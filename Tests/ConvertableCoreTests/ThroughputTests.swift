import XCTest
@testable import ConvertableCore

final class ThroughputTests: XCTestCase {
    func testLearnedThroughputWeightsRecentBatchesAndIgnoresNoise() throws {
        let store = try Store.inMemory()
        func batch(_ id: Int, bytes: Int64, seconds: Double) throws {
            try store.db.run("INSERT INTO batches (id, selection_json, started_at, finished_at, bytes_in, bytes_out, files_done, ended_by) VALUES (?, '{}', ?, ?, ?, 0, 1, 'empty')",
                             [.integer(Int64(id)), .real(1000), .real(1000 + seconds), .integer(bytes)])
        }
        XCTAssertNil(try store.learnedThroughput(), "nothing finished yet")
        try batch(1, bytes: 50_000_000, seconds: 3)           // tiny: ignored as noise
        XCTAssertNil(try store.learnedThroughput())
        try batch(2, bytes: 10_000_000_000, seconds: 1000)    // 10 MB/s — the slow-network era
        XCTAssertEqual(try store.learnedThroughput()?.bytesPerSecond ?? 0, 10_000_000, accuracy: 1)
        XCTAssertEqual(try store.learnedThroughput()?.batches, 1)
        try batch(3, bytes: 10_000_000_000, seconds: 100)     // 100 MB/s — after the network fix
        let t = try XCTUnwrap(try store.learnedThroughput())
        XCTAssertEqual(t.batches, 2)
        // Newest weighted 1.0, older 0.6: (100 + 0.6 × 10) / 1.6 = 66.25 MB/s — already leaning toward the new rate.
        XCTAssertEqual(t.bytesPerSecond, 66_250_000, accuracy: 1)
        try batch(4, bytes: 10_000_000_000, seconds: 100)
        try batch(5, bytes: 10_000_000_000, seconds: 100)
        XCTAssertGreaterThan(try store.learnedThroughput()!.bytesPerSecond, 85_000_000, "a few fast batches later the old rate has mostly faded")
    }
}
