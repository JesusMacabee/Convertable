import XCTest
@testable import ConvertableCore

/// Scripted stand-in for osascript: records scripts, answers from a queue.
final class MockRunner: MusicScripting, @unchecked Sendable {
    let lock = NSLock()
    var scripts: [String] = []
    var answers: [(String) -> Result<String, MusicError>] = []
    func run(_ script: String, timeout: TimeInterval) throws -> String {
        lock.lock(); defer { lock.unlock() }
        scripts.append(script)
        guard !answers.isEmpty else { return "" }
        return try answers.removeFirst()(script).get()
    }
}

final class MusicBridgeTests: XCTestCase {
    func testQuoteEscapes() {
        XCTAssertEqual(MusicBridge.quote(#"Rock "n" Roll\Path"#), #""Rock \"n\" Roll\\Path""#)
        XCTAssertEqual(MusicBridge.quote("Cam’ron/It's"), "\"Cam’ron/It's\"")
    }
    func testAddParsesPersistentIDAndLocation() throws {
        let m = MockRunner()
        m.answers = [{ _ in .success("ABCDEF0123456789\u{1F}/Volumes/X/a.m4a") }]
        let r = try MusicBridge(runner: m).add(path: "/Volumes/X/a.m4a")
        XCTAssertEqual(r.persistentID, "ABCDEF0123456789"); XCTAssertEqual(r.location, "/Volumes/X/a.m4a")
        XCTAssertTrue(m.scripts[0].contains("POSIX file \"/Volumes/X/a.m4a\""))
        XCTAssertTrue(m.scripts[0].contains("add ("))
    }
    func testAddRejectsGarbage() {
        let m = MockRunner(); m.answers = [{ _ in .success("nonsense") }]
        XCTAssertThrowsError(try MusicBridge(runner: m).add(path: "/x"))
    }
    func testFileTracksParsing() throws {
        let m = MockRunner()
        m.answers = [{ _ in .success("P1\u{1F}/Volumes/M/a.m4a\nP2\u{1F}\nP3\u{1F}/Volumes/M/b.m4a") }]
        let t = try MusicBridge(runner: m).fileTracks()
        XCTAssertEqual(t.map(\.persistentID), ["P1", "P2", "P3"]); XCTAssertEqual(t[1].path, "")
    }
}

final class MusicImporterTests: XCTestCase {
    var store: Store!
    var settings = Settings()
    let mirror = "/Volumes/M/Mirror"

    override func setUpWithError() throws {
        store = try Store.inMemory()
        settings.mirrorRoot = mirror
        settings.importMethod = .appleScript
    }

    /// Album with `tracks` sources; the first `outputs` of them get verified outputs.
    func album(_ artist: String, _ album: String, tracks: Int, outputs: Int) throws {
        for i in 1...tracks {
            let id = try store.db.insert("""
                INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan)
                VALUES (?,?,?,'.flac','lossless',10,1,1,3,1,1)
                """, [.text("\(artist)/\(album)/\(i).flac"), .text(artist), .text(album)])
            if i <= outputs {
                try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok) VALUES (?,?,'ipod-classic',1)", [.integer(id), .text("\(artist)/\(album)/\(i).m4a")])
            }
        }
    }
    func importer(_ m: MockRunner, gateOK: Bool = true) -> MusicImporter {
        MusicImporter(store: store, settings: settings, profile: .ipodClassic, bridge: MusicBridge(runner: m),
                      gate: { gateOK ? .success(()) : .failure(.wrongLibraryOpen("other")) })
    }

    func testOnlyCompleteAlbumsArePending() throws {
        try album("A", "done", tracks: 3, outputs: 3)
        try album("A", "half", tracks: 3, outputs: 2)
        let p = try importer(MockRunner()).pendingAlbums()
        XCTAssertEqual(p.keys.map(\.albumDir), ["done"])
        XCTAssertEqual(p.values.first?.count, 3)
    }

    func testDrainAddsAndRecordsPersistentIDs() throws {
        try album("A", "done", tracks: 2, outputs: 2)
        let m = MockRunner()
        m.answers = [
            { s in .success("PID1\u{1F}" + self.mirror + "/A/done/1.m4a") },
            { s in .success("PID2\u{1F}" + self.mirror + "/A/done/2.m4a") },
        ]
        let o = importer(m).drain()
        XCTAssertEqual(o.added, 2); XCTAssertEqual(o.failed, 0); XCTAssertNil(o.disabledReason)
        let pids = try store.db.query("SELECT music_persistent_id FROM outputs ORDER BY id") { $0.text(0) }
        XCTAssertEqual(pids, ["PID1", "PID2"])
        XCTAssertEqual(importer(m).pendingCount(), 0)
    }

    func testDrainWaitsWhenWrongLibraryIsOpen() throws {
        try album("A", "done", tracks: 1, outputs: 1)
        let m = MockRunner()
        let o = importer(m, gateOK: false).drain()
        XCTAssertEqual(o.added, 0); XCTAssertTrue(m.scripts.isEmpty, "no AppleScript runs against the wrong library")
        XCTAssertTrue(o.messages[0].contains("different library"))
    }

    func testCopySettingDetectedStopsImportAndUndoes() throws {
        try album("A", "done", tracks: 2, outputs: 2)
        let m = MockRunner()
        m.answers = [
            { _ in .success("PIDX\u{1F}/Users/me/Music/Media.localized/Music/A/done/1.m4a") },   // Music copied it
            { _ in .success("") },                                                                // our remove
        ]
        let o = importer(m).drain()
        XCTAssertEqual(o.added, 0)
        XCTAssertNotNil(o.disabledReason); XCTAssertTrue(o.disabledReason!.contains("Copy files to Music Media folder"))
        XCTAssertEqual(m.scripts.count, 2); XCTAssertTrue(m.scripts[1].contains("delete"))
        XCTAssertTrue(m.scripts[1].contains("PIDX"))
        let pids = try store.db.query("SELECT music_persistent_id FROM outputs") { $0.text(0) }
        XCTAssertEqual(pids, [nil, nil], "nothing recorded as imported")
    }

    func testFailuresCountAttemptsAndBackOff() throws {
        try album("A", "done", tracks: 5, outputs: 5)
        let m = MockRunner()
        m.answers = Array(repeating: { _ in .failure(.script("AppleEvent timed out")) }, count: 5)
        let o = importer(m).drain()
        XCTAssertEqual(o.failed, 3, "stops hammering Music after three consecutive failures")
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM outputs WHERE music_attempts = 1"), .integer(3))
    }

    func testReconcileMapsTracksUnderMirror() throws {
        try album("A", "done", tracks: 2, outputs: 2)
        let m = MockRunner()
        m.answers = [{ _ in .success("P1\u{1F}\(self.mirror)/A/done/1.m4a\nP9\u{1F}\(self.mirror)/A/done/stray.m4a\nPZ\u{1F}/elsewhere/x.m4a") }]
        let r = try importer(m).reconcile()
        XCTAssertEqual(r.matched, 1); XCTAssertEqual(r.unknownInMirror, 1)
        XCTAssertEqual(try store.db.scalar("SELECT music_persistent_id FROM outputs WHERE rel_path='A/done/1.m4a'"), .text("P1"))
    }

    func testSamePathIsCaseAndSymlinkInsensitive() {
        XCTAssertTrue(MusicImporter.samePath("/Volumes/X/A.m4a", "/Volumes/X/a.m4a"))
        XCTAssertFalse(MusicImporter.samePath("/Volumes/X/a.m4a", "/Volumes/Y/a.m4a"))
    }
}
