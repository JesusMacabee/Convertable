import Foundation

/// One encoder backend. Input and output are always local files.
public protocol Encoder: Sendable {
    var backend: EncoderSpec.Backend { get }
    func isAvailable() -> Bool
    func encode(_ spec: EncoderSpec, input: String, output: String, sourceChannels: Int) throws
}

public enum Encoders {
    public static func encoder(for spec: EncoderSpec) -> Encoder {
        switch spec.backend {
        case .afconvertAAC, .afconvertALAC, .afconvertPCM: return AfconvertEncoder()
        case .lame: return LameEncoder()
        case .flac: return FlacEncoder()
        }
    }

    /// Stamp written into the output's encoder tag so mirror files are self-identifying forever.
    public static func stamp(_ spec: EncoderSpec) -> String { "Convertable (\(spec.summary.trimmingCharacters(in: .whitespaces)))" }

    static func check(_ r: (status: Int32, stdout: String, stderr: String), _ path: String) throws {
        guard r.status == 0 else { throw Tools.ToolError.failed(path, status: r.status, stderr: r.stderr.isEmpty ? r.stdout : r.stderr) }
    }
}

/// Apple's encoder. AAC output carries `iTunSMPB` (gapless) and, with --soundcheck-generate, `iTunNORM`.
public struct AfconvertEncoder: Encoder {
    public var backend: EncoderSpec.Backend { .afconvertAAC }
    public func isAvailable() -> Bool { Tools.locate("afconvert") != nil }

    public func arguments(_ spec: EncoderSpec, sourceChannels: Int) -> [String] {
        var args: [String] = []
        switch spec.backend {
        case .afconvertAAC:
            args += ["-f", "m4af", "-d", spec.sampleRate.map { "aac@\($0)" } ?? "aac"]
            switch spec.vbrMode?.lowercased() {
            case "vbr":  args += ["-s", "3", "-ue", "vbrq", String(spec.quality ?? 96)]
            case "cbr":  args += ["-b", String(spec.bitrate ?? 256_000), "-s", "0"]
            case "abr":  args += ["-b", String(spec.bitrate ?? 256_000), "-s", "1"]
            default:     args += ["-b", String(spec.bitrate ?? 256_000), "-s", "2"]     // constrained VBR = iTunes Plus
            }
            if spec.vbrMode?.lowercased() != "vbr" { args += ["-q", String(spec.quality ?? 127)] }
            args += ["--soundcheck-generate"]
        case .afconvertALAC:
            args += ["-f", "m4af", "-d", spec.sampleRate.map { "alac@\($0)" } ?? "alac"]
        case .afconvertPCM:
            let fmt = spec.outputExtension == ".aif" || spec.outputExtension == ".aiff" ? "AIFF" : "WAVE"
            args += ["-f", fmt, "-d", spec.sampleRate.map { "LEI16@\($0)" } ?? "LEI16"]
        default: break
        }
        if sourceChannels > 2 { args += ["-l", "Stereo"] }   // iPod-bound output is stereo at most
        return args
    }

    public func encode(_ spec: EncoderSpec, input: String, output: String, sourceChannels: Int) throws {
        guard let path = Tools.locate("afconvert") else { throw Tools.ToolError.failed("afconvert", status: 127, stderr: "not found") }
        let r = try Tools.run(path, arguments(spec, sourceChannels: sourceChannels) + [input, output], timeout: 900)
        if r.status != 0, input.lowercased().hasSuffix(".flac"), let flac = Tools.locate("flac") {
            // CoreAudio rejects some valid FLACs (e.g. unusual block sizes). The reference decoder does not.
            let wav = (input as NSString).deletingPathExtension + ".refdecoded.wav"
            defer { try? FileManager.default.removeItem(atPath: wav) }
            try Encoders.check(try Tools.run(flac, ["-d", "--silent", "--force", "-o", wav, input], timeout: 900), flac)
            try Encoders.check(try Tools.run(path, arguments(spec, sourceChannels: sourceChannels) + [wav, output], timeout: 900), path)
            return
        }
        try Encoders.check(r, path)
    }
}

/// LAME for MP3. Input must be PCM/WAV; anything else is decoded to WAV by afconvert first.
public struct LameEncoder: Encoder {
    public var backend: EncoderSpec.Backend { .lame }
    public func isAvailable() -> Bool { Tools.locate("lame") != nil }

    public func arguments(_ spec: EncoderSpec) -> [String] {
        var args = ["--quiet", "--noreplaygain", "-q", String(spec.quality ?? 0)]
        if let sr = spec.sampleRate { args += ["--resample", String(Double(sr) / 1000)] }
        switch spec.vbrMode?.lowercased() {
        case let m? where m.hasPrefix("v"): args += ["-V", String(m.dropFirst())]             // "V0" … "V9"
        case "abr": args += ["--abr", String((spec.bitrate ?? 256_000) / 1000)]
        default: args += ["-b", String((spec.bitrate ?? 320_000) / 1000), "--cbr"]
        }
        return args
    }

    public func encode(_ spec: EncoderSpec, input: String, output: String, sourceChannels: Int) throws {
        guard let lame = Tools.locate("lame") else { throw Tools.ToolError.failed("lame", status: 127, stderr: "not installed: brew install lame") }
        let wav = try Decode.toWAV(input, channels: sourceChannels)
        defer { if wav != input { try? FileManager.default.removeItem(atPath: wav) } }
        try Encoders.check(try Tools.run(lame, arguments(spec) + [wav, output], timeout: 900), lame)
    }
}

/// The reference FLAC encoder. Input must be PCM/WAV; decoded via afconvert when it isn't.
public struct FlacEncoder: Encoder {
    public var backend: EncoderSpec.Backend { .flac }
    public func isAvailable() -> Bool { Tools.locate("flac") != nil }

    public func encode(_ spec: EncoderSpec, input: String, output: String, sourceChannels: Int) throws {
        guard let flac = Tools.locate("flac") else { throw Tools.ToolError.failed("flac", status: 127, stderr: "not installed: brew install flac") }
        let wav = try Decode.toWAV(input, channels: sourceChannels)
        defer { if wav != input { try? FileManager.default.removeItem(atPath: wav) } }
        let level = "-\(min(8, max(0, spec.quality ?? 8)))"
        try Encoders.check(try Tools.run(flac, ["--silent", "--force", level, "--verify", "--no-padding", "-o", output, wav], timeout: 900), flac)
    }
}

/// Intermediate decode for backends that only take PCM. Keeps bit depth (24-bit stays 24-bit).
enum Decode {
    static func toWAV(_ input: String, channels: Int) throws -> String {
        let ext = (input as NSString).pathExtension.lowercased()
        if ext == "wav" { return input }
        guard let af = Tools.locate("afconvert") else { throw Tools.ToolError.failed("afconvert", status: 127, stderr: "not found") }
        let out = (input as NSString).deletingPathExtension + ".decoded.wav"
        var args = ["-f", "WAVE", "-d", "LEI24"]
        if channels > 2 { args += ["-l", "Stereo"] }
        try Encoders.check(try Tools.run(af, args + [input, out], timeout: 900), af)
        return out
    }
}
