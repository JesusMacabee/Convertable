import Foundation

/// What Music.app itself says about its state, read from its preferences — no AppleScript needed.
public enum MusicPrefs {
    static let domain = "com.apple.Music"
    private static let lock = NSLock()
    private static var cache: [String: (at: Double, value: String?)] = [:]

    /// Never open Music's own files in-process: macOS per-app data protection can hold such an `open()`
    /// indefinitely while a privacy decision is pending, which would freeze the controller. Everything here
    /// goes through short-lived subprocesses with timeouts, and is cached for 5 s because status() asks often.
    static func cached(_ key: String, _ compute: () -> String?) -> String? {
        let now = Date().timeIntervalSince1970
        lock.lock()
        if let c = cache[key], now - c.at < 5 { lock.unlock(); return c.value }
        lock.unlock()
        let value = compute()
        lock.lock(); cache[key] = (now, value); lock.unlock()
        return value
    }

    /// The `.musiclibrary` bundle the running Music process holds open, found with `lsof` — no Music file is touched.
    public static var openLibraryPathViaProcess: String? {
        cached("lsof-library") {
            guard let pid = try? Tools.run("/usr/bin/pgrep", ["-x", "Music"], timeout: 5).stdout.split(separator: "\n").first else { return nil }
            guard let r = try? Tools.run("/usr/sbin/lsof", ["-nP", "-Fn", "-p", String(pid)], timeout: 15) else { return nil }
            for line in r.stdout.split(separator: "\n") where line.hasPrefix("n") && line.contains(".musiclibrary/") {
                let path = String(line.dropFirst())
                if let range = path.range(of: ".musiclibrary/") { return String(path[..<range.upperBound].dropLast()) }
            }
            return nil
        }
    }

    static func read(_ key: String) -> String? {
        cached(key) {
            guard let r = try? Tools.run("/usr/bin/defaults", ["read", domain, key], timeout: 5), r.status == 0 else { return nil }
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
    }

    /// File URL string of the library Music has open: from the live process when Music is running,
    /// else Music's last-used library from its preferences.
    public static var openLibraryURLString: String? {
        if isRunning, let p = openLibraryPathViaProcess { return URL(fileURLWithPath: p, isDirectory: true).absoluteString }
        return read("library-url")
    }

    public static var mediaFolderURLString: String? { read("media-folder-url") }

    public static var isRunning: Bool {
        // Cheap and permission-free; NSWorkspace would need AppKit.
        (try? Tools.run("/usr/bin/pgrep", ["-xq", "Music"], timeout: 5).status == 0) ?? false
    }

    /// True when the open library is the one Convertable is configured for.
    public static func isConfiguredLibraryOpen(_ settings: Settings) -> Bool {
        guard let open = openLibraryURLString else { return false }
        return normalize(open) == normalize(settings.musicLibraryFileURLString)
    }

    /// Whether the library Music would open on launch (its last-used library, from preferences) is the configured one.
    /// Meaningful while Music is closed; while it runs, `isConfiguredLibraryOpen` is the live answer.
    /// nil when the preference cannot be read — macOS's per-app data protection silently blocks the read for an app
    /// launched normally unless the user has granted it access to Music's data (it works from a Terminal context).
    public static func configuredLibraryIsDefault(_ settings: Settings) -> Bool? {
        guard let d = read("library-url") else { return nil }
        return normalize(d) == normalize(settings.musicLibraryFileURLString)
    }

    public static func normalize(_ s: String) -> String {
        var v = s.removingPercentEncoding ?? s
        if !v.hasSuffix("/") { v += "/" }
        return v.lowercased()
    }
}
