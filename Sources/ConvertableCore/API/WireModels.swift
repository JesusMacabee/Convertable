import Foundation

/// Wire models shared by the dashboard, the menu bar and the CLI. All Codable, all plain data.

public enum AppState: String, Codable, Sendable {
    case idle, scanning, converting, paused, batchComplete, attention, volumeUnavailable
}

public struct BatchProgress: Codable, Equatable, Sendable {
    public var id: Int64
    public var selection: String
    public var albumsTotal: Int
    public var albumsDone: Int
    public var tracksTotal: Int
    public var tracksDone: Int
    public var tracksFailed: Int
    public var bytesInTotal: Int64
    public var bytesInDone: Int64
    public var bytesOut: Int64
    public var startedAt: Double
    public var currentAlbum: String?
    public var currentTracks: [String]
    public var backlogAlbums: Int
    public var backlogBytes: Int64
}

public struct Alert: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var level: String      // info | warn | error
    public var message: String
    public var action: String?    // e.g. "openLibrary"
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var state: AppState
    public var volume: String
    public var volumeAvailable: Bool
    public var protocolName: String?
    public var musicLibraryOpen: Bool
    public var musicRunning: Bool
    public var batch: BatchProgress?
    public var library: LibraryCounts
    public var lastFullScan: Double?
    public var lastIncrementalScan: Double?
    public var nextScan: Double?
    public var scanInProgress: String?
    public var pendingApprovals: Int
    public var musicPending: Int
    public var musicImportDisabled: String?
    public var alerts: [Alert]
    public var shareLimit: Int
    public var shareInFlight: Int
    public var uptimeSeconds: Double
}

public struct LibraryCounts: Codable, Equatable, Sendable {
    public var artists: Int, albums: Int, tracks: Int, lossless: Int, lossy: Int, bytes: Int64, mirrored: Int, missing: Int
    public var backlogAlbums: Int, backlogBytes: Int64, settlingAlbums: Int
}

public struct ArtistRow: Codable, Equatable, Sendable {
    public var dir: String, name: String, albums: Int, tracks: Int, bytes: Int64, mirrored: Int, pinned: Bool, status: String
}

public struct AlbumRow: Codable, Equatable, Sendable {
    public var artistDir: String, albumDir: String, name: String, tracks: Int, bytes: Int64, mirrored: Int, lossless: Int, lossy: Int, status: String, firstSeen: Double
}

public struct PlanPreview: Codable, Equatable, Sendable {
    public struct Album: Codable, Equatable, Sendable {
        public var artistDir: String, albumDir: String, artist: String, album: String, tracks: Int, bytesIn: Int64, estimatedOut: Int64, pinned: Bool
    }
    public var selection: Selection
    public var albums: [Album]
    public var overflow: [Album]
    public var bytesIn: Int64, estimatedOut: Int64, tracks: Int
    public var overflowBytes: Int64
    public var backlogAlbums: Int, backlogBytes: Int64
    public var settling: Int, alreadyMirrored: Int, skipped: Int
    public var estimatedSeconds: Double
}

public struct BatchRow: Codable, Equatable, Sendable {
    public var id: Int64, selection: String, budgetBytes: Int64?, bytesIn: Int64, bytesOut: Int64, filesDone: Int, startedAt: Double, finishedAt: Double?, endedBy: String?
}

public struct ActivityRow: Codable, Equatable, Sendable {
    public var id: Int64, at: Double, level: String, category: String, message: String, relPath: String?
}

/// Everything the dashboard can ask the app to do.
public enum Command: Codable, Sendable {
    case scan(full: Bool)
    case startBatch(Selection, exceedCap: Bool)
    case stop
    case pin(artistDir: String, pinned: Bool)
    case importNow
    case enableMusicImport
    case approve(id: Int64)
    case dismiss(id: Int64)
    case indexLegacy
}

/// Pushed over SSE. Kept small; clients refetch details.
public enum Event: Codable, Sendable {
    case status(StatusSnapshot)
    case activity(ActivityRow)
    case batchProgress(BatchProgress)
    case scanProgress(dirs: Int, files: Int, artist: String)
    case heartbeat
}
