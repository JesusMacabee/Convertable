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

    func testLibraryURLStringMatchesMusicFormat() {
        var s = Settings()
        s.musicLibraryPath = "/Volumes/PLeX/Music/AAC Music/Music Library.musiclibrary"
        XCTAssertEqual(s.musicLibraryFileURLString, "file:///Volumes/PLeX/Music/AAC%20Music/Music%20Library.musiclibrary/")
    }
}
