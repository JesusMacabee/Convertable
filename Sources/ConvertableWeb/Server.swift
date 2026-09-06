import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import ConvertableCore

/// HTTP + JSON + SSE server for the dashboard. Every `/api` and `/events` request needs the access
/// token (cookie set by a one-time `/?token=` link, or `Authorization: Bearer`). Mutations also need
/// the `X-Convertable` header the dashboard's own JavaScript sets, which blocks cross-site form posts.
public struct WebServer: Sendable {
    public let controller: AppController
    public let host: String
    public let port: Int
    let token: String
    let allowLAN: Bool

    public init(controller: AppController, settings: Settings) {
        self.controller = controller
        self.host = settings.web.allowLAN ? "0.0.0.0" : "127.0.0.1"
        self.port = settings.web.port
        self.token = settings.web.token
        self.allowLAN = settings.web.allowLAN
    }

    public var localURL: String { "http://127.0.0.1:\(port)/?token=\(token)" }

    public func run() async throws {
        try await buildApplication().runService()
    }

    /// The configured application; tests drive it in-process via HummingbirdTesting.
    public func buildApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let html = Dashboard.html

        router.get("/health") { _, _ in "ok" }

        router.get("/") { request, _ -> Response in
            if let t = request.uri.queryParameters["token"], t == self.token {
                return Response(status: .seeOther, headers: [.location: "/", .setCookie: "ct=\(self.token); Path=/; HttpOnly; SameSite=Strict"])
            }
            guard self.authorized(request) else {
                return Response(status: .unauthorized, headers: [.contentType: "text/html; charset=utf-8"],
                                body: .init(byteBuffer: ByteBuffer(string: Dashboard.unauthorizedHTML)))
            }
            return Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"], body: .init(byteBuffer: ByteBuffer(string: html)))
        }

        let api = router.group("api").add(middleware: AuthMiddleware<BasicRequestContext>(token: token))

        api.get("status") { _, _ in try self.json(await self.controller.status()) }
        api.get("artists") { _, _ in try self.json(await self.controller.artists()) }
        api.get("albums") { req, _ in
            let artist = req.uri.queryParameters["artist"].map(String.init) ?? ""
            return try self.json(await self.controller.albums(artist: artist))
        }
        api.get("batches") { _, _ in try self.json(await self.controller.batches()) }
        api.get("activity") { req, _ in
            let level = req.uri.queryParameters["level"].map(String.init)
            let search = req.uri.queryParameters["search"].map(String.init)
            let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 200
            return try self.json(await self.controller.activity(limit: limit, level: level, search: search))
        }
        api.get("settings") { _, _ in try self.json(await self.controller.settings) }
        api.get("profiles") { _, _ in try self.json(Profile.builtIn) }
        api.post("preview") { req, ctx in
            let sel = try await req.decode(as: Selection.self, context: ctx)
            return try self.json(try await self.controller.preview(sel))
        }
        api.post("batch") { req, ctx in
            struct Body: Decodable { var selection: Selection; var exceedCap: Bool? }
            let b = try await req.decode(as: Body.self, context: ctx)
            try await self.controller.perform(.startBatch(b.selection, exceedCap: b.exceedCap ?? false))
            return try self.json(await self.controller.status())
        }
        api.post("stop") { _, _ in try await self.controller.perform(.stop); return try self.json(await self.controller.status()) }
        api.get("proposals") { _, _ in try self.json(await self.controller.proposals()) }
        api.post("proposals/approve") { req, ctx in
            struct Body: Decodable { var id: Int64 }
            let b = try await req.decode(as: Body.self, context: ctx)
            try await self.controller.perform(.approve(id: b.id))
            return try self.json(await self.controller.proposals())
        }
        api.post("proposals/dismiss") { req, ctx in
            struct Body: Decodable { var id: Int64 }
            let b = try await req.decode(as: Body.self, context: ctx)
            try await self.controller.perform(.dismiss(id: b.id))
            return try self.json(await self.controller.proposals())
        }
        api.post("legacy/index") { _, _ in try await self.controller.perform(.indexLegacy); return try self.json(await self.controller.status()) }
        api.post("music/import") { _, _ in try await self.controller.perform(.importNow); return try self.json(await self.controller.status()) }
        api.post("music/enable") { _, _ in try await self.controller.perform(.enableMusicImport); return try self.json(await self.controller.status()) }
        api.post("scan") { req, ctx in
            struct Body: Decodable { var full: Bool? }
            let b = try? await req.decode(as: Body.self, context: ctx)
            try await self.controller.perform(.scan(full: b?.full ?? false))
            return try self.json(await self.controller.status())
        }
        api.post("pin") { req, ctx in
            struct Body: Decodable { var artistDir: String; var pinned: Bool }
            let b = try await req.decode(as: Body.self, context: ctx)
            try await self.controller.perform(.pin(artistDir: b.artistDir, pinned: b.pinned))
            return try self.json(await self.controller.artists())
        }
        api.post("alerts/dismiss") { req, ctx in
            struct Body: Decodable { var id: String }
            let b = try await req.decode(as: Body.self, context: ctx)
            await self.controller.dismissAlert(b.id)
            return try self.json(await self.controller.status())
        }
        api.put("settings") { req, ctx in
            let s = try await req.decode(as: Settings.self, context: ctx)
            try await self.controller.updateSettings(s)
            return try self.json(s)
        }

        router.get("/events") { request, _ -> Response in
            guard self.authorized(request) else { return Response(status: .unauthorized) }
            let (id, stream) = await self.controller.bus.subscribe()
            let controller = self.controller
            let body = AsyncStream<ByteBuffer> { cont in
                let task = Task {
                    // Initial snapshot so a fresh page renders immediately.
                    if let s = try? Self.encoder.encode(Event.status(await controller.status())) {
                        cont.yield(ByteBuffer(string: "data: \(String(decoding: s, as: UTF8.self))\n\n"))
                    }
                    let heartbeat = Task {
                        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 15_000_000_000); cont.yield(ByteBuffer(string: ": hb\n\n")) }
                    }
                    for await ev in stream {
                        if let d = try? Self.encoder.encode(ev) { cont.yield(ByteBuffer(string: "data: \(String(decoding: d, as: UTF8.self))\n\n")) }
                    }
                    heartbeat.cancel()
                    cont.finish()
                }
                cont.onTermination = { _ in task.cancel(); Task { await controller.bus.unsubscribe(id) } }
            }
            return Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-cache", .connection: "keep-alive"],
                            body: .init(asyncSequence: body))
        }

        return Application(router: router, configuration: .init(address: .hostname(host, port: port), serverName: "Convertable"))
    }

    // MARK: Helpers

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    func json<T: Encodable>(_ value: T) throws -> Response {
        let data = try Self.encoder.encode(value)
        return Response(status: .ok, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    func authorized(_ request: Request) -> Bool {
        Auth.tokenPresent(request, token: token)
    }
}

enum Auth {
    static func tokenPresent(_ request: Request, token: String) -> Bool {
        if let auth = request.headers[.authorization], auth == "Bearer \(token)" { return true }
        if let cookie = request.headers[.cookie] {
            for part in cookie.split(separator: ";") {
                let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "ct", kv[1] == token[...] { return true }
            }
        }
        return false
    }
}

struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard Auth.tokenPresent(request, token: token) else { throw HTTPError(.unauthorized) }
        if request.method != .get, request.headers[.init("X-Convertable")!] == nil { throw HTTPError(.forbidden, message: "missing X-Convertable header") }
        return try await next(request, context)
    }
}
