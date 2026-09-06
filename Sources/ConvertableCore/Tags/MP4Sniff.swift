import Foundation

/// Reads just enough of an MP4/M4A container to name its audio codec ("alac", "mp4a", …).
/// Only headers and the tiny `stsd` box are read — a few KB even when `moov` trails a multi-GB `mdat`.
public enum MP4Sniff {
    public static func codec(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        return walk(fh, from: 0, to: end, depth: 0)
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    private static func walk(_ fh: FileHandle, from start: UInt64, to end: UInt64, depth: Int) -> String? {
        var off = start
        while off + 8 <= end, depth < 8 {
            guard let hdr = read(fh, at: off, count: 16), hdr.count >= 8 else { return nil }
            var size = UInt64(be32(hdr, 0))
            let type = String(decoding: hdr[4..<8], as: UTF8.self)
            var header: UInt64 = 8
            if size == 1, hdr.count >= 16 { size = be64(hdr, 8); header = 16 }
            if size == 0 { size = end - off }
            guard size >= header else { return nil }
            if type == "stsd" {
                // stsd: version/flags(4) entryCount(4) then entries: size(4) format(4) …
                guard let body = read(fh, at: off + header, count: 16), body.count >= 16 else { return nil }
                let fmt = String(decoding: body[12..<16], as: UTF8.self)
                return fmt.trimmingCharacters(in: .whitespaces)
            }
            if containers.contains(type) {
                if let c = walk(fh, from: off + header, to: off + size, depth: depth + 1) { return c }
            }
            off += size
        }
        return nil
    }

    private static func read(_ fh: FileHandle, at off: UInt64, count: Int) -> Data? {
        do { try fh.seek(toOffset: off); return try fh.read(upToCount: count) } catch { return nil }
    }
    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        d.withUnsafeBytes { p in UInt32(bigEndian: p.loadUnaligned(fromByteOffset: d.startIndex - d.startIndex + i, as: UInt32.self)) }
    }
    private static func be64(_ d: Data, _ i: Int) -> UInt64 {
        d.withUnsafeBytes { p in UInt64(bigEndian: p.loadUnaligned(fromByteOffset: i, as: UInt64.self)) }
    }
}
