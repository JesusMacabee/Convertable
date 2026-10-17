import XCTest
@testable import ConvertableCore

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var s = Settings()
        s.batchBudgetBytes = 50_000_000_000
        s.autoContinue = .window(startHour: 1, endHour: 7)
        s.importMethod = .autoAddFolder
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("convertable-\(UUID()).json")
        try s.save(to: url)
        let back = try Settings.load(from: url)
        XCTAssertEqual(back, s)
    }

    func testMissingFileGivesDefaults() throws {
        var s = try Settings.load(from: URL(fileURLWithPath: "/nonexistent/settings.json"))
        var d = Settings()
        // Each fresh Settings gets a random web token; equality is about everything else.
        s.web.token = "x"; d.web.token = "x"
        XCTAssertEqual(s, d)
    }

    func testOlderSettingsFileWithMissingKeysLoads() throws {
        let json = #"{"sourceRoot":"/x","web":{"port":9000,"allowLAN":false,"token":"t"}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.sourceRoot, "/x"); XCTAssertEqual(s.web.port, 9000)
        XCTAssertEqual(s.legacyMediaRoots, Settings().legacyMediaRoots, "new keys take defaults")
        XCTAssertEqual(s.batchBudgetBytes, nil, "absent optional stays nil")
    }

    func testLibraryURLStringMatchesMusicFormat() {
        var s = Settings()
        s.musicLibraryPath = "/Volumes/Media/AAC Music/Music Library.musiclibrary"
        XCTAssertEqual(s.musicLibraryFileURLString, "file:///Volumes/Media/AAC%20Music/Music%20Library.musiclibrary/")
        XCTAssertEqual(Settings().musicLibraryFileURLString, "", "an unset library must not resolve to the working directory")
    }

    /// A fresh install must not inherit anyone's library layout: the locations start empty and the app
    /// reports itself unconfigured until the wizard fills them in.
    func testFreshSettingsHaveNoLocations() {
        let s = Settings()
        XCTAssertEqual(s.sourceRoot, ""); XCTAssertEqual(s.mirrorRoot, ""); XCTAssertEqual(s.musicLibraryPath, "")
        XCTAssertEqual(s.legacyMediaRoots, [])
        XCTAssertFalse(s.isConfigured)
        XCTAssertEqual(s.missingLocations, ["source folder", "mirror folder", "Music library"])
        var done = s; done.sourceRoot = "/a"; done.mirrorRoot = "/b"; done.musicLibraryPath = "/c.musiclibrary"
        XCTAssertTrue(done.isConfigured)
        XCTAssertEqual(Doctor.run(settings: s, benchmark: false).first?.name, "Setup")
    }
}

final class SetupProbeTests: XCTestCase {
    func testMirrorInsideMusicMediaFolderIsRejected() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID())").path
        try? FileManager.default.createDirectory(atPath: tmp + "/Lib/Media.localized", withIntermediateDirectories: true)
        let lib = tmp + "/Lib/Music Library.musiclibrary"
        XCTAssertFalse(Setup.probeMirror(tmp + "/Lib/Media.localized/Music/Mirror", musicLibraryPath: lib).ok)
        XCTAssertTrue(Setup.probeMirror(tmp + "/Lib/Lossless Mirror", musicLibraryPath: lib).ok)
        XCTAssertFalse(Setup.probeMirror("/nonexistent/x/Mirror", musicLibraryPath: lib).ok)
    }
    func testDependenciesListRequiredEncoder() {
        let d = Setup.dependencies()
        XCTAssertTrue(d.first { $0.name.hasPrefix("afconvert") }!.present)
        XCTAssertEqual(d.filter(\.required).count, 2)
    }
    func testSourceProbeOnMissingPath() {
        XCTAssertFalse(Setup.probeSource("/Volumes/Nope/Music").ok)
    }
}
