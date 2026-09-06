import Foundation
import XCTest

/// Locates the ~1 GB fixture library (gitignored) and hands out sample files by kind.
enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/library")
    }
    static var available: Bool { FileManager.default.fileExists(atPath: root.path) }

    static func all(withExtension ext: String) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == ext }.sorted { $0.path < $1.path }
    }

    static func first(_ ext: String, containing needle: String? = nil) throws -> URL {
        guard available else { throw XCTSkip("fixture library not present") }
        let matches = all(withExtension: ext).filter { needle == nil || $0.path.contains(needle!) }
        guard let f = matches.first else { throw XCTSkip("no .\(ext) fixture\(needle.map { " containing \($0)" } ?? "")") }
        return f
    }

    static func tempDir(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("convertable-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func contains(_ path: String, marker: String) -> Bool {
        guard let d = FileManager.default.contents(atPath: path) else { return false }
        return d.range(of: Data(marker.utf8)) != nil
    }
}
