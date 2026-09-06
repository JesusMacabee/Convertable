import XCTest
@testable import ConvertableCore

final class ProfileTests: XCTestCase {
    func file(_ ext: String, _ kind: FileKind) -> SourceFile {
        SourceFile(id: 1, relPath: "A/B/t\(ext)", artistDir: "A", albumDir: "B", ext: ext, kind: kind, codec: nil, size: 10, mtime: 0, stableSince: 0,
                   observations: 2, firstSeen: 0, lastSeenScan: 1, status: .active, missingSince: nil, audioMD5: nil, tagHash: nil,
                   tagArtist: nil, tagAlbumArtist: nil, tagAlbum: nil)
    }
    func testIpodProfile() {
        let p = Profile.ipodClassic
        XCTAssertEqual(p.action(for: file(".flac", .lossless)), .transcode(.ipodAAC))
        XCTAssertEqual(p.action(for: file(".mp3", .lossy)), .copyThrough)
        XCTAssertEqual(p.action(for: file(".m4a", .lossy)), .copyThrough)
        XCTAssertEqual(p.action(for: file(".m4a", .lossless)), .transcode(.ipodAAC))   // ALAC in .m4a
        XCTAssertEqual(p.action(for: file(".xyz", .other)), .skip)
    }
    func testArchiveProfileCopiesFlacTranscodesWav() {
        let p = Profile.archiveFLAC
        XCTAssertEqual(p.action(for: file(".flac", .lossless)), .copyThrough)
        XCTAssertEqual(p.action(for: file(".wav", .lossless)), .transcode(.flac8))
    }
    func testProfilesRoundTripJSON() throws {
        let data = try JSONEncoder().encode(Profile.builtIn)
        let back = try JSONDecoder().decode([Profile].self, from: data)
        XCTAssertEqual(back, Profile.builtIn)
    }
    func testClassifier() {
        XCTAssertEqual(Classifier.kind(forExtension: ".flac"), .lossless)
        XCTAssertEqual(Classifier.kind(forExtension: ".mp3"), .lossy)
        XCTAssertNil(Classifier.kind(forExtension: ".m4a"))
        XCTAssertEqual(Classifier.kind(forCodec: "alac"), .lossless)
        XCTAssertEqual(Classifier.kind(forCodec: "mp4a"), .lossy)
        XCTAssertFalse(Classifier.isAudio(".jpg"))
    }
}
