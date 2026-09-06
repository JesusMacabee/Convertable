import Foundation

/// The single-page dashboard, embedded as a package resource. Looked up in the places SwiftPM and our
/// .app bundle put it, so the same binary works from `swift build` and from `Convertable.app`.
enum Dashboard {
    static let html: String = {
        let name = "Convertable_ConvertableWeb.bundle"
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent(name)) }
        for c in candidates {
            let f = c.appendingPathComponent("Dashboard/index.html")
            if let s = try? String(contentsOf: f, encoding: .utf8) { return s }
        }
        #if DEBUG
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Dashboard"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        #endif
        return "<h1>Convertable</h1><p>dashboard resource missing — reinstall the app</p>"
    }()

    static let unauthorizedHTML = """
    <!doctype html><meta charset=utf-8><title>Convertable</title>
    <body style="font-family:-apple-system,system-ui;padding:3rem;color:#333;background:#fafafa">
    <h2>Convertable</h2><p>This dashboard needs its access link. Open it from the Convertable menu bar item, or run
    <code>convertctl web-url</code> and open the printed address.</p></body>
    """
}
