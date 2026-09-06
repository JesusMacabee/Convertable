import XCTest
@testable import ConvertableCore

final class DatabaseTests: XCTestCase {
    func testMigrateFreshDatabase() throws {
        let db = try Database.inMemory()
        try Schema.migrate(db)
        XCTAssertEqual(db.userVersion, Schema.currentVersion)
        // Re-running is a no-op.
        try Schema.migrate(db)
        XCTAssertEqual(db.userVersion, Schema.currentVersion)
    }

    func testInsertAndQuery() throws {
        let db = try Database.inMemory()
        try Schema.migrate(db)
        try db.run("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, first_seen, last_seen_scan) VALUES (?,?,?,?,?,?,?,?,?)",
                   ["A/B/01.flac", "A", "B", ".flac", "lossless", 12345, 1.0, 2.0, 1])
        let rows = try db.query("SELECT rel_path, size, kind FROM source_files") { r in (r.text("rel_path")!, r.int("size")!, r.text("kind")!) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, "A/B/01.flac")
        XCTAssertEqual(rows[0].1, 12345)
        XCTAssertEqual(rows[0].2, "lossless")
    }

    func testConstraintsAreEnforced() throws {
        let db = try Database.inMemory()
        try Schema.migrate(db)
        XCTAssertThrowsError(try db.run("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, first_seen, last_seen_scan) VALUES (?,?,?,?,?,?,?,?,?)",
                                        ["x", "A", "B", ".flac", "bogus-kind", 1, 1.0, 1.0, 1]))
    }

    func testTransactionRollsBack() throws {
        let db = try Database.inMemory()
        try Schema.migrate(db)
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO pins (artist_dir, pinned_at) VALUES ('A', 1.0)")
            throw Boom()
        })
        let n = try db.scalar("SELECT COUNT(*) FROM pins")
        XCTAssertEqual(n, .integer(0))
    }
}
