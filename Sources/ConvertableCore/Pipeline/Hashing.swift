import Foundation
import AVFoundation
import CryptoKit

/// "Did the audio change, or only the tags?" — answered without decoding whenever possible.
public enum AudioHash {
    /// FLAC's STREAMINFO block carries an MD5 of the decoded PCM. Free.
    public static func flacStreamMD5(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard var head = try? fh.read(upToCount: 10), head.count >= 4 else { return nil }
        if head.starts(with: [0x49, 0x44, 0x33]) {   // ID3v2 prefix
            let sz = (Int(head[6] & 0x7f) << 21) | (Int(head[7] & 0x7f) << 14) | (Int(head[8] & 0x7f) << 7) | Int(head[9] & 0x7f)
            try? fh.seek(toOffset: UInt64(10 + sz))
            guard let h2 = try? fh.read(upToCount: 4) else { return nil }
            head = h2
        } else {
            try? fh.seek(toOffset: 4)
        }
        guard head.prefix(4) == Data("fLaC".utf8) else { return nil }
        while let hdr = try? fh.read(upToCount: 4), hdr.count == 4 {
            let last = hdr[0] & 0x80 != 0, type = hdr[0] & 0x7f
            let len = (Int(hdr[1]) << 16) | (Int(hdr[2]) << 8) | Int(hdr[3])
            guard let block = try? fh.read(upToCount: len), block.count == len else { return nil }
            if type == 0, block.count >= 34 {
                let md5 = block[18..<34]
                // An all-zero signature means the encoder didn't compute one; fall back to decoding.
                return md5.allSatisfy { $0 == 0 } ? nil : md5.map { String(format: "%02x", $0) }.joined()
            }
            if last { break }
        }
        return nil
    }

    /// MD5 of decoded PCM in the file's native processing format (float32, deinterleaved — deterministic
    /// for a given decoder). Used for ALAC/WAV/AIFF and for FLACs whose header MD5 is unset, which WEB rips often are.
    public static func decodedPCMMD5(_ path: String) throws -> String {
        do { return try avDecodedMD5(path) } catch { return try afconvertDecodedMD5(path) }
    }

    /// AVAudioFile opens 24-bit FLAC but refuses to read samples from it; CoreAudio's converter has no such trouble.
    /// Decode to a temp WAV and hash the PCM `data` chunk.
    static func afconvertDecodedMD5(_ path: String) throws -> String {
        guard let af = Tools.locate("afconvert") else { throw Tools.ToolError.failed("afconvert", status: 127, stderr: "not found") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("convertable-hash-\(UUID().uuidString).wav").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = try Tools.run(af, ["-f", "WAVE", "-d", "LEI24", path, tmp], timeout: 600)
        guard r.status == 0 else { throw Tools.ToolError.failed(af, status: r.status, stderr: r.stderr) }
        guard let fh = FileHandle(forReadingAtPath: tmp) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { try? fh.close() }
        // Walk RIFF chunks to the `data` chunk so header differences never change the hash.
        guard let riff = try fh.read(upToCount: 12), riff.count == 12 else { throw CocoaError(.fileReadCorruptFile) }
        var md5 = Insecure.MD5()
        while let hdr = try fh.read(upToCount: 8), hdr.count == 8 {
            let id = String(decoding: hdr[hdr.startIndex..<hdr.startIndex + 4], as: UTF8.self)
            let size = hdr.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
            if id == "data" {
                var remaining = Int(size)
                while remaining > 0, let chunk = try fh.read(upToCount: min(remaining, 4 << 20)), !chunk.isEmpty {
                    md5.update(data: chunk); remaining -= chunk.count
                }
                return md5.finalize().map { String(format: "%02x", $0) }.joined()
            }
            try fh.seek(toOffset: fh.offsetInFile + UInt64(size + (size & 1)))
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func avDecodedMD5(_ path: String) throws -> String {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let frames: AVAudioFrameCount = 65536
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CocoaError(.fileReadCorruptFile) }
        var md5 = Insecure.MD5()
        let channels = Int(format.channelCount)
        while true {
            try file.read(into: buf, frameCount: frames)
            if buf.frameLength == 0 { break }
            let n = Int(buf.frameLength)
            if let f = buf.floatChannelData {
                for c in 0..<channels { md5.update(data: Data(bytes: f[c], count: n * MemoryLayout<Float>.size)) }
            } else if let i = buf.int32ChannelData {
                for c in 0..<channels { md5.update(data: Data(bytes: i[c], count: n * MemoryLayout<Int32>.size)) }
            } else if let i = buf.int16ChannelData {
                for c in 0..<channels { md5.update(data: Data(bytes: i[c], count: n * MemoryLayout<Int16>.size)) }
            }
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whichever is cheapest for the file. Lossy files use a hash of the raw bytes minus nothing — their
    /// "audio" is the file; a retag of an MP3 changes the hash, which correctly triggers a re-copy.
    public static func audioMD5(_ path: String, ext: String) -> String? {
        if ext == ".flac", let m = flacStreamMD5(path) { return m }
        if Classifier.losslessExts.contains(ext) || ext == ".m4a", let m = try? decodedPCMMD5(path) { return m }
        return fileMD5(path)
    }

    public static func fileMD5(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var md5 = Insecure.MD5()
        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty { md5.update(data: chunk) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum TagHash {
    /// Stable digest of the tags that matter for the mirror (keys sorted, values joined), plus art bytes.
    public static func compute(_ info: AudioFileInfo) -> String {
        var h = SHA256()
        for (k, v) in info.properties.sorted(by: { $0.key < $1.key }) where TagPolicy.isCarried(k) {
            h.update(data: Data("\(k)=\(v.joined(separator: "\u{1f}"))\n".utf8))
        }
        if let pic = info.pictures.first { h.update(data: pic.data) }
        return h.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Which source tags travel to the output. TagLib's property map already normalises names across
/// FLAC / MP3 / MP4, so this is a deny-list of junk rather than a mapping table.
public enum TagPolicy {
    static let dropped: Set<String> = [
        "ENCODER", "ENCODEDBY", "ENCODING", "ENCODERSETTINGS", "ENCODER SETTINGS",
        "COMPATIBLE_BRANDS", "MAJOR_BRAND", "MINOR_VERSION",      // ffmpeg container leftovers
        "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_PEAK", "REPLAYGAIN_REFERENCE_LOUDNESS",
        "ITUNSMPB", "ITUNNORM",                                    // never copy from a source; the encoder writes its own
        "COMMENT:ID3V1 COMMENT",
    ]
    public static func isCarried(_ key: String) -> Bool {
        let k = key.uppercased()
        if dropped.contains(k) { return false }
        if k.hasPrefix("REPLAYGAIN") || k.hasPrefix("ITUNES:") { return false }
        return true
    }
}
