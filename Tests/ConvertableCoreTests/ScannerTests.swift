import XCTest
@testable import ConvertableCore

/// Builds a throwaway library tree and drives the scanner through add / change / delete / settle scenarios.
final class ScannerTests: XCTestCase {
    var root: URL!
    var store: Store!
    var now: Double = 1_000_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("convertable-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try Store.inMemory()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ rel: String, bytes: Int = 100) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }
    func scanner() -> LibraryScanner { let s = LibraryScanner(root: root.path, store: store); s.clock = { self.now }; return s }

    func testFullScanClassifiesAndIgnoresNonAudio() throws {
        try write("Adele/21/01 Rolling.flac"); try write("Adele/21/02 Rumour.flac"); try write("Adele/21/cover.jpg"); try write("Adele/21/rip.log")
        try write("E-40/Block/05 Catch.mp3"); try write("Loose/track.wav"); try write("root.flac")
        let p = try scanner().fullScan()
        XCTAssertEqual(p.audio, 5); XCTAssertEqual(p.added, 5); XCTAssertEqual(p.files, 7)
        let c = try store.counts()
        XCTAssertEqual(c.active, 5); XCTAssertEqual(c.lossless, 4); XCTAssertEqual(c.lossy, 1)
        let f = try store.sourceFile(relPath: "Adele/21/01 Rolling.flac")!
        XCTAssertEqual(f.artistDir, "Adele"); XCTAssertEqual(f.albumDir, "21"); XCTAssertEqual(f.kind, .lossless)
        XCTAssertEqual(try store.sourceFile(relPath: "Loose/track.wav")!.albumDir, "")
        XCTAssertEqual(try store.sourceFile(relPath: "root.flac")!.artistDir, "")
    }

    func testMultiDiscBelongsToAlbum() throws {
        try write("2Pac/All Eyez/CD 01/01.flac"); try write("2Pac/All Eyez/CD 02/01.flac")
        try scanner().fullScan()
        let a = try store.albumSummaries()
        XCTAssertEqual(a.count, 1); XCTAssertEqual(a[0].key, AlbumKey(artistDir: "2Pac", albumDir: "All Eyez")); XCTAssertEqual(a[0].tracks, 2)
    }

    func testSettleBookkeeping() throws {
        try write("A/B/01.flac")
        try scanner().fullScan()
        var f = try store.sourceFile(relPath: "A/B/01.flac")!
        XCTAssertEqual(f.observations, 1); XCTAssertEqual(f.stableSince, now)
        now += 600; try scanner().fullScan()
        f = try store.sourceFile(relPath: "A/B/01.flac")!
        XCTAssertEqual(f.observations, 2); XCTAssertEqual(f.stableSince, 1_000_000)
        // File grows (still being copied) → reset.
        try write("A/B/01.flac", bytes: 5000); now += 600; try scanner().fullScan()
        f = try store.sourceFile(relPath: "A/B/01.flac")!
        XCTAssertEqual(f.observations, 1); XCTAssertEqual(f.stableSince, now); XCTAssertEqual(f.size, 5000)
    }

    func testDeletionMarksMissingAndReappearanceRestores() throws {
        try write("A/B/01.flac"); try write("A/B/02.flac")
        try scanner().fullScan()
        try FileManager.default.removeItem(at: root.appendingPathComponent("A/B/02.flac"))
        now += 60; let p = try scanner().fullScan()
        XCTAssertEqual(p.missing, 1)
        XCTAssertEqual(try store.sourceFile(relPath: "A/B/02.flac")!.status, .missing)
        XCTAssertEqual(try store.counts().active, 1)
        try write("A/B/02.flac"); now += 60; let p2 = try scanner().fullScan()
        XCTAssertEqual(p2.reappeared + p2.changed, 1)
        XCTAssertEqual(try store.sourceFile(relPath: "A/B/02.flac")!.status, .active)
    }

    func testIncrementalScanPicksUpNewAlbumAndDeletedFile() throws {
        try write("A/B/01.flac"); try write("C/D/01.flac")
        try scanner().fullScan()
        XCTAssertEqual(try store.counts().directories, 5) // root, A, A/B, C, C/D
        // New album under an existing artist (bumps A's mtime) and a whole new artist (bumps root's mtime).
        sleep(1)  // ensure directory mtimes move
        try write("A/E/01.flac"); try write("A/E/02.flac"); try write("N/M/01.flac")
        try FileManager.default.removeItem(at: root.appendingPathComponent("C/D/01.flac"))
        now += 600
        let p = try scanner().incrementalScan()
        XCTAssertEqual(p.added, 3, "new files found via directory mtimes")
        XCTAssertEqual(p.missing, 1)
        XCTAssertEqual(try store.counts().active, 4)
        XCTAssertEqual(try store.sourceFile(relPath: "N/M/01.flac")?.status, .active)
        XCTAssertEqual(try store.sourceFile(relPath: "C/D/01.flac")?.status, .missing)
        XCTAssertEqual(try store.counts().directories, 8) // + A/E, N, N/M
    }

    func testIncrementalScanConfirmsSettleForUntouchedFilesAndCatchesGrowth() throws {
        try write("A/B/01.flac"); try write("A/B/02.flac", bytes: 100)
        try scanner().fullScan()
        XCTAssertEqual(try store.sourceFile(relPath: "A/B/01.flac")!.observations, 1)
        // 02 keeps growing (a slow copy); 01 is done. Directory mtime does not change for either.
        try write("A/B/02.flac", bytes: 900)
        now += 600
        try scanner().incrementalScan()
        XCTAssertEqual(try store.sourceFile(relPath: "A/B/01.flac")!.observations, 2, "untouched file confirmed without a full scan")
        let growing = try store.sourceFile(relPath: "A/B/02.flac")!
        XCTAssertEqual(growing.observations, 1, "a growing file is not confirmed"); XCTAssertEqual(growing.size, 900)
        now += 600
        try scanner().incrementalScan()
        XCTAssertEqual(try store.sourceFile(relPath: "A/B/02.flac")!.observations, 2)
    }

    func testFullScanResumesFromCheckpoint() throws {
        for a in ["A", "B", "C", "D"] { try write("\(a)/X/01.flac") }
        let s = scanner()
        // Cancel once artist "B" has been committed, so the checkpoint is "B" and C/D remain.
        var cancel = false
        s.onProgress = { p in if p.currentArtist == "B" { cancel = true } }
        s.isCancelled = { cancel }
        XCTAssertThrowsError(try s.fullScan())
        let unfinished = try store.unfinishedFullScan()
        XCTAssertEqual(unfinished?.checkpoint, "B")
        let before = try store.counts().active
        XCTAssertEqual(before, 2)
        let s2 = scanner()
        let p = try s2.fullScan()
        XCTAssertEqual(try store.counts().active, 4)
        XCTAssertEqual(p.added, 4 - before, "resume only visits artists after the checkpoint")
        XCTAssertNil(try store.unfinishedFullScan())
    }

    func testMissingRootIsAVolumeErrorNotMassDeletion() throws {
        try write("A/B/01.flac"); try scanner().fullScan()
        let gone = LibraryScanner(root: root.path + "/nonexistent", store: store)
        XCTAssertThrowsError(try gone.fullScan())
        XCTAssertEqual(try store.counts().active, 1, "nothing marked missing when the root is unavailable")
    }

    func testM4ASniffOnFixture() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/library")
        guard let e = FileManager.default.enumerator(at: fixtures, includingPropertiesForKeys: nil) else { throw XCTSkip("no fixtures") }
        let m4a = e.compactMap { $0 as? URL }.first { $0.pathExtension == "m4a" }
        guard let m4a else { throw XCTSkip("no m4a fixture") }
        XCTAssertEqual(MP4Sniff.codec(ofFileAt: m4a.path), "mp4a")
    }
}
