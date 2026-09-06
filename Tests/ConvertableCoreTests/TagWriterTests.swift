import XCTest
@testable import ConvertableCore

final class TagWriterTests: XCTestCase {
    func testAfconvertOutputGetsFullTagsAndKeepsGaplessAtom() throws {
        let src = try Fixtures.first("flac", containing: "24BIT")
        let tmp = try Fixtures.tempDir("tagwriter"); defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("out.m4a").path
        try AfconvertEncoder().encode(.ipodAAC, input: src.path, output: out, sourceChannels: 2)
        XCTAssertTrue(Fixtures.contains(out, marker: "iTunSMPB"), "afconvert wrote the gapless atom")

        let info = try TagReader.read(src.path)
        let carried = info.properties.filter { TagPolicy.isCarried($0.key) }
        let art = Artwork.downscale(info.pictures[0].data, maxPixels: 600, jpegQuality: 0.85)!
        try TagWriter.write(path: out, properties: carried, picture: art.data, encoderStamp: Encoders.stamp(.ipodAAC))

        let back = try TagReader.read(out)
        XCTAssertEqual(back.title, info.title)
        XCTAssertEqual(back.albumArtist, info.albumArtist)
        XCTAssertEqual(back.first("MUSICBRAINZ_ALBUMID"), info.first("MUSICBRAINZ_ALBUMID"), "Picard IDs travel via the iTunes freeform atom")
        XCTAssertEqual(back.first("DATE"), info.first("DATE"))
        XCTAssertEqual(back.first("ENCODEDBY"), "Convertable (AAC 256k CVBR @44.1 kHz)")
        XCTAssertNil(back.first("ENCODER"), "ffmpeg leftovers are not carried")
        XCTAssertEqual(back.pictures.count, 1)
        let dims = Artwork.dimensions(back.pictures[0].data)!
        XCTAssertLessThanOrEqual(max(dims.0, dims.1), 600)
        XCTAssertEqual(back.sampleRate, 44100)
        XCTAssertTrue(Fixtures.contains(out, marker: "iTunSMPB"), "tag rewrite preserved iTunSMPB")
        XCTAssertTrue(Fixtures.contains(out, marker: "iTunNORM"), "tag rewrite preserved Sound Check")
    }

    func testCopyThroughMP3IsNormalised() throws {
        let src = try Fixtures.first("mp3")
        let tmp = try Fixtures.tempDir("tagwriter-mp3"); defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("copy.mp3").path
        try FileManager.default.copyItem(atPath: src.path, toPath: out)
        let info = try TagReader.read(src.path)
        let carried = info.properties.filter { TagPolicy.isCarried($0.key) }
        let art = info.pictures.first.flatMap { Artwork.downscale($0.data, maxPixels: 600, jpegQuality: 0.85)?.data }
        try TagWriter.write(path: out, properties: carried, picture: art, encoderStamp: nil)
        let back = try TagReader.read(out)
        XCTAssertEqual(back.title, info.title)
        XCTAssertEqual(back.album, info.album)
        XCTAssertNil(back.first("ENCODEDBY"), "source encoder credit dropped on copy-through")
        XCTAssertEqual(back.pictures.count, info.pictures.isEmpty ? 0 : 1)
    }

    func testFLACOutputTagging() throws {
        let src = try Fixtures.first("flac")
        let tmp = try Fixtures.tempDir("tagwriter-flac"); defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("x.flac").path
        try FileManager.default.copyItem(atPath: src.path, toPath: out)
        try TagWriter.write(path: out, properties: ["TITLE": ["Renamed"], "ARTISTS": ["A", "B"]], picture: nil, encoderStamp: nil)
        let back = try TagReader.read(out)
        XCTAssertEqual(back.title, "Renamed")
        XCTAssertEqual(back.properties["ARTISTS"], ["A", "B"])
        XCTAssertNil(back.album, "unlisted keys are removed")
        XCTAssertEqual(back.pictures.count, 0)
    }
}
