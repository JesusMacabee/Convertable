import XCTest
@testable import ConvertableCore

final class VolumeGateTests: XCTestCase {
    func testExpectedVolume() {
        XCTAssertEqual(VolumeGate.expectedVolume(for: "/Volumes/Media/Music/Lossless"), "/Volumes/Media")
        XCTAssertNil(VolumeGate.expectedVolume(for: "/Users/me/Music"))
    }

    func testLocalPathIsAvailable() {
        if case .available(let info) = VolumeGate.check(root: NSHomeDirectory(), timeout: 5) {
            XCTAssertFalse(info.isNetwork)
        } else { XCTFail("home directory should be available") }
    }

    func testUnmountedVolumeIsNotMounted() {
        XCTAssertEqual(VolumeGate.check(root: "/Volumes/DefinitelyNotMounted/x", timeout: 5),
                       .notMounted(expectedMountPoint: "/Volumes/DefinitelyNotMounted"))
    }

    func testSuggestedConcurrency() {
        XCTAssertEqual(MountInfo(mountPoint: "/Volumes/X", fsType: "afpfs", mountedFrom: "").suggestedConcurrency, 1)
        XCTAssertEqual(MountInfo(mountPoint: "/Volumes/X", fsType: "smbfs", mountedFrom: "").suggestedConcurrency, 4)
    }
}
