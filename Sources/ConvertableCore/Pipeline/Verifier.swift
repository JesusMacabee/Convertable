import Foundation
import AVFoundation

/// Post-encode sanity: the file opens, its duration matches the source, and the tags read back.
public enum Verifier {
    public struct Report: Sendable {
        public var ok: Bool
        public var problems: [String]
        public var durationMs: Int
        public var sampleRate: Int
        public var channels: Int
    }

    public static func durationMs(_ path: String) throws -> (ms: Int, sampleRate: Int, channels: Int) {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let sr = f.fileFormat.sampleRate
        return (Int(Double(f.length) / sr * 1000), Int(sr), Int(f.fileFormat.channelCount))
    }

    public static func verify(output: String, sourceDurationMs: Int, expectedSampleRate: Int?, expectedTags: [String: [String]], toleranceMs: Int = 100) -> Report {
        var problems: [String] = []
        var d = (ms: 0, sampleRate: 0, channels: 0)
        do { d = try durationMs(output) } catch { return Report(ok: false, problems: ["cannot open: \(error)"], durationMs: 0, sampleRate: 0, channels: 0) }
        if abs(d.ms - sourceDurationMs) > toleranceMs { problems.append("duration \(d.ms) ms vs source \(sourceDurationMs) ms") }
        if let sr = expectedSampleRate, d.sampleRate != sr { problems.append("sample rate \(d.sampleRate) ≠ \(sr)") }
        if let info = try? TagReader.read(output) {
            for key in ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "TRACKNUMBER"] {
                if let want = expectedTags[key]?.first, let got = info.first(key) {
                    // TRACKNUMBER may be normalised ("3/12" → "3"); compare leading integers for it.
                    if key == "TRACKNUMBER" { if leadingInt(want) != leadingInt(got) { problems.append("\(key): \(got) ≠ \(want)") } }
                    else if got != want { problems.append("\(key): \(got) ≠ \(want)") }
                } else if expectedTags[key] != nil { problems.append("\(key) missing") }
            }
        } else { problems.append("tags unreadable") }
        return Report(ok: problems.isEmpty, problems: problems, durationMs: d.ms, sampleRate: d.sampleRate, channels: d.channels)
    }

    static func leadingInt(_ s: String) -> Int? { Int(s.prefix { $0.isNumber }) }
}
