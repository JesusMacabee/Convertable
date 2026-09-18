import Foundation

/// Environment checks. Each is independent and reports pass/warn/fail with detail.
public struct DoctorCheck: Sendable {
    public enum Result: String, Sendable { case pass, warn, fail }
    public let name: String
    public let result: Result
    public let detail: String
}

public enum Doctor {
    public static func run(settings: Settings, benchmark: Bool = true) -> [DoctorCheck] {
        var out: [DoctorCheck] = []

        // Source volume
        let src = VolumeGate.check(root: settings.sourceRoot, timeout: 15)
        switch src {
        case let .available(info):
            out.append(.init(name: "Source mounted", result: .pass,
                             detail: "\(settings.sourceRoot) on \(info.fsType) (\(info.mountedFrom)); suggested share concurrency \(info.suggestedConcurrency)"))
            if info.fsType.lowercased() == "afpfs" {
                out.append(.init(name: "Protocol", result: .warn, detail: "AFP: slow cold opens and poor concurrency on this client. SMB measured ~20× faster — consider remounting over smb://"))
            }
        case let .notMounted(v): out.append(.init(name: "Source mounted", result: .fail, detail: "\(v) is not mounted"))
        case let .pathMissing(p): out.append(.init(name: "Source mounted", result: .fail, detail: "volume mounted but \(p) does not exist"))
        case let .unresponsive(p): out.append(.init(name: "Source mounted", result: .fail, detail: "\(p) did not answer a listing within 15 s"))
        }

        // Mirror root (parent must exist; root itself is created on first run)
        let mirrorParent = (settings.mirrorRoot as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: mirrorParent) {
            let writable = access(mirrorParent, W_OK) == 0
            out.append(.init(name: "Mirror location", result: writable ? .pass : .fail,
                             detail: writable ? "\(settings.mirrorRoot) (parent writable)" : "\(mirrorParent) is not writable"))
            if let free = VolumeGate.freeBytes(at: mirrorParent) {
                out.append(.init(name: "Mirror free space", result: free > 20_000_000_000 ? .pass : .warn, detail: ByteCount.string(free)))
            }
        } else {
            out.append(.init(name: "Mirror location", result: .fail, detail: "\(mirrorParent) does not exist"))
        }

        // Local work space
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
        if let free = VolumeGate.freeBytes(at: caches) {
            out.append(.init(name: "Local temp space", result: free > 10_000_000_000 ? .pass : .warn, detail: "\(ByteCount.string(free)) free in \(caches)"))
        }

        // Tools
        let af = Tools.afconvert
        out.append(.init(name: "afconvert", result: af.available ? .pass : .fail, detail: af.path ?? "not found (part of macOS; this should not happen)"))
        for t in [Tools.lame, Tools.flac] {
            out.append(.init(name: t.name, result: t.available ? .pass : .warn,
                             detail: t.available ? "\(t.path!) — \(t.version ?? "")" : "not installed (only needed for MP3/FLAC output profiles): brew install \(t.name)"))
        }
        out.append(.init(name: "TagLib", result: .pass, detail: "linked (libtag_c)"))

        // Music.app
        if let lib = MusicPrefs.openLibraryURLString {
            let ok = MusicPrefs.isConfiguredLibraryOpen(settings)
            let running = MusicPrefs.isRunning
            out.append(.init(name: "Music library", result: ok ? .pass : .warn,
                             detail: (ok ? "configured library is the open one" : "Music has a different library open: \(lib.removingPercentEncoding ?? lib)") + (running ? " (Music running)" : " (Music not running)")))
        } else {
            out.append(.init(name: "Music library", result: .warn, detail: "could not read Music preferences"))
        }
        if FileManager.default.fileExists(atPath: settings.musicLibraryPath) {
            out.append(.init(name: "Library bundle", result: .pass, detail: settings.musicLibraryPath))
        } else {
            out.append(.init(name: "Library bundle", result: .fail, detail: "\(settings.musicLibraryPath) not found"))
        }

        // Database
        do {
            let url = Settings.defaultDatabaseURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let db = try Database(path: url.path)
            try Schema.migrate(db)
            out.append(.init(name: "State database", result: .pass, detail: "\(url.path) schema v\(db.userVersion)"))
        } catch {
            out.append(.init(name: "State database", result: .fail, detail: "\(error)"))
        }

        // Web port
        let port = settings.web.port
        if portIsFree(port) { out.append(.init(name: "Web port", result: .pass, detail: "\(port) free")) }
        else if (try? Tools.run("/usr/bin/curl", ["-s", "-m", "2", "http://127.0.0.1:\(port)/health"], timeout: 5).stdout) == "ok" {
            out.append(.init(name: "Web port", result: .pass, detail: "\(port) — Convertable's dashboard is already serving here"))
        } else { out.append(.init(name: "Web port", result: .warn, detail: "\(port) in use by another program; pick a different port")) }

        // Latency benchmark (read-only; ~20 small header reads)
        if benchmark, case .available = src, let b = Benchmark.coldOpen(root: settings.sourceRoot, samples: 20) {
            let verdict: DoctorCheck.Result = b.coldMs < 100 ? .pass : (b.coldMs < 400 ? .warn : .fail)
            out.append(.init(name: "Share latency", result: verdict,
                             detail: String(format: "cold open %.0f ms, warm %.0f ms, listing %.0f ms (%d files sampled)", b.coldMs, b.warmMs, b.listMs, b.sampled)))
        }
        return out
    }

    /// Free means nothing accepts connections on it. A bind test is the wrong probe: with SO_REUSEADDR it
    /// succeeds against a wildcard listener (the dashboard with LAN access on), and without it a lingering
    /// TIME_WAIT socket makes a free port look busy. A connect attempt is refused exactly when the port is free.
    static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return rc != 0 && errno == ECONNREFUSED
    }
}

public enum ByteCount {
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }
}

/// Small read-only latency probe used by doctor and by the adaptive concurrency controller's baseline.
public enum Benchmark {
    public struct Result: Sendable { public let coldMs: Double, warmMs: Double, listMs: Double, sampled: Int }

    public static func coldOpen(root: String, samples: Int) -> Result? {
        let fm = FileManager.default
        var t = Date()
        guard let top = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        let listMs = Date().timeIntervalSince(t) * 1000
        // Walk a few random artist dirs two levels deep for candidate files.
        var files: [String] = []
        for a in top.shuffled().prefix(8) where !a.hasPrefix(".") {
            let ad = root + "/" + a
            guard let albums = try? fm.contentsOfDirectory(atPath: ad) else { continue }
            for al in albums where !al.hasPrefix(".") {
                let p = ad + "/" + al
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    if let fs = try? fm.contentsOfDirectory(atPath: p) {
                        files += fs.filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".flac") }.map { p + "/" + $0 }
                    }
                } else if p.lowercased().hasSuffix(".flac") {
                    files.append(p)
                }
                if files.count >= samples * 3 { break }
            }
            if files.count >= samples * 3 { break }
        }
        let picks = Array(files.shuffled().prefix(samples))
        guard !picks.isEmpty else { return nil }
        func read(_ p: String) { if let h = FileHandle(forReadingAtPath: p) { _ = try? h.read(upToCount: 2048); try? h.close() } }
        t = Date(); picks.forEach(read); let cold = Date().timeIntervalSince(t) * 1000 / Double(picks.count)
        t = Date(); picks.forEach(read); let warm = Date().timeIntervalSince(t) * 1000 / Double(picks.count)
        return Result(coldMs: cold, warmMs: warm, listMs: listMs, sampled: picks.count)
    }
}
