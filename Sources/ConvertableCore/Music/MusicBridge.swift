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
    public func remove(persistentID: String) throws {
        _ = try runner.run("""
        tell application "Music"
            delete (first track of library playlist 1 whose persistent ID is \(Self.quote(persistentID)))
        end tell
        """, timeout: 60)
    }

    /// Every file track's persistent ID and path. Used to reconcile after a restart or a manual import.
    public func fileTracks() throws -> [(persistentID: String, path: String)] {
        let out = try runner.run("""
        tell application "Music"
            set ids to persistent ID of every file track of library playlist 1
            set locs to location of every file track of library playlist 1
            set acc to {}
            repeat with i from 1 to count of ids
                set p to ""
                try
                    set p to POSIX path of (item i of locs as alias)
                end try
                set end of acc to (item i of ids) & \(Self.quote(Self.sep)) & p
            end repeat
            set AppleScript's text item delimiters to linefeed
            return acc as text
        end tell
        """, timeout: 600)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: Self.sep)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
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
