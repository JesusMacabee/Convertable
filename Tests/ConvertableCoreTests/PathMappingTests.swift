import XCTest
@testable import ConvertableCore

final class PathMappingTests: XCTestCase {
    func testTranscodeSwapsExtensionOnly() {
        XCTAssertEqual(PathMapping.outputRelPath(source: "A/B/01 x.flac", action: .transcode(.ipodAAC)), "A/B/01 x.m4a")
        XCTAssertEqual(PathMapping.outputRelPath(source: "A/B/CD 01/01.flac", action: .transcode(.mp3_320)), "A/B/CD 01/01.mp3")
    }
    func testCopyThroughKeepsPath() {
        XCTAssertEqual(PathMapping.outputRelPath(source: "A/B/01.mp3", action: .copyThrough), "A/B/01.mp3")
    }
    func testCollisionsGetSuffixDeterministically() {
        let m = PathMapping.outputRelPaths(for: [("A/B/x.mp3", .copyThrough), ("A/B/x.flac", .transcode(.ipodAAC)), ("A/B/x.m4a", .copyThrough), ("A/B/y.flac", .skip)])
        // Sorted: x.flac → x.m4a first; x.m4a (copy) collides → x (2).m4a; x.mp3 unaffected; y skipped.
        XCTAssertEqual(m["A/B/x.flac"], "A/B/x.m4a")
        XCTAssertEqual(m["A/B/x.m4a"], "A/B/x (2).m4a")
        XCTAssertEqual(m["A/B/x.mp3"], "A/B/x.mp3")
        XCTAssertNil(m["A/B/y.flac"])
    }
    func testCaseInsensitiveCollision() {
        let m = PathMapping.outputRelPaths(for: [("A/x.flac", .transcode(.ipodAAC)), ("A/X.wav", .transcode(.ipodAAC))])
        XCTAssertEqual(Set(m.values.map { $0.lowercased() }).count, 2)
    }
    func testByteParser() {
        XCTAssertEqual(ByteParser.parse("25GB"), 25_000_000_000)
        XCTAssertEqual(ByteParser.parse("1.5 TB"), 1_500_000_000_000)
        XCTAssertEqual(ByteParser.parse("800mb"), 800_000_000)
        XCTAssertEqual(ByteParser.parse("12345"), 12345)
        XCTAssertNil(ByteParser.parse("lots"))
    }
}
