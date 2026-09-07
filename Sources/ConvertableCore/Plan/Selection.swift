import Foundation

/// What the user asked to convert this batch.
public struct Selection: Codable, Equatable, Sendable {
    public enum Mode: Codable, Equatable, Sendable {
        case artists([String])          // artist directories
        case albums([AlbumKey])
        case size                       // budget-driven: oldest eligible albums first
        case everything
    }
    public var mode: Mode
    /// Source-byte cap. For `.size` it defines the batch; for the others it is a soft cap the user may exceed.
    public var cap: Int64?
    /// Preview aid: treat not-yet-settled albums as eligible.
    public var ignoreSettle: Bool = false

    public init(mode: Mode, cap: Int64? = nil, ignoreSettle: Bool = false) {
        self.mode = mode; self.cap = cap; self.ignoreSettle = ignoreSettle
    }

    public var description: String {
        let capText = cap.map { ", cap \(ByteCount.string($0))" } ?? ""
        switch mode {
        case let .artists(a): return "\(a.count) artist(s)\(capText)"
        case let .albums(a): return "\(a.count) album(s)\(capText)"
        case .size: return "by size: \(cap.map(ByteCount.string) ?? "unlimited")"
        case .everything: return "everything\(capText)"
        }
    }
}

public struct PlannedTrack: Equatable, Sendable {
    public var source: SourceFile
    public var action: Action
    public var outputRelPath: String
    public var estimatedOutBytes: Int64
    /// Set when a verified output already exists but the source changed since — retag or re-encode, decided by hashing.
    public var existingOutput: OutputFile? = nil
}

public struct PlannedAlbum: Equatable, Sendable {
    public var key: AlbumKey
    public var displayArtist: String
    public var displayAlbum: String
    public var tracks: [PlannedTrack]
    public var pinned: Bool
    public var firstSeen: Double
    public var bytesIn: Int64 { tracks.reduce(0) { $0 + $1.source.size } }
    public var estimatedOutBytes: Int64 { tracks.reduce(0) { $0 + $1.estimatedOutBytes } }
}

public struct Plan: Sendable {
    public enum Ineligibility: Equatable, Sendable { case settling(secondsLeft: Int), nothingToDo, allSkipped, needsTagging(untagged: Int), auditing }

    public var selection: Selection
    public var albums: [PlannedAlbum]               // fits within the cap, in processing order
    public var overflow: [PlannedAlbum]             // selected but beyond the cap (soft-cap modes)
    public var ineligible: [(AlbumKey, Ineligibility)]
    public var backlogAlbums: Int                   // eligible albums not in this plan (size/everything modes)
    public var backlogBytes: Int64

    public var bytesIn: Int64 { albums.reduce(0) { $0 + $1.bytesIn } }
    public var estimatedOutBytes: Int64 { albums.reduce(0) { $0 + $1.estimatedOutBytes } }
    public var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    public var overflowBytes: Int64 { overflow.reduce(0) { $0 + $1.bytesIn } }
}
