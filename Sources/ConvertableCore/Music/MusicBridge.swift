import Foundation

/// Runs AppleScript against Music.app. Abstracted so the importer can be tested with a mock.
public protocol MusicScripting: Sendable {
    /// Returns osascript's stdout (trimmed). Throws `MusicError.script` with Music's message on failure.
    func run(_ script: String, timeout: TimeInterval) throws -> String
}

public enum MusicError: Error, CustomStringConvertible, Equatable {
    case script(String)
    case notRunning
    case wrongLibraryOpen(String)
    case copiedIntoMediaFolder(added: String, ours: String)
    case unexpectedOutput(String)
    public var description: String {
        switch self {
        case let .script(m): return "Music: \(m)"
        case .notRunning: return "Music is not running"
        case let .wrongLibraryOpen(l): return "Music has a different library open: \(l)"
        case let .copiedIntoMediaFolder(a, o): return "Music copied the file into its media folder (\(a)) instead of referencing \(o) — turn off “Copy files to Music Media folder” in that library"
        case let .unexpectedOutput(o): return "unexpected AppleScript output: \(o.prefix(200))"
        }
    }
}

/// `osascript` in a subprocess: killable on timeout, and Automation permission attaches to the host app.
public struct OsascriptRunner: MusicScripting {
    public init() {}
    public func run(_ script: String, timeout: TimeInterval) throws -> String {
        let r = try Tools.run("/usr/bin/osascript", ["-e", script], timeout: timeout)
        guard r.status == 0 else {
            throw MusicError.script(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "execution error: ", with: ""))
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The operations Convertable needs from Music, as AppleScript. Every path goes through `quote`.
public struct MusicBridge: Sendable {
    public let runner: MusicScripting
    public init(runner: MusicScripting = OsascriptRunner()) { self.runner = runner }

    /// AppleScript string literal: backslashes and double quotes escaped.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static let sep = "\u{1F}"   // unit separator: never appears in paths or IDs

    public func version() throws -> String {
        try runner.run("tell application \"Music\" to return version", timeout: 20)
    }

    /// Adds one file to the library and returns Music's persistent ID plus the location Music recorded.
    /// If the location is not our file, Music copied it (the setting we require to be off).
    public func add(path: String) throws -> (persistentID: String, location: String) {
        let script = """
        tell application "Music"
            set t to add (POSIX file \(Self.quote(path))) to library playlist 1
            if class of t is list then set t to item 1 of t
            set loc to ""
            try
                set loc to POSIX path of (location of t as alias)
            end try
            return (persistent ID of t) & \(Self.quote(Self.sep)) & loc
        end tell
        """
        let out = try runner.run(script, timeout: 120)
        let parts = out.components(separatedBy: Self.sep)
        guard parts.count == 2, !parts[0].isEmpty else { throw MusicError.unexpectedOutput(out) }
        return (parts[0], parts[1])
    }

    public func refresh(persistentID: String) throws {
        _ = try runner.run("""
        tell application "Music"
            refresh (first file track of library playlist 1 whose persistent ID is \(Self.quote(persistentID)))
        end tell
        """, timeout: 60)
    }

    /// Removes the track entry from the library. Files are never deleted by Music here — we manage them.
    /// Idempotent: a track that is already gone is not an error. (Deleting through a `whose` specifier that
    /// matches nothing fails with "doesn't understand the delete message", -1708, not the "Can't get" text
    /// a plain lookup gives, so the script checks first.) Returns false when there was nothing to delete.
    @discardableResult
    public func remove(persistentID: String) throws -> Bool {
        let out = try runner.run("""
        tell application "Music"
            set hits to (every track of library playlist 1 whose persistent ID is \(Self.quote(persistentID)))
            if (count of hits) is 0 then return "gone"
            delete (item 1 of hits)
            return "deleted"
        end tell
        """, timeout: 60)
        return out != "gone"
    }

    /// Every file track's persistent ID and path. Used to reconcile after a restart or a manual import.
    public func fileTracks() throws -> [(persistentID: String, path: String)] {
        // Per-track location reads: the bulk form throws as soon as any single track's file is missing.
        let out = try runner.run("""
        tell application "Music"
            set ts to every file track of library playlist 1
            set acc to {}
            repeat with t in ts
                set p to ""
                try
                    set p to POSIX path of (location of t as alias)
                end try
                set end of acc to (persistent ID of t) & \(Self.quote(Self.sep)) & p
            end repeat
            set AppleScript's text item delimiters to linefeed
            return acc as text
        end tell
        """, timeout: 900)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: Self.sep)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// Tracks of one album (by album + artist/album artist) with their titles and whether the file is missing.
    /// Used to identify legacy entries whose files are gone, which have no usable location any more.
    public func albumTracks(album: String, artist: String) throws -> [(persistentID: String, name: String, missing: Bool)] {
        let out = try runner.run("""
        tell application "Music"
            set ts to (every file track of library playlist 1 whose album is \(Self.quote(album)) and (artist is \(Self.quote(artist)) or album artist is \(Self.quote(artist))))
            set acc to {}
            repeat with t in ts
                set m to "1"
                try
                    if location of t is not missing value then set m to "0"
                end try
                set end of acc to (persistent ID of t) & \(Self.quote(Self.sep)) & (name of t) & \(Self.quote(Self.sep)) & m
            end repeat
            set AppleScript's text item delimiters to linefeed
            return acc as text
        end tell
        """, timeout: 120)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: Self.sep)
            return parts.count == 3 ? (parts[0], parts[1], parts[2] == "1") : nil
        }
    }

    /// Every file track whose file no longer exists, with enough metadata to show a person. Walks the whole
    /// library one track at a time (Music cannot filter on a missing location), so minutes for large libraries.
    public func deadTracks() throws -> [(persistentID: String, name: String, artist: String, album: String)] {
        let out = try runner.run("""
        tell application "Music"
            set ts to every file track of library playlist 1
            set acc to {}
            repeat with t in ts
                set dead to false
                try
                    if location of t is missing value then set dead to true
                on error
                    set dead to true
                end try
                if dead then set end of acc to (persistent ID of t) & \(Self.quote(Self.sep)) & (name of t) & \(Self.quote(Self.sep)) & (artist of t) & \(Self.quote(Self.sep)) & (album of t)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return acc as text
        end tell
        """, timeout: 1800)
        return out.split(separator: "\n").compactMap { line in
            let p = line.components(separatedBy: Self.sep)
            return p.count == 4 ? (p[0], p[1], p[2], p[3]) : nil
        }
    }

    public func setLocation(persistentID: String, path: String) throws {
        _ = try runner.run("""
        tell application "Music"
            set location of (first file track of library playlist 1 whose persistent ID is \(Self.quote(persistentID))) to POSIX file \(Self.quote(path))
        end tell
        """, timeout: 60)
    }

    /// Carries listening history from one track to another (used when a legacy copy is superseded).
    public func copyStats(from: String, to: String) throws {
        _ = try runner.run("""
        tell application "Music"
            set a to (first track of library playlist 1 whose persistent ID is \(Self.quote(from)))
            set b to (first track of library playlist 1 whose persistent ID is \(Self.quote(to)))
            set rating of b to rating of a
            set played count of b to played count of a
            try
                set played date of b to played date of a
            end try
            try
                set favorited of b to favorited of a
            end try
        end tell
        """, timeout: 60)
    }

    public func launch() throws { _ = try runner.run("tell application \"Music\" to launch", timeout: 60) }
}
