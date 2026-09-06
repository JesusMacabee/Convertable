import Foundation

public enum FileKind: String, Codable, Sendable { case lossless, lossy, other }
public enum FileStatus: String, Codable, Sendable { case active, missing, ignored }

public struct SourceFile: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var relPath: String
    public var artistDir: String
    public var albumDir: String
    public var ext: String
    public var kind: FileKind
    public var codec: String?
    public var size: Int64
    public var mtime: Double
    public var stableSince: Double
    public var observations: Int
    public var firstSeen: Double
    public var lastSeenScan: Int64
    public var status: FileStatus
    public var missingSince: Double?
    public var audioMD5: String?
    public var tagHash: String?
    public var tagArtist: String?
    public var tagAlbumArtist: String?
    public var tagAlbum: String?

    public var fileName: String { (relPath as NSString).lastPathComponent }
    public var stem: String { (fileName as NSString).deletingPathExtension }
    public var albumKey: AlbumKey { AlbumKey(artistDir: artistDir, albumDir: albumDir) }
}

/// An album is a (artist directory, album directory) pair — the unit of settling, batching and Music import.
public struct AlbumKey: Hashable, Codable, Sendable, Comparable {
    public var artistDir: String
    public var albumDir: String
    public init(artistDir: String, albumDir: String) { self.artistDir = artistDir; self.albumDir = albumDir }
    public var relPath: String { albumDir.isEmpty ? artistDir : artistDir + "/" + albumDir }
    public static func < (a: AlbumKey, b: AlbumKey) -> Bool {
        a.artistDir == b.artistDir ? a.albumDir < b.albumDir : a.artistDir < b.artistDir
    }
}

public struct OutputFile: Equatable, Sendable {
    public var id: Int64
    public var sourceID: Int64
    public var relPath: String
    public var size: Int64?
    public var encoderProfile: String
    public var audioMD5: String?
    public var tagHash: String?
    public var verifyOK: Bool
    public var musicPersistentID: String?
}

public enum ScanKind: String, Codable, Sendable { case full, incremental }

public struct ScanRecord: Equatable, Sendable {
    public var id: Int64
    public var kind: ScanKind
    public var startedAt: Double
    public var finishedAt: Double?
    public var dirsSeen: Int
    public var filesSeen: Int
    public var checkpoint: String?
}

/// Classification by extension. `.m4a` is ambiguous (AAC or ALAC) and is resolved by sniffing the container.
public enum Classifier {
    public static let losslessExts: Set<String> = [".flac", ".wav", ".aif", ".aiff", ".aifc", ".ape", ".wv", ".dsf", ".dff", ".alac", ".tta", ".tak"]
    public static let lossyExts: Set<String> = [".mp3", ".aac", ".ogg", ".oga", ".opus", ".wma", ".mpc", ".mp2"]
    public static let ambiguousExts: Set<String> = [".m4a", ".mp4", ".m4b", ".caf", ".mka"]

    public static func isAudio(_ ext: String) -> Bool {
        losslessExts.contains(ext) || lossyExts.contains(ext) || ambiguousExts.contains(ext)
    }

    /// Kind from extension alone; nil when the container must be inspected.
    public static func kind(forExtension ext: String) -> FileKind? {
        if losslessExts.contains(ext) { return .lossless }
        if lossyExts.contains(ext) { return .lossy }
        return nil
    }

    public static func kind(forCodec codec: String) -> FileKind {
        switch codec.lowercased() {
        case "alac", "flac", "lpcm", "sowt", "twos", "in24", "in32", "fl32", "ape", "wavpack", "dsd": return .lossless
        default: return .lossy
        }
    }
}
