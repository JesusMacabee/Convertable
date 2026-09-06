import Foundation

/// What Music.app itself says about its state, read from its preferences — no AppleScript needed.
public enum MusicPrefs {
    static let domain = "com.apple.Music" as CFString

    /// File URL string of the library Music has open (or last had open), e.g.
    /// `file:///Users/me/Music/Music/Music%20Library.musiclibrary/`.
    public static var openLibraryURLString: String? {
        CFPreferencesCopyAppValue("library-url" as CFString, domain) as? String
    }

    public static var mediaFolderURLString: String? {
        CFPreferencesCopyAppValue("media-folder-url" as CFString, domain) as? String
    }

    public static var isRunning: Bool {
        // Cheap and permission-free; NSWorkspace would need AppKit.
        (try? Tools.run("/usr/bin/pgrep", ["-xq", "Music"], timeout: 5).status == 0) ?? false
    }

    /// True when the open library is the one Convertable is configured for.
    public static func isConfiguredLibraryOpen(_ settings: Settings) -> Bool {
        guard let open = openLibraryURLString else { return false }
        return normalize(open) == normalize(settings.musicLibraryFileURLString)
    }

    static func normalize(_ s: String) -> String {
        var v = s.removingPercentEncoding ?? s
        if !v.hasSuffix("/") { v += "/" }
        return v.lowercased()
    }
}
