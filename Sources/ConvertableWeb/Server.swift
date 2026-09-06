import Foundation
import Hummingbird
import ConvertableCore

/// HTTP + JSON + SSE server hosting the dashboard. Phase 0: health endpoint only.
public struct WebServer {
    public let host: String
    public let port: Int

    public init(settings: Settings) {
        host = settings.web.allowLAN ? "0.0.0.0" : "127.0.0.1"
        port = settings.web.port
    }

    public func run() async throws {
        let router = Router()
        router.get("/health") { _, _ in "ok" }
        let app = Application(router: router, configuration: .init(address: .hostname(host, port: port)))
        try await app.runService()
    }
}
