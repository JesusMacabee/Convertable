import XCTest
@testable import ConvertableCore

/// End-to-end: scan a small local library, plan, run the pipeline into a temp mirror, check the results.
final class PipelineTests: XCTestCase {
    var lib: URL!, mirror: URL!, work: URL!
    var store: Store!

    override func setUpWithError() throws {
        guard Fixtures.available else { throw XCTSkip("fixture library not present") }
        lib = try Fixtures.tempDir("pipe-lib"); mirror = try Fixtures.tempDir("pipe-mirror"); work = try Fixtures.tempDir("pipe-work")
        store = try Store.inMemory()
    }
    override func tearDownWithError() throws { for u in [lib, mirror, work] { try? FileManager.default.removeItem(at: u!) } }

    func add(_ fixture: URL, as rel: String) throws {
        let dst = lib.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: dst)
    }
    func config(concurrency: Int = 3) -> Pipeline.Config {
        Pipeline.Config(sourceRoot: lib.path, mirrorRoot: mirror.path, workDir: work.path, encodeConcurrency: concurrency, artMaxPixels: 600, artJPEGQuality: 0.85, profileID: "ipod-classic")
    }
    func planEverything() throws -> Plan {
        try LibraryScanner(root: lib.path, store: store).fullScan()
        return try Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0).plan(Selection(mode: .everything, ignoreSettle: true))
    }

    func testAlbumRoundTrip() async throws {
        let flacs = Fixtures.all(withExtension: "flac").filter { $0.path.contains("16BIT") }.prefix(3)
        guard flacs.count == 3 else { throw XCTSkip("need 3 CD-rate fixtures") }
        for (i, f) in flacs.enumerated() { try add(f, as: "Larry June/Out The Trunk/0\(i + 1) track.flac") }
        try add(try Fixtures.first("mp3"), as: "Larry June/Out The Trunk/04 bonus.mp3")
        let plan = try planEverything()
        XCTAssertEqual(plan.albums.count, 1); XCTAssertEqual(plan.trackCount, 4)

        let pipeline = Pipeline(config: config(), store: store, shareIO: ShareIO(limit: 2))
        let summary = await pipeline.run(plan, batchID: nil)
        XCTAssertEqual(summary.tracksDone, 4); XCTAssertEqual(summary.tracksFailed, 0)
        XCTAssertTrue(summary.albums[0].complete)

        for i in 1...3 {
            let out = mirror.appendingPathComponent("Larry June/Out The Trunk/0\(i) track.m4a").path
            XCTAssertTrue(FileManager.default.fileExists(atPath: out), "output \(i) exists")
            let info = try TagReader.read(out)
            XCTAssertEqual(info.sampleRate, 44100); XCTAssertNotNil(info.title); XCTAssertEqual(info.pictures.count, 1)
            XCTAssertTrue(Fixtures.contains(out, marker: "iTunSMPB"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("Larry June/Out The Trunk/04 bonus.mp3").path))
        let partials = FileManager.default.enumerator(atPath: mirror.path)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".partial") }
        XCTAssertTrue(partials.isEmpty, "no .partial files left behind")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty, "work dir cleaned")

        // Everything recorded; a second plan has nothing to do.
        XCTAssertEqual(try store.counts().mirrored, 4)
        let again = try Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0).plan(Selection(mode: .everything, ignoreSettle: true))
        XCTAssertTrue(again.albums.isEmpty)
        XCTAssertTrue([32, 34].contains(try store.sourceFile(relPath: "Larry June/Out The Trunk/01 track.flac")?.audioMD5?.count ?? 0), "header MD5 (32) or frame hash (f:+32)")
        XCTAssertNotNil(try store.sourceFile(relPath: "Larry June/Out The Trunk/01 track.flac")?.tagAlbumArtist)
    }

    func testCorruptTrackFailsAloneAndAlbumIsIncomplete() async throws {
        try add(try Fixtures.first("flac", containing: "16BIT"), as: "A/B/01 good.flac")
        try Data((0..<200_000).map { _ in UInt8.random(in: 0...255) }).write(to: lib.appendingPathComponent("A/B/02 bad.flac"))
        let plan = try planEverything()
        var cfg = config(); cfg.maxAttempts = 1
        let summary = await Pipeline(config: cfg, store: store, shareIO: ShareIO(limit: 2)).run(plan, batchID: nil)
        XCTAssertEqual(summary.tracksDone, 1); XCTAssertEqual(summary.tracksFailed, 1)
        XCTAssertFalse(summary.albums[0].complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("A/B/01 good.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("A/B/02 bad.m4a").path))
        let errors = try store.db.query("SELECT message FROM activity WHERE level='error'") { $0.text(0)! }
        XCTAssertEqual(errors.count, 1)
    }

    func testStopBetweenTracksLeavesNothingHalfDone() async throws {
        let flacs = Array(Fixtures.all(withExtension: "flac").prefix(4))
        guard flacs.count == 4 else { throw XCTSkip("need 4 fixtures") }
        for (i, f) in flacs.enumerated() { try add(f, as: "A/B/0\(i + 1).flac") }
        let plan = try planEverything()
        let p = Pipeline(config: config(concurrency: 1), store: store, shareIO: ShareIO(limit: 1))
        let counter = Counter()
        p.onEvent = { if case .trackFinished = $0 { counter.increment() } }
        p.shouldStop = { counter.value >= 1 }
        let summary = await p.run(plan, batchID: nil)
        XCTAssertEqual(summary.endedBy, "user")
        XCTAssertLessThan(summary.tracksDone, 4)
        let outputs = FileManager.default.enumerator(atPath: mirror.path)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".m4a") }
        XCTAssertEqual(outputs.count, summary.tracksDone, "every recorded track is fully published, nothing partial")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}
