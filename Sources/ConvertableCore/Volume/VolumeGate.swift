import Foundation

/// What the share is mounted as. Drives the concurrency profile and doctor's advice.
public struct MountInfo: Equatable, Sendable {
    public let mountPoint: String
    public let fsType: String        // smbfs, afpfs, nfs, apfs, …
    public let mountedFrom: String   // //user@host/share, /dev/disk3s1, …

    public var isNetwork: Bool {
        ["smbfs", "afpfs", "nfs", "webdav", "cifs"].contains(fsType.lowercased())
    }

    /// Starting in-flight limit for share I/O before the adaptive controller adjusts it.
    /// AFP's client degrades badly under parallel requests; SMB/NFS scale to a handful.
    public var suggestedConcurrency: Int {
        switch fsType.lowercased() {
        case "afpfs": return 1
        case "smbfs", "cifs", "nfs", "webdav": return 4
        default: return 8   // local disk
        }
    }
}

public enum VolumeStatus: Equatable, Sendable {
    case available(MountInfo)
    case notMounted(expectedMountPoint: String)
    case pathMissing(String)
    case unresponsive(String)
}

public enum VolumeGate {
    /// Finds the mount that contains `path` (longest matching mount point).
    public static func mountInfo(containing path: String) -> MountInfo? {
        var raw: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&raw, MNT_NOWAIT)
        guard count > 0, let raw else { return nil }
        var best: MountInfo?
        for i in 0..<Int(count) {
            let fs = raw[i]
            let mnt = withUnsafePointer(to: fs.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let type = withUnsafePointer(to: fs.f_fstypename) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let from = withUnsafePointer(to: fs.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let prefix = mnt.hasSuffix("/") ? mnt : mnt + "/"
            if path == mnt || path.hasPrefix(prefix) {
                if best == nil || mnt.count > best!.mountPoint.count {
                    best = MountInfo(mountPoint: mnt, fsType: type, mountedFrom: from)
                }
            }
        }
        return best
    }

    /// The `/Volumes/<name>` a path lives under, if any — what we expect to be mounted.
    public static func expectedVolume(for path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }

    /// Full gate: mounted → path exists → a listing answers within `timeout`.
    /// Never reports `pathMissing` when the volume itself is gone.
    public static func check(root: String, timeout: TimeInterval = 30) -> VolumeStatus {
        if let vol = expectedVolume(for: root) {
            guard let info = mountInfo(containing: root), info.mountPoint == vol else {
                return .notMounted(expectedMountPoint: vol)
            }
            guard FileManager.default.fileExists(atPath: root) else { return .pathMissing(root) }
            return probeListing(root, timeout: timeout) ? .available(info) : .unresponsive(root)
        }
        // Local path (tests, custom setups).
        guard FileManager.default.fileExists(atPath: root) else { return .pathMissing(root) }
        let info = mountInfo(containing: root) ?? MountInfo(mountPoint: "/", fsType: "unknown", mountedFrom: "")
        return probeListing(root, timeout: timeout) ? .available(info) : .unresponsive(root)
    }

    /// A stalled network mount can hang a plain listing indefinitely; bound it.
    static func probeListing(_ path: String, timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let ok = Locked(false)
        DispatchQueue.global(qos: .utility).async {
            ok.value = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success && ok.value
    }

    /// Free bytes on the filesystem containing `path`.
    public static func freeBytes(at path: String) -> Int64? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }
}
