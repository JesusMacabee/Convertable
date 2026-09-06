import Foundation

/// Source relative path → mirror relative path. Pure and total: the tree is replicated exactly,
/// only the extension changes for transcodes. Collisions inside one directory (e.g. `x.flac` and
/// `x.mp3` both becoming `x.m4a`) get a " (2)" suffix in deterministic (sorted) order.
public enum PathMapping {
    public static func outputRelPath(source rel: String, action: Action) -> String {
        guard case let .transcode(spec) = action else { return rel }
        let ns = rel as NSString
        return ns.deletingPathExtension + spec.outputExtension
    }

    /// Maps a whole directory's files at once so collisions can be resolved.
    public static func outputRelPaths(for files: [(rel: String, action: Action)]) -> [String: String] {
        var taken: Set<String> = []
        var out: [String: String] = [:]
        for (rel, action) in files.sorted(by: { $0.rel < $1.rel }) where action.isWork {
            var candidate = outputRelPath(source: rel, action: action)
            var n = 2
            while taken.contains(candidate.lowercased()) {
                let ns = outputRelPath(source: rel, action: action) as NSString
                candidate = ns.deletingPathExtension + " (\(n))." + ns.pathExtension
                n += 1
            }
            taken.insert(candidate.lowercased())
            out[rel] = candidate
        }
        return out
    }
}
