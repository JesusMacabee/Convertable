import XCTest
@testable import ConvertableCore

final class PlannerTests: XCTestCase {
    var store: Store!
    let now: Double = 2_000_000

    override func setUpWithError() throws { store = try Store.inMemory() }

    /// Inserts an album of `tracks` files, each `size` bytes, settled long ago unless `fresh`.
    func album(_ artist: String, _ album: String, tracks: Int, size: Int64, ext: String = ".flac", kind: FileKind = .lossless, firstSeen: Double = 1_000_000, fresh: Bool = false) throws {
        for i in 1...tracks {
            try store.db.run("""
                INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan, status)
                VALUES (?,?,?,?,?,?,?,?,?,?,1,'active')
                """, [.text("\(artist)/\(album)/\(i)\(ext)"), .text(artist), .text(album), .text(ext), .text(kind.rawValue), .integer(size), .real(1.0),
                      .real(fresh ? now - 10 : 1_000_000), .integer(fresh ? 1 : 3), .real(firstSeen)])
        }
    }
    func planner() -> Planner {
        var p = Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 120, albumSettleSeconds: 300); p.clock = { self.now }; return p
    }

    func testSizeModeNeverSplitsAlbumsAndReportsBacklog() throws {
        try album("A", "1", tracks: 10, size: 100, firstSeen: 1)      // 1000 bytes, oldest
        try album("B", "1", tracks: 10, size: 100, firstSeen: 2)      // 1000
        try album("C", "1", tracks: 10, size: 100, firstSeen: 3)      // 1000
        let plan = try planner().plan(Selection(mode: .size, cap: 2500))
        XCTAssertEqual(plan.albums.map(\.key.artistDir), ["A", "B"])
        XCTAssertEqual(plan.bytesIn, 2000)
        XCTAssertEqual(plan.backlogAlbums, 1); XCTAssertEqual(plan.backlogBytes, 1000)
        XCTAssertTrue(plan.overflow.isEmpty)
        XCTAssertEqual(plan.estimatedOutBytes, Int64(2000.0 * 0.27))
    }

    func testOversizedSingleAlbumStillFitsWhenFirst() throws {
        try album("Big", "Box", tracks: 10, size: 1000)
        let plan = try planner().plan(Selection(mode: .size, cap: 500))
        XCTAssertEqual(plan.albums.count, 1, "an album larger than the cap is still processed rather than blocking forever")
    }

    func testArtistModeSoftCapProducesOverflowInUserOrder() throws {
        try album("Zed", "1", tracks: 5, size: 100, firstSeen: 1)
        try album("Amy", "1", tracks: 5, size: 100, firstSeen: 5)
        try album("Amy", "2", tracks: 5, size: 100, firstSeen: 6)
        try album("Other", "1", tracks: 5, size: 100)
        let plan = try planner().plan(Selection(mode: .artists(["Amy", "Zed"]), cap: 1000))
        XCTAssertEqual(plan.albums.map { $0.key.relPath }, ["Amy/1", "Amy/2"], "user's artist order wins over first_seen")
        XCTAssertEqual(plan.overflow.map { $0.key.relPath }, ["Zed/1"])
        XCTAssertEqual(plan.overflowBytes, 500)
        XCTAssertEqual(plan.backlogAlbums, 0)
    }

    func testPinnedArtistsGoFirst() throws {
        try album("A", "1", tracks: 2, size: 10, firstSeen: 1)
        try album("Fav", "1", tracks: 2, size: 10, firstSeen: 9)
        try store.pin("Fav", pinned: true)
        let plan = try planner().plan(Selection(mode: .everything))
        XCTAssertEqual(plan.albums.first?.key.artistDir, "Fav")
        XCTAssertTrue(plan.albums.first!.pinned)
    }

    func testSettlingAlbumsAreExcludedUnlessIgnored() throws {
        try album("A", "old", tracks: 2, size: 10)
        try album("A", "new", tracks: 2, size: 10, fresh: true)
        let plan = try planner().plan(Selection(mode: .everything))
        XCTAssertEqual(plan.albums.map(\.key.albumDir), ["old"])
        XCTAssertEqual(plan.ineligible.count, 1)
        if case .settling = plan.ineligible[0].1 {} else { XCTFail("expected settling") }
        let preview = try planner().plan(Selection(mode: .everything, ignoreSettle: true))
        XCTAssertEqual(preview.albums.count, 2)
    }

    func testMirroredTracksAreSkippedAndCompleteAlbumsAreNothingToDo() throws {
        try album("A", "1", tracks: 3, size: 10)
        let ids = try store.db.query("SELECT id FROM source_files ORDER BY id") { $0.int(0)! }
        for id in ids.prefix(2) {
            try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok) VALUES (?, ?, 'x', 1)", [.integer(id), .text("A/1/\(id).m4a")])
        }
        var plan = try planner().plan(Selection(mode: .everything))
        XCTAssertEqual(plan.albums.count, 1); XCTAssertEqual(plan.albums[0].tracks.count, 1, "only the unmirrored track is planned")
        try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok) VALUES (?, ?, 'x', 1)", [.integer(ids[2]), .text("A/1/\(ids[2]).m4a")])
        plan = try planner().plan(Selection(mode: .everything))
        XCTAssertTrue(plan.albums.isEmpty)
        XCTAssertEqual(plan.ineligible.first?.1, .nothingToDo)
    }

    func testLossyIsCopyThroughWithFullSizeEstimate() throws {
        try album("E-40", "Block", tracks: 2, size: 500, ext: ".mp3", kind: .lossy)
        let plan = try planner().plan(Selection(mode: .everything))
        XCTAssertEqual(plan.albums[0].tracks[0].action, .copyThrough)
        XCTAssertEqual(plan.estimatedOutBytes, 1000)
        XCTAssertEqual(plan.albums[0].tracks[0].outputRelPath, "E-40/Block/1.mp3")
    }

    func testAlbumModeExactSelection() throws {
        try album("A", "1", tracks: 2, size: 10); try album("A", "2", tracks: 2, size: 10)
        let plan = try planner().plan(Selection(mode: .albums([AlbumKey(artistDir: "A", albumDir: "2")])))
        XCTAssertEqual(plan.albums.map(\.key.albumDir), ["2"])
    }
}
