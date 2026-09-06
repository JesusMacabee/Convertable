import Foundation
import ArgumentParser
import ConvertableCore

@main
struct Convertctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convertable command line — diagnostics and scripting over the same core as the app.",
        subcommands: [Doctor.self, Config.self, Tags.self],
        defaultSubcommand: Doctor.self)
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check mount, paths, tools, Music library, database, web port, share latency.")
    @Flag(name: .long, help: "Skip the share latency benchmark.") var noBenchmark = false

    func run() throws {
        let settings = try Settings.load()
        let checks = ConvertableCore.Doctor.run(settings: settings, benchmark: !noBenchmark)
        let width = checks.map(\.name.count).max() ?? 10
        for c in checks {
            let mark = c.result == .pass ? "✅" : (c.result == .warn ? "⚠️ " : "❌")
            print("\(mark) \(c.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(c.detail)")
        }
        let fails = checks.filter { $0.result == .fail }.count
        print(fails == 0 ? "\nAll critical checks passed." : "\n\(fails) critical check(s) failed.")
        if fails > 0 { throw ExitCode(1) }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or initialise settings.json.")
    @Flag(name: .long, help: "Write the default settings file if none exists.") var initialize = false

    func run() throws {
        if initialize, !FileManager.default.fileExists(atPath: Settings.defaultURL.path) {
            try Settings().save()
            print("wrote \(Settings.defaultURL.path)")
        }
        let s = try Settings.load()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try enc.encode(s), as: UTF8.self))
        print("\n(file: \(Settings.defaultURL.path))")
    }
}

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dump the tags TagLib reads from a file.")
    @Argument(help: "Audio file path.") var path: String

    func run() throws {
        let info = try TagReader.read(path)
        print("\(info.sampleRate) Hz, \(info.channels) ch, \(info.bitrateKbps) kbps, \(Double(info.lengthMs) / 1000) s, \(info.pictures.count) picture(s)")
        for (k, v) in info.properties.sorted(by: { $0.key < $1.key }) {
            print("  \(k.padding(toLength: 28, withPad: " ", startingAt: 0)) \(v.joined(separator: " | "))")
        }
        for p in info.pictures { print("  PICTURE \(p.pictureType) \(p.mimeType) \(p.data.count) bytes") }
    }
}
