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
    public var hasMBID: Bool? = nil          // nil = not audited yet
    public var tagTitle: String? = nil
    public var tagTrack: Int? = nil
    public var tagDisc: Int? = nil
    public var tagDiscTotal: Int? = nil
    public var tagYear: Int? = nil
    public var mbidRelease: String? = nil
    /// "" for a normal folder. In a folder that holds several MusicBrainz releases (a dump of live shows, say) it is
    /// the release id, or `AlbumKey.untaggedRelease` for the files without one, so each release is its own album.
    public var releaseGroup: String = ""

    public var fileName: String { (relPath as NSString).lastPathComponent }
    public var stem: String { (fileName as NSString).deletingPathExtension }
    public var albumKey: AlbumKey { AlbumKey(artistDir: artistDir, albumDir: albumDir, release: releaseGroup.isEmpty ? nil : releaseGroup) }
}

/// An album is a (artist directory, album directory) pair — the unit of settling, batching and Music import.
/// An album is a source folder — unless that folder holds several MusicBrainz releases, in which case each
/// release is an album of its own and `release` says which (nil = the whole folder).
public struct AlbumKey: Hashable, Codable, Sendable, Comparable {
    public var artistDir: String
    public var albumDir: String
    public var release: String? = nil
    /// The `release` of the files in a split folder that carry no MusicBrainz release id.
    public static let untaggedRelease = "untagged"
    public init(artistDir: String, albumDir: String, release: String? = nil) { self.artistDir = artistDir; self.albumDir = albumDir; self.release = release }
    public var relPath: String { albumDir.isEmpty ? artistDir : artistDir + "/" + albumDir }
    /// The folder this key lives in, whichever release it names.
    public var folder: AlbumKey { AlbumKey(artistDir: artistDir, albumDir: albumDir) }
    public var isUntaggedRemainder: Bool { release == AlbumKey.untaggedRelease }
    /// True when `self` names `other` or the whole folder `other` lives in.
    public func covers(_ other: AlbumKey) -> Bool { self == other || (release == nil && folder == other.folder) }
    public static func < (a: AlbumKey, b: AlbumKey) -> Bool {
        if a.artistDir != b.artistDir { return a.artistDir < b.artistDir }
        if a.albumDir != b.albumDir { return a.albumDir < b.albumDir }
        return (a.release ?? "") < (b.release ?? "")
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
    public var encodedAt: Double? = nil
    public var tagsWrittenAt: Double? = nil
    public var tagPolicy: Int = 0
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
