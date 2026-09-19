import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ConvertableCore

final class ArtworkTests: XCTestCase {
    func png(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        return out as Data
    }
    func testDownscalesLargeArtToJPEGWithinBound() {
        let r = Artwork.downscale(png(3000, 3000), maxPixels: 600, jpegQuality: 0.85)!
        XCTAssertEqual(r.width, 600); XCTAssertEqual(r.height, 600); XCTAssertEqual(r.mimeType, "image/jpeg")
        XCTAssertTrue(r.data.starts(with: [0xFF, 0xD8]))
        XCTAssertLessThan(r.data.count, 100_000)
    }
    func testSmallArtIsNotUpscaled() {
        let r = Artwork.downscale(png(300, 200), maxPixels: 600, jpegQuality: 0.85)!
        XCTAssertEqual(r.width, 300); XCTAssertEqual(r.height, 200)
    }
    func testGarbageReturnsNil() { XCTAssertNil(Artwork.downscale(Data([1, 2, 3]), maxPixels: 600, jpegQuality: 0.85)) }
}

final class HashingTests: XCTestCase {
    func testFLACStreamMD5IsReadFromHeader() throws {
        let f = try Fixtures.first("flac")
        let md5 = AudioHash.flacStreamMD5(f.path)
        XCTAssertEqual(md5?.count, 32)
        XCTAssertEqual(md5, AudioHash.audioMD5(f.path, ext: ".flac"))
    }
    func testDecodedPCMHashIsStableAndDiffersBetweenFiles() throws {
        let files = Fixtures.all(withExtension: "flac")
        guard files.count >= 2 else { throw XCTSkip("need two flac fixtures") }
        let a = try AudioHash.decodedPCMMD5(files[0].path), b = try AudioHash.decodedPCMMD5(files[1].path)
        XCTAssertEqual(a, try AudioHash.decodedPCMMD5(files[0].path)); XCTAssertNotEqual(a, b)
    }
    func testTagHashIgnoresJunkAndTracksRealChanges() {
        var info = AudioFileInfo(properties: ["TITLE": ["x"], "ENCODER": ["Lavf"]], sampleRate: 44100, channels: 2, bitrateKbps: 900, lengthMs: 1000, pictures: [])
        let h1 = TagHash.compute(info)
        info.properties["ENCODER"] = ["something else"]
        XCTAssertEqual(TagHash.compute(info), h1, "junk keys do not affect the hash")
        info.properties["TITLE"] = ["y"]
        XCTAssertNotEqual(TagHash.compute(info), h1)
    }
    func testPolicy() {
        XCTAssertTrue(TagPolicy.isCarried("MUSICBRAINZ_ALBUMID")); XCTAssertTrue(TagPolicy.isCarried("TITLE"))
        XCTAssertFalse(TagPolicy.isCarried("REPLAYGAIN_TRACK_GAIN")); XCTAssertFalse(TagPolicy.isCarried("ENCODER")); XCTAssertFalse(TagPolicy.isCarried("MAJOR_BRAND"))
    }
}

final class EncodersTests: XCTestCase {
    func testAfconvertArgsMatchPinnedProfile() {
        XCTAssertEqual(AfconvertEncoder().arguments(.ipodAAC, sourceChannels: 2),
                       ["-f", "m4af", "-d", "aac@44100", "-b", "256000", "-s", "2", "-q", "127", "--soundcheck-generate"])
        XCTAssertTrue(AfconvertEncoder().arguments(.ipodAAC, sourceChannels: 6).contains("Stereo"))
    }
    func testHiResFLACBecomes44100AAC() throws {
        let src = try Fixtures.first("flac", containing: "24BIT")
        let tmp = try Fixtures.tempDir("enc"); defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("o.m4a").path
        try AfconvertEncoder().encode(.ipodAAC, input: src.path, output: out, sourceChannels: 2)
        let d = try Verifier.durationMs(out)
        XCTAssertEqual(d.sampleRate, 44100); XCTAssertEqual(d.channels, 2)
        XCTAssertEqual(Double(d.ms), Double(try Verifier.durationMs(src.path).ms), accuracy: 100)
        XCTAssertTrue(Fixtures.contains(out, marker: "iTunSMPB"))
    }
    /// macOS 27's CoreAudio decoder writes an empty file, exit status 0, for FLAC frames whose header says
    /// "sample rate / bit depth: see STREAMINFO" (a 2 s synthetic tone with every frame header rewritten that way;
    /// `flac -t` passes it). Batch #16 lost a whole album to this before the fallback covered it.
    func testFLACWithStreaminfoCodedFramesFallsBackToReferenceDecoder() throws {
        guard Tools.locate("flac") != nil else { throw XCTSkip("flac not installed") }
        let src = try XCTUnwrap(Bundle.module.url(forResource: "streaminfo-coded-frames", withExtension: "flac", subdirectory: "Resources"))
        let tmp = try Fixtures.tempDir("enc0"); defer { try? FileManager.default.removeItem(at: tmp) }
        let local = tmp.appendingPathComponent("in.flac").path
        try FileManager.default.copyItem(atPath: src.path, toPath: local)
        let out = tmp.appendingPathComponent("o.m4a").path
        try AfconvertEncoder().encode(.ipodAAC, input: local, output: out, sourceChannels: 2)
        XCTAssertEqual(Double(try Verifier.durationMs(out).ms), 2000, accuracy: 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("in.refdecoded.wav").path), "intermediate WAV cleaned up")
        // The PCM decode used by the lame/flac backends takes the same detour.
        let wav = try Decode.toWAV(local, channels: 2)
        XCTAssertEqual(Double(try Verifier.durationMs(wav).ms), 2000, accuracy: 100)
    }
    func testLameAndFlacBackends() throws {
        guard LameEncoder().isAvailable(), FlacEncoder().isAvailable() else { throw XCTSkip("lame/flac not installed") }
        let src = try Fixtures.first("flac", containing: "16BIT")
        let tmp = try Fixtures.tempDir("enc2"); defer { try? FileManager.default.removeItem(at: tmp) }
        let mp3 = tmp.appendingPathComponent("o.mp3").path, flac = tmp.appendingPathComponent("o.flac").path
        try LameEncoder().encode(.mp3_320, input: src.path, output: mp3, sourceChannels: 2)
        try FlacEncoder().encode(.flac8, input: src.path, output: flac, sourceChannels: 2)
        XCTAssertEqual(try Verifier.durationMs(mp3).sampleRate, 44100)
        XCTAssertEqual(Double(try Verifier.durationMs(flac).ms), Double(try Verifier.durationMs(src.path).ms), accuracy: 5)
        XCTAssertEqual(try AudioHash.decodedPCMMD5(flac), try AudioHash.decodedPCMMD5(src.path), "FLAC→FLAC is bit-identical audio")
    }
}

final class ShareIOTests: XCTestCase {
    func testNeverExceedsLimit() async throws {
        let io = ShareIO(limit: 3)
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<30 { g.addTask { _ = try? await io.perform { usleep(5_000); return 1 } } }
        }
        let peak = await io.peakInFlight, done = await io.completed
        XCTAssertLessThanOrEqual(peak, 3); XCTAssertEqual(done, 30)
    }
    func testHalvesLimitOnLatencySpike() async throws {
        let io = ShareIO(limit: 4, maxLimit: 4)
        for _ in 0..<10 { _ = try await io.perform { usleep(1_000); return 0 } }
        _ = try await io.perform { sleep(3); return 0 }     // > 2 s and > 8× the average
        let l = await io.limit
        XCTAssertEqual(l, 2)
    }
}

final class FrameHashTests: XCTestCase {
    func testFrameHashSurvivesRetagAndDiffersBetweenFiles() throws {
        let files = Fixtures.all(withExtension: "flac")
        guard files.count >= 2 else { throw XCTSkip("need two flac fixtures") }
        let tmp = try Fixtures.tempDir("framehash"); defer { try? FileManager.default.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("a.flac").path
        try FileManager.default.copyItem(atPath: files[0].path, toPath: copy)
        let before = AudioHash.flacFrameMD5(copy)!
        try TagWriter.write(path: copy, properties: ["TITLE": ["Completely different title"], "ALBUM": ["X"]], picture: nil, encoderStamp: nil)
        XCTAssertEqual(AudioHash.flacFrameMD5(copy), before, "retag leaves the frame hash unchanged")
        XCTAssertNotEqual(AudioHash.flacFrameMD5(files[1].path), before)
        XCTAssertTrue(before.hasPrefix("f:"))
    }
}
