import Foundation

/// The single-page dashboard, embedded as a package resource.
enum Dashboard {
    static let html: String = {
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Dashboard"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return "<h1>Convertable</h1><p>dashboard resource missing</p>"
    }()

    static let unauthorizedHTML = """
    <!doctype html><meta charset=utf-8><title>Convertable</title>
    <body style="font-family:-apple-system,system-ui;padding:3rem;color:#333;background:#fafafa">
    <h2>Convertable</h2><p>This dashboard needs its access link. Open it from the Convertable menu bar item, or run
    <code>convertctl web-url</code> and open the printed address.</p></body>
    """
}
