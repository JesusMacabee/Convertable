import Foundation

/// The one gate every read/write on the network share passes through.
///
/// Limits operations in flight (AFP tolerates 1, SMB a handful) and adapts: when an operation
/// takes far longer than the running average the limit halves; after a quiet stretch it creeps back.
public actor ShareIO {
    public private(set) var limit: Int
    public let maxLimit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var ewmaSeconds: Double = 0
    private var goodStreak = 0
    public private(set) var completed = 0
    public private(set) var peakInFlight = 0

    public init(limit: Int, maxLimit: Int? = nil) {
        let l = max(1, limit)
        self.limit = l
        self.maxLimit = max(l, maxLimit ?? l)
    }

    /// Runs `body` under the concurrency limit, on a background thread (the body is blocking file I/O).
    public func perform<T: Sendable>(_ label: String = "", _ body: @Sendable @escaping () throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        let start = Date()
        let result: Result<T, Error> = await Task.detached(priority: .utility) { Result { try body() } }.value
        observe(Date().timeIntervalSince(start))
        return try result.get()
    }

    private func acquire() async {
        if inFlight < limit {
            inFlight += 1; peakInFlight = max(peakInFlight, inFlight); return
        }
        // The slot is handed over by `release()` — it stays counted in `inFlight`, so no increment here.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        // Hand the slot straight to a waiter (no decrement, so nobody can sneak in between), or free it.
        if !waiters.isEmpty, inFlight <= limit {
            waiters.removeFirst().resume()
        } else {
            inFlight -= 1
        }
    }

    /// Latency-based adaptation. A spike is an operation > 8× the average (and > 2 s), which on a
    /// network share means the client is queueing. Recovery needs 50 consecutive normal operations.
    private func observe(_ seconds: Double) {
        completed += 1
        if ewmaSeconds == 0 { ewmaSeconds = seconds } else { ewmaSeconds = ewmaSeconds * 0.9 + seconds * 0.1 }
        if seconds > 2, seconds > ewmaSeconds * 8, limit > 1 {
            limit = max(1, limit / 2); goodStreak = 0
        } else {
            goodStreak += 1
            if goodStreak >= 50, limit < maxLimit { limit += 1; goodStreak = 0 }
        }
    }

    // MARK: Convenience file operations (all run under the limit)

    public func copy(from src: String, to dst: String) async throws {
        try await perform("copy") {
            try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
            try FileManager.default.copyItem(atPath: src, toPath: dst)
        }
    }

    /// Writes `src` to `dst` atomically from the reader's point of view: copy to `dst.partial`, then rename.
    public func publish(localFile src: String, to dst: String) async throws {
        let partial = dst + ".partial"
        try await copy(from: src, to: partial)
        try await perform("rename") {
            if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
            try FileManager.default.moveItem(atPath: partial, toPath: dst)
        }
    }

    public func move(from src: String, to dst: String) async throws {
        try await perform("move") {
            try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: src, toPath: dst)
        }
    }

    public func remove(_ path: String) async throws {
        try await perform("remove") { try FileManager.default.removeItem(atPath: path) }
    }

    public func attributes(of path: String) async throws -> (size: Int64, mtime: Double) {
        try await perform("stat") {
            let a = try FileManager.default.attributesOfItem(atPath: path)
            return ((a[.size] as? NSNumber)?.int64Value ?? 0, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
    }

    public func size(of path: String) async throws -> Int64 {
        try await perform("stat") {
            let a = try FileManager.default.attributesOfItem(atPath: path)
            return (a[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    public func exists(_ path: String) async -> Bool {
        (try? await perform("exists") { FileManager.default.fileExists(atPath: path) }) ?? false
    }
}
