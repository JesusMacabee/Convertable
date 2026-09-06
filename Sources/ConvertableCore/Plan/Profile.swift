import Foundation

/// Which encoder produces the output, and how.
public struct EncoderSpec: Codable, Equatable, Sendable {
    public enum Backend: String, Codable, Sendable { case afconvertAAC, afconvertALAC, afconvertPCM, lame, flac }
    public var backend: Backend
    public var outputExtension: String         // ".m4a", ".mp3", ".flac", ".wav"
    public var sampleRate: Int?                // nil = keep source rate
    public var bitrate: Int?                   // bits/s for lossy backends
    public var vbrMode: String?                // backend-specific ("cvbr", "vbr", "cbr", "V0", …)
    public var quality: Int?                   // backend-specific (afconvert -q 0–127, lame -q 0–9, flac -0…-8)
    /// Expected output-bytes / input-bytes for planning until real ratios are learned.
    public var estimatedRatio: Double

    public static let ipodAAC = EncoderSpec(backend: .afconvertAAC, outputExtension: ".m4a", sampleRate: 44100, bitrate: 256_000,
                                            vbrMode: "cvbr", quality: 127, estimatedRatio: 0.27)
    public static let alac = EncoderSpec(backend: .afconvertALAC, outputExtension: ".m4a", sampleRate: nil, bitrate: nil, vbrMode: nil, quality: nil, estimatedRatio: 1.0)
    public static let mp3_320 = EncoderSpec(backend: .lame, outputExtension: ".mp3", sampleRate: 44100, bitrate: 320_000, vbrMode: "cbr", quality: 0, estimatedRatio: 0.33)
    public static let flac8 = EncoderSpec(backend: .flac, outputExtension: ".flac", sampleRate: nil, bitrate: nil, vbrMode: nil, quality: 8, estimatedRatio: 0.6)

    public var summary: String {
        switch backend {
        case .afconvertAAC: return "AAC \((bitrate ?? 0) / 1000)k \(vbrMode?.uppercased() ?? "") @\(sampleRate.map { "\(Double($0) / 1000)" } ?? "src") kHz"
        case .afconvertALAC: return "ALAC"
        case .afconvertPCM: return "PCM \(outputExtension)"
        case .lame: return "MP3 \((bitrate ?? 0) / 1000)k \(vbrMode?.uppercased() ?? "")"
        case .flac: return "FLAC -\(quality ?? 5)"
        }
    }
}

public enum Action: Codable, Equatable, Sendable {
    case transcode(EncoderSpec)
    case copyThrough
    case skip

    public var isWork: Bool { if case .skip = self { return false }; return true }
    public var label: String {
        switch self {
        case let .transcode(e): return e.summary
        case .copyThrough: return "copy"
        case .skip: return "skip"
        }
    }
}

public struct Rule: Codable, Equatable, Sendable {
    public enum Match: Codable, Equatable, Sendable {
        case kind(FileKind)
        case extensions([String])
        case any
    }
    public var match: Match
    public var action: Action

    public func matches(_ f: SourceFile) -> Bool {
        switch match {
        case let .kind(k): return f.kind == k
        case let .extensions(exts): return exts.contains(f.ext)
        case .any: return true
        }
    }
}

/// Ordered rules; the first match wins. Files matching nothing are skipped.
public struct Profile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var rules: [Rule]

    public func action(for f: SourceFile) -> Action {
        rules.first { $0.matches(f) }?.action ?? .skip
    }

    public static let ipodClassic = Profile(id: "ipod-classic", name: "iPod Classic — AAC 256 CVBR 44.1, lossy copy-through", rules: [
        Rule(match: .kind(.lossless), action: .transcode(.ipodAAC)),
        Rule(match: .kind(.lossy), action: .copyThrough),
    ])
    public static let appleLossless = Profile(id: "alac", name: "Apple Lossless — everything to ALAC", rules: [
        Rule(match: .kind(.lossless), action: .transcode(.alac)),
        Rule(match: .kind(.lossy), action: .copyThrough),
    ])
    public static let mp3_320 = Profile(id: "mp3-320", name: "MP3 320 — everything to MP3", rules: [
        Rule(match: .extensions([".mp3"]), action: .copyThrough),
        Rule(match: .any, action: .transcode(.mp3_320)),
    ])
    public static let archiveFLAC = Profile(id: "archive-flac", name: "Archive to FLAC — WAV/AIFF/ALAC to FLAC, others copy", rules: [
        Rule(match: .extensions([".flac"]), action: .copyThrough),
        Rule(match: .kind(.lossless), action: .transcode(.flac8)),
        Rule(match: .kind(.lossy), action: .copyThrough),
    ])
    public static let builtIn: [Profile] = [ipodClassic, appleLossless, mp3_320, archiveFLAC]

    public static func named(_ id: String) -> Profile? { builtIn.first { $0.id == id } }
}
