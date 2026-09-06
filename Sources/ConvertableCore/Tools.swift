import Foundation

/// External command-line tools the pipeline can use. Detected at startup, never assumed.
public struct Tool: Equatable, Sendable {
    public let name: String
    public let path: String?
    public let version: String?
    public var available: Bool { path != nil }
}

public enum Tools {
    static let searchPaths = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    public static func locate(_ name: String) -> String? {
        for dir in searchPaths {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs a process and captures both streams. `timeout` guards against a hung network read.
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 600, stdin: Data? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inp = Pipe(); p.standardInput = inp
            try p.run()
            inp.fileHandleForWriting.write(stdin); try? inp.fileHandleForWriting.close()
        } else {
            try p.run()
        }
        // Drain concurrently so a chatty tool can't deadlock on a full pipe.
        var o = Data(), e = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            p.terminate()
            throw ToolError.timeout(path, args)
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    public enum ToolError: Error, CustomStringConvertible {
        case timeout(String, [String])
        case failed(String, status: Int32, stderr: String)
        public var description: String {
            switch self {
            case let .timeout(p, a): return "\(p) \(a.joined(separator: " ")) timed out"
            case let .failed(p, s, e): return "\(p) exited \(s): \(e.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    public static func detect(_ name: String, versionArgs: [String]) -> Tool {
        guard let path = locate(name) else { return Tool(name: name, path: nil, version: nil) }
        let v = (try? run(path, versionArgs, timeout: 10)).map { r in
            (r.stdout + r.stderr).split(separator: "\n").first.map(String.init) ?? ""
        }
        return Tool(name: name, path: path, version: v?.trimmingCharacters(in: .whitespaces))
    }

    public static var afconvert: Tool { detect("afconvert", versionArgs: ["-h"]) }
    public static var afinfo: Tool { detect("afinfo", versionArgs: ["-h"]) }
    public static var lame: Tool { detect("lame", versionArgs: ["--version"]) }
    public static var flac: Tool { detect("flac", versionArgs: ["--version"]) }
    public static var ffmpeg: Tool { detect("ffmpeg", versionArgs: ["-version"]) }
}
