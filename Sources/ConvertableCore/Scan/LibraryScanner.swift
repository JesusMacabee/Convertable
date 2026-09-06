import Foundation

/// Read-only library scanner. Uses only what directory enumeration returns (name, size, mtime,
/// isDirectory) and opens a file solely to resolve an ambiguous container (.m4a: AAC or ALAC).
///
/// Full scans are resumable per top-level (artist) directory; incremental scans stat known
/// directories and re-list only those whose mtime changed.
public final class LibraryScanner {
    public struct Progress: Sendable {
        public var dirs = 0, files = 0, audio = 0, added = 0, changed = 0, unchanged = 0, reappeared = 0, missing = 0, sniffed = 0
        public var currentArtist: String = ""
    }

    public enum Failure: Error, CustomStringConvertible {
        case volume(VolumeStatus)
        case cancelled
        public var description: String {
            switch self {
            case let .volume(v): return "volume not available: \(v)"
            case .cancelled: return "scan cancelled"
            }
        }
    }

    public let root: String
    public let store: Store
    public var onProgress: ((Progress) -> Void)?
    public var isCancelled: () -> Bool = { false }
    /// Hook for tests: injects "now".
    public var clock: () -> Double = { Date().timeIntervalSince1970 }

    private let fm = FileManager.default
    private let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .nameKey]

    public init(root: String, store: Store) {
        self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
        self.store = store
    }

    // MARK: Full scan

    @discardableResult
    public func fullScan() throws -> Progress {
        try gate()
        var progress = Progress()
        let now = clock()
        // Resume an interrupted full scan, or start a new one.
        let scan: ScanRecord
        var resumeAfter: String?
        if let unfinished = try store.unfinishedFullScan() {
            scan = unfinished
            resumeAfter = unfinished.checkpoint
            progress.dirs = unfinished.dirsSeen
            progress.files = unfinished.filesSeen
        } else {
            scan = try store.beginScan(.full, now: now)
        }

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let top = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        try store.seenDirectory("", mtime: mtime(of: rootURL), scanID: scan.id)

        for entry in top {
            if isCancelled() { throw Failure.cancelled }
            let name = entry.lastPathComponent
            if let resumeAfter, name.localizedStandardCompare(resumeAfter) != .orderedDescending { continue }
            progress.currentArtist = name
            let v = try entry.resourceValues(forKeys: Set(keys))
            try store.db.transaction {
                if v.isDirectory == true {
                    try visit(entry, scanID: scan.id, now: now, progress: &progress)
                } else if v.isRegularFile == true {
                    try record(fileURL: entry, rel: name, values: v, scanID: scan.id, now: now, progress: &progress)
                }
                try store.updateScan(scan.id, checkpoint: name, dirsSeen: progress.dirs, filesSeen: progress.files)
            }
            onProgress?(progress)
        }

        // Anything active that this complete pass didn't see is missing. The gate passed, so this is
        // real absence, not an unmounted volume.
        try gate()
        try store.db.transaction {
            progress.missing = try store.markFilesMissing(notSeenIn: scan.id, now: clock())
            _ = try store.markDirectoriesMissing(notSeenIn: scan.id)
            try store.finishScan(scan.id, now: clock())
        }
        onProgress?(progress)
        return progress
    }

    // MARK: Incremental scan

    @discardableResult
    public func incrementalScan() throws -> Progress {
        try gate()
        var progress = Progress()
        let now = clock()
        let scan = try store.beginScan(.incremental, now: now)
        let known = try store.activeDirectories()

        for (rel, oldMtime) in known {
            if isCancelled() { throw Failure.cancelled }
            let url = rel.isEmpty ? URL(fileURLWithPath: root, isDirectory: true) : URL(fileURLWithPath: root + "/" + rel, isDirectory: true)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]), values.isDirectory == true else {
                // Directory gone. Its files are marked missing; a later full scan confirms before anything is proposed.
                try store.db.transaction {
                    progress.missing += try store.markFilesMissing(notSeenIn: scan.id, now: now, underPrefix: rel)
                    if rel.isEmpty == false { _ = try store.markDirectoriesMissing(notSeenIn: scan.id, underPrefix: rel) }
                }
                continue
            }
            let m = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            progress.dirs += 1
            if abs(m - oldMtime) < 0.001 {
                try store.seenDirectory(rel, mtime: m, scanID: scan.id)
                continue
            }
            // Something was added, removed or renamed here: re-list this directory (shallow), and deep-scan any new subdirectories.
            try store.db.transaction {
                try store.seenDirectory(rel, mtime: m, scanID: scan.id)
                let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                let knownSet = Set(known.map(\.relPath))
                for child in children {
                    let v = try child.resourceValues(forKeys: Set(keys))
                    let childRel = rel.isEmpty ? child.lastPathComponent : rel + "/" + child.lastPathComponent
                    if v.isDirectory == true {
                        if knownSet.contains(childRel) {
                            try store.seenDirectory(childRel, mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, scanID: scan.id)
                        } else {
                            try visit(child, scanID: scan.id, now: now, progress: &progress)
                        }
                    } else if v.isRegularFile == true {
                        try record(fileURL: child, rel: childRel, values: v, scanID: scan.id, now: now, progress: &progress)
                    }
                }
                progress.missing += try store.markFilesMissing(notSeenIn: scan.id, now: now, directlyIn: rel)
            }
            onProgress?(progress)
        }
        // Second look at anything seen only once: confirms settled files, catches ones still being written.
        // Batched so a first run over a whole library (tens of thousands) still completes in one scan.
        var confirmed: Set<Int64> = []
        while true {
            let pending = try store.filesAwaitingConfirmation().filter { !confirmed.contains($0.id) }
            if pending.isEmpty { break }
            for f in pending {
                confirmed.insert(f.id)
                if isCancelled() { throw Failure.cancelled }
                let url = URL(fileURLWithPath: root + "/" + f.relPath)
                guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else {
                    try store.markFileMissing(relPath: f.relPath, now: now); progress.missing += 1; continue
                }
                let r = try store.seenFile(relPath: f.relPath, artistDir: f.artistDir, albumDir: f.albumDir, ext: f.ext, kind: f.kind, codec: f.codec,
                                           size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, scanID: scan.id, now: now)
                progress.files += 1
                switch r { case .changed: progress.changed += 1; case .unchanged, .reappeared: progress.unchanged += 1; case .added: progress.added += 1 }
            }
            onProgress?(progress)
        }
        try store.finishScan(scan.id, now: clock())
        onProgress?(progress)
        return progress
    }

    // MARK: Internals

    func gate() throws {
        if case .available = VolumeGate.check(root: root, timeout: 30) { return }
        throw Failure.volume(VolumeGate.check(root: root, timeout: 1))
    }

    /// Deep-enumerates one directory (an artist, or a newly appeared subtree).
    private func visit(_ dirURL: URL, scanID: Int64, now: Double, progress: inout Progress) throws {
        let rel = relPath(of: dirURL)
        try store.seenDirectory(rel, mtime: mtime(of: dirURL), scanID: scanID)
        progress.dirs += 1
        guard let it = fm.enumerator(at: dirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in it {
            if isCancelled() { throw Failure.cancelled }
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isDirectory == true {
                try store.seenDirectory(relPath(of: url), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, scanID: scanID)
                progress.dirs += 1
            } else if v.isRegularFile == true {
                try record(fileURL: url, rel: relPath(of: url), values: v, scanID: scanID, now: now, progress: &progress)
            }
        }
    }

    private func record(fileURL: URL, rel: String, values v: URLResourceValues, scanID: Int64, now: Double, progress: inout Progress) throws {
        progress.files += 1
        let ext = "." + fileURL.pathExtension.lowercased()
        guard Classifier.isAudio(ext) else { return }
        progress.audio += 1
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let artist = parts.count >= 2 ? parts[0] : ""
        let album = parts.count >= 3 ? parts[1] : ""
        var kind = Classifier.kind(forExtension: ext)
        var codec: String?
        let size = Int64(v.fileSize ?? 0)
        let mtime = v.contentModificationDate?.timeIntervalSince1970 ?? 0
        if kind == nil {
            // Ambiguous container: sniff only when new or changed; otherwise keep what we know.
            if let existing = try store.sourceFile(relPath: rel), existing.size == size, abs(existing.mtime - mtime) < 0.001, let c = existing.codec {
                codec = c; kind = Classifier.kind(forCodec: c)
            } else {
                codec = MP4Sniff.codec(ofFileAt: fileURL.path)
                progress.sniffed += 1
                kind = codec.map(Classifier.kind(forCodec:)) ?? .lossy
            }
        }
        let result = try store.seenFile(relPath: rel, artistDir: artist, albumDir: album, ext: ext, kind: kind ?? .other, codec: codec,
                                        size: size, mtime: mtime, scanID: scanID, now: now)
        switch result {
        case .added: progress.added += 1
        case .changed: progress.changed += 1
        case .unchanged: progress.unchanged += 1
        case .reappeared: progress.reappeared += 1
        }
    }

    private func relPath(of url: URL) -> String {
        let p = url.standardizedFileURL.path
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        guard p.hasPrefix(base) else { return p }
        return String(p.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func mtime(of url: URL) -> Double {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
    }
}
