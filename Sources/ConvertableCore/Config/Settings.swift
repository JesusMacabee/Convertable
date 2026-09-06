import Foundation

/// How converted files are handed to Music.app.
public enum ImportMethod: String, Codable, CaseIterable, Sendable {
    /// `add POSIX file …` — Music references the mirror file in place. Requires
    /// "Copy files to Music Media folder" to be off in that library.
    case appleScript
    /// Drop the finished file into the library's "Automatically Add to Music" folder.
    /// Music moves it into its own media folder; the mirror folder is transient.
    case autoAddFolder
}

public enum AutoContinue: Codable, Equatable, Sendable {
    case off
    case on
    /// Only continue automatically between `startHour` and `endHour` (24h, local time; may wrap midnight).
    case window(startHour: Int, endHour: Int)
}

public struct WebSettings: Codable, Equatable, Sendable {
    public var port: Int = 8765
    public var allowLAN: Bool = false
    /// Random access token; regenerated on demand from Settings.
    public var token: String = WebSettings.newToken()

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Everything the user can configure. Persisted as JSON in Application Support.
public struct Settings: Codable, Equatable, Sendable {
    // Locations
    public var sourceRoot: String = "/Volumes/PLeX/Music/New Tunes"
    public var mirrorRoot: String = "/Volumes/PLeX/Music/AAC Music/Lossless Mirror"
    /// The `.musiclibrary` bundle the iPod is paired to.
    public var musicLibraryPath: String = "/Volumes/PLeX/Music/AAC Music/Music Library.musiclibrary"
    /// Optional server URL (smb://, afp://, nfs://) used only when `autoMount` is on.
    public var shareURL: String? = nil
    public var autoMount: Bool = false

    // Music.app
    public var importMethod: ImportMethod = .appleScript

    // Legacy library (pre-existing lossy files in the Music library, not derived from the source tree)
    public var legacyMediaRoots: [String] = ["/Volumes/PLeX/Music/AAC Music/Music/Music", "/Volumes/PLeX/Music/AAC Music/Music/Media.localized/Music"]
    public var supersedeEnabled: Bool = true

    // Scanning
    public var incrementalScanMinutes: Int = 10
    public var fullScanHour: Int = 4
    public var fileSettleSeconds: Int = 120
    public var albumSettleSeconds: Int = 300

    // Throughput
    public var encodeConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    /// Overrides the protocol-derived share concurrency when set.
    public var shareConcurrencyOverride: Int? = nil

    // Batches
    /// nil = unlimited. Measured in source bytes.
    public var batchBudgetBytes: Int64? = 25 * 1_000_000_000
    public var autoContinue: AutoContinue = .off

    // Output
    public var profileID: String = "ipod-classic"
    public var artMaxPixels: Int = 600
    public var artJPEGQuality: Double = 0.85
    public var quarantineRetentionDays: Int = 30

    // App
    public var web: WebSettings = WebSettings()
    public var launchAtLogin: Bool = false

    public init() {}

    /// Tolerant decoding: any key missing from an older settings file takes its default, so upgrades never fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        sourceRoot = try c.decodeIfPresent(String.self, forKey: .sourceRoot) ?? d.sourceRoot
        mirrorRoot = try c.decodeIfPresent(String.self, forKey: .mirrorRoot) ?? d.mirrorRoot
        musicLibraryPath = try c.decodeIfPresent(String.self, forKey: .musicLibraryPath) ?? d.musicLibraryPath
        shareURL = try c.decodeIfPresent(String.self, forKey: .shareURL)
        autoMount = try c.decodeIfPresent(Bool.self, forKey: .autoMount) ?? d.autoMount
        importMethod = try c.decodeIfPresent(ImportMethod.self, forKey: .importMethod) ?? d.importMethod
        legacyMediaRoots = try c.decodeIfPresent([String].self, forKey: .legacyMediaRoots) ?? d.legacyMediaRoots
        supersedeEnabled = try c.decodeIfPresent(Bool.self, forKey: .supersedeEnabled) ?? d.supersedeEnabled
        incrementalScanMinutes = try c.decodeIfPresent(Int.self, forKey: .incrementalScanMinutes) ?? d.incrementalScanMinutes
        fullScanHour = try c.decodeIfPresent(Int.self, forKey: .fullScanHour) ?? d.fullScanHour
        fileSettleSeconds = try c.decodeIfPresent(Int.self, forKey: .fileSettleSeconds) ?? d.fileSettleSeconds
        albumSettleSeconds = try c.decodeIfPresent(Int.self, forKey: .albumSettleSeconds) ?? d.albumSettleSeconds
        encodeConcurrency = try c.decodeIfPresent(Int.self, forKey: .encodeConcurrency) ?? d.encodeConcurrency
        shareConcurrencyOverride = try c.decodeIfPresent(Int.self, forKey: .shareConcurrencyOverride)
        batchBudgetBytes = try c.decodeIfPresent(Int64.self, forKey: .batchBudgetBytes)
        autoContinue = try c.decodeIfPresent(AutoContinue.self, forKey: .autoContinue) ?? d.autoContinue
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? d.profileID
        artMaxPixels = try c.decodeIfPresent(Int.self, forKey: .artMaxPixels) ?? d.artMaxPixels
        artJPEGQuality = try c.decodeIfPresent(Double.self, forKey: .artJPEGQuality) ?? d.artJPEGQuality
        quarantineRetentionDays = try c.decodeIfPresent(Int.self, forKey: .quarantineRetentionDays) ?? d.quarantineRetentionDays
        web = try c.decodeIfPresent(WebSettings.self, forKey: .web) ?? d.web
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }

    // MARK: Persistence

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Convertable", isDirectory: true)
    }

    public static var defaultURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var defaultDatabaseURL: URL { supportDirectory.appendingPathComponent("state.sqlite") }

    public static func load(from url: URL = defaultURL) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Settings.self, from: data)
    }

    public func save(to url: URL = Settings.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        // Write atomically so a crash mid-save never leaves a truncated settings file.
        try data.write(to: url, options: .atomic)
    }

    /// Music stores the open library as a file URL string in its preferences.
    public var musicLibraryFileURLString: String {
        var url = URL(fileURLWithPath: musicLibraryPath, isDirectory: true).absoluteString
        if !url.hasSuffix("/") { url += "/" }
        return url
    }
}
