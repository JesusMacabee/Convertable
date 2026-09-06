import Foundation
import AVFoundation

/// Probes behind the first-run setup. Each returns plain data the wizard renders; nothing here changes settings.
public enum Setup {
    public struct Dependency: Codable, Equatable, Sendable { public var name: String, present: Bool, detail: String, required: Bool, fix: String? }

    public static func dependencies() -> [Dependency] {
        let af = Tools.afconvert, lame = Tools.lame, flac = Tools.flac
        let tagPresent = FileManager.default.fileExists(atPath: "/opt/homebrew/lib/libtag_c.dylib") || Bundle.main.privateFrameworksURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("libtag_c.2.dylib").path) } == true
        return [
            .init(name: "afconvert (Apple AAC / ALAC encoder)", present: af.available, detail: af.path ?? "part of macOS", required: true, fix: nil),
            .init(name: "TagLib (tag reading/writing)", present: tagPresent, detail: tagPresent ? "available" : "not found", required: true, fix: tagPresent ? nil : "brew install taglib"),
            .init(name: "lame (MP3 output profiles only)", present: lame.available, detail: lame.version ?? "not installed", required: false, fix: lame.available ? nil : "brew install lame"),
            .init(name: "flac (FLAC output profiles only)", present: flac.available, detail: flac.version ?? "not installed", required: false, fix: flac.available ? nil : "brew install flac"),
        ]
    }

    public struct SourceProbe: Codable, Equatable, Sendable {
        public var ok: Bool, status: String, protocolName: String?, suggestedConcurrency: Int?
        public var topLevelFolders: Int, sampleAudioFiles: Int, coldMs: Double?, warmMs: Double?, warnings: [String]
    }

    public static func probeSource(_ path: String) -> SourceProbe {
        var warnings: [String] = []
        let vs = VolumeGate.check(root: path, timeout: 15)
        guard case let .available(info) = vs else {
            let text: String
            switch vs { case let .notMounted(v): text = "\(v) is not mounted"; case let .pathMissing(p): text = "\(p) does not exist"; case let .unresponsive(p): text = "\(p) did not answer"; default: text = "unavailable" }
            return SourceProbe(ok: false, status: text, protocolName: nil, suggestedConcurrency: nil, topLevelFolders: 0, sampleAudioFiles: 0, coldMs: nil, warmMs: nil, warnings: [])
        }
        let fm = FileManager.default
        let top = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
        var sample = 0
        for a in top.prefix(8) {
            if let e = fm.enumerator(atPath: path + "/" + a) { for case let f as String in e where Classifier.isAudio("." + (f as NSString).pathExtension.lowercased()) { sample += 1; if sample >= 150 { break } } }
            if sample >= 150 { break }
        }
        if info.fsType.lowercased() == "afpfs" { warnings.append("Mounted over AFP. On this kind of NAS, SMB was measured ~20× faster for first access; consider connecting with smb:// instead.") }
        if top.isEmpty { warnings.append("The folder is empty.") } else if sample == 0 { warnings.append("No audio files found in the first folders; is this the right level (Artist/Album/tracks)?") }
        let b = Benchmark.coldOpen(root: path, samples: 8)
        if let b, b.coldMs > 400 { warnings.append(String(format: "Cold file access is slow here (%.0f ms per file); conversion will work but scanning large libraries takes longer.", b.coldMs)) }
        return SourceProbe(ok: true, status: "\(info.mountPoint) (\(info.fsType))", protocolName: info.fsType, suggestedConcurrency: info.suggestedConcurrency,
                           topLevelFolders: top.count, sampleAudioFiles: sample, coldMs: b?.coldMs, warmMs: b?.warmMs, warnings: warnings)
    }

    public struct MirrorProbe: Codable, Equatable, Sendable { public var ok: Bool, status: String, freeBytes: Int64?, warnings: [String], errors: [String] }

    public static func probeMirror(_ path: String, musicLibraryPath: String) -> MirrorProbe {
        var warnings: [String] = [], errors: [String] = []
        let parent = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard fm.fileExists(atPath: parent) else { return MirrorProbe(ok: false, status: "parent folder does not exist", freeBytes: nil, warnings: [], errors: ["\(parent) does not exist"]) }
        if access(parent, W_OK) != 0 { errors.append("\(parent) is not writable") }
        // Inside Music's own media folder would let Music reorganise or duplicate our files.
        let libHome = (musicLibraryPath as NSString).deletingLastPathComponent
        for media in [libHome + "/Media.localized", libHome + "/Music", libHome + "/Media"] where path.hasPrefix(media + "/") || path == media {
            errors.append("The mirror must not live inside Music's media folder (\(media)); put it beside it, e.g. \(libHome)/Lossless Mirror")
        }
        if let vol = VolumeGate.expectedVolume(for: path), VolumeGate.mountInfo(containing: path)?.mountPoint != vol { errors.append("\(vol) is not mounted") }
        let free = VolumeGate.freeBytes(at: parent)
        if let free, free < 50_000_000_000 { warnings.append("Only \(ByteCount.string(free)) free.") }
        if fm.fileExists(atPath: path), let n = try? fm.contentsOfDirectory(atPath: path).count, n > 0 { warnings.append("Folder already exists with \(n) entries; existing files are left alone.") }
        return MirrorProbe(ok: errors.isEmpty, status: errors.isEmpty ? "ok" : "problems", freeBytes: free, warnings: warnings, errors: errors)
    }

    public struct LibraryChoice: Codable, Equatable, Sendable { public var path: String, name: String, isOpen: Bool, home: String }

    public static func musicLibraries() -> (libraries: [LibraryChoice], musicRunning: Bool, openLibrary: String?) {
        var paths: Set<String> = []
        if let r = try? Tools.run("/usr/bin/mdfind", ["kMDItemFSName == '*.musiclibrary'"], timeout: 20) {
            for l in r.stdout.split(separator: "\n") where !l.contains("Previous Libraries") { paths.insert(String(l)) }
        }
        let openURL = MusicPrefs.openLibraryURLString.flatMap { URL(string: $0)?.path }
        if let openURL { paths.insert(openURL.hasSuffix("/") ? String(openURL.dropLast()) : openURL) }
        let list = paths.sorted().map { p -> LibraryChoice in
            let home = (p as NSString).deletingLastPathComponent
            return LibraryChoice(path: p, name: (home as NSString).lastPathComponent + " / " + (p as NSString).lastPathComponent, isOpen: MusicPrefs.normalize("file://" + p) == MusicPrefs.normalize(openURL.map { "file://" + $0 } ?? ""), home: home)
        }
        return (list, MusicPrefs.isRunning, openURL)
    }

    public struct ImportTest: Codable, Equatable, Sendable { public var ok: Bool, message: String, detail: String? }

    /// Adds a 2-second generated file to the open library and checks whether Music referenced it in place
    /// or copied it, then removes the track and the file. The one check that cannot be done any other way.
    public static func testImport(mirrorRoot: String, settings: Settings, bridge: MusicBridge = MusicBridge()) -> ImportTest {
        var s = settings; s.mirrorRoot = mirrorRoot
        guard MusicPrefs.isRunning else { return ImportTest(ok: false, message: "Music is not running", detail: nil) }
        guard MusicPrefs.isConfiguredLibraryOpen(s) else { return ImportTest(ok: false, message: "Music has a different library open", detail: MusicPrefs.openLibraryURLString?.removingPercentEncoding) }
        let dir = mirrorRoot + "/.convertable-setup"
        let wav = dir + "/test.wav", m4a = dir + "/Convertable setup test.m4a"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try writeTone(to: wav)
            try AfconvertEncoder().encode(.ipodAAC, input: wav, output: m4a, sourceChannels: 1)
            try TagWriter.write(path: m4a, properties: ["TITLE": ["Convertable setup test"], "ARTIST": ["Convertable"], "ALBUM": ["Setup"]], picture: nil, encoderStamp: "Convertable setup")
            let (pid, loc) = try bridge.add(path: m4a)
            let inPlace = MusicImporter.samePath(loc, m4a)
            try? bridge.remove(persistentID: pid)
            if !inPlace, !loc.isEmpty, MusicImporter.looksLikeCopy(of: m4a, at: loc) { try? FileManager.default.removeItem(atPath: loc) }
            return inPlace ? ImportTest(ok: true, message: "Music referenced the file in place — the copy setting is off. The test track was removed again.", detail: loc)
                           : ImportTest(ok: false, message: "Music copied the file into its media folder. Turn off “Copy files to Music Media folder when adding to library” (Music ▸ Settings ▸ Files) and test again.", detail: loc)
        } catch {
            return ImportTest(ok: false, message: "Test failed: \(error)", detail: nil)
        }
    }

    static func writeTone(to path: String) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let frames: AVAudioFrameCount = 88200
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100)) * 0.2 }
        try file.write(from: buf)
    }

    public struct DoctorRow: Codable, Equatable, Sendable { public var name: String, result: String, detail: String }
    public static func doctor(_ settings: Settings) -> [DoctorRow] {
        Doctor.run(settings: settings, benchmark: false).map { .init(name: $0.name, result: $0.result.rawValue, detail: $0.detail) }
    }
}
