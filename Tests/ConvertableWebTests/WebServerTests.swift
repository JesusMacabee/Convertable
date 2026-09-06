import XCTest
import Hummingbird
import HummingbirdTesting
@testable import ConvertableWeb
@testable import ConvertableCore

final class WebServerTests: XCTestCase {
    var settings: Settings!
    var controller: AppController!
    var server: WebServer!

    override func setUpWithError() throws {
        settings = Settings()
        settings.web.token = "test-token-123"
        let store = try Store.inMemory()
        // A tiny library so artists/preview have something to return.
        for (i, rel) in ["Adele/21/01.flac", "Adele/21/02.flac", "Beck/Odelay/01.mp3"].enumerated() {
            let parts = rel.split(separator: "/").map(String.init)
            try store.db.run("""
                INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan)
                VALUES (?,?,?,?,?,?,?,?,?,?,1)
                """, [.text(rel), .text(parts[0]), .text(parts[1]), .text("." + (rel as NSString).pathExtension),
                      .text(rel.hasSuffix("mp3") ? "lossy" : "lossless"), .integer(1000 * Int64(i + 1)), .real(1), .real(1), .integer(3), .real(1)])
        }
        controller = AppController(settings: settings, store: store)
        server = WebServer(controller: controller, settings: settings)
    }

    var auth: HTTPFields { var h = HTTPFields(); h[.authorization] = "Bearer test-token-123"; return h }
    var authMut: HTTPFields { var h = auth; h[.init("X-Convertable")!] = "1"; h[.contentType] = "application/json"; return h }

    func testHealthNeedsNoAuth() async throws {
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { XCTAssertEqual($0.status, .ok) }
        }
    }

    func testAPIRejectsMissingOrWrongToken() async throws {
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/api/status", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            var bad = HTTPFields(); bad[.authorization] = "Bearer nope"
            try await client.execute(uri: "/api/status", method: .get, headers: bad) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(uri: "/", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(uri: "/events", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testTokenLinkSetsCookieAndCookieAuthorises() async throws {
        try await server.buildApplication().test(.router) { client in
            var cookie = ""
            try await client.execute(uri: "/?token=test-token-123", method: .get) { r in
                XCTAssertEqual(r.status, .seeOther)
                cookie = r.headers[.setCookie] ?? ""
                XCTAssertTrue(cookie.hasPrefix("ct=test-token-123"))
                XCTAssertTrue(cookie.contains("HttpOnly"))
            }
            var h = HTTPFields(); h[.cookie] = "ct=test-token-123"
            try await client.execute(uri: "/", method: .get, headers: h) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertTrue(String(buffer: r.body).contains("<title>Convertable</title>"))
            }
            try await client.execute(uri: "/api/artists", method: .get, headers: h) { XCTAssertEqual($0.status, .ok) }
        }
    }

    func testStatusAndArtists() async throws {
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/api/status", method: .get, headers: auth) { r in
                XCTAssertEqual(r.status, .ok)
                let s = try JSONDecoder().decode(StatusSnapshot.self, from: Data(buffer: r.body))
                XCTAssertEqual(s.library.tracks, 3); XCTAssertEqual(s.library.artists, 2)
            }
            try await client.execute(uri: "/api/artists", method: .get, headers: auth) { r in
                let a = try JSONDecoder().decode([ArtistRow].self, from: Data(buffer: r.body))
                XCTAssertEqual(a.map(\.dir), ["Adele", "Beck"])
                XCTAssertEqual(a[0].bytes, 3000)
            }
        }
    }

    func testMutationsNeedTheSameOriginHeader() async throws {
        try await server.buildApplication().test(.router) { client in
            let body = ByteBuffer(string: #"{"artistDir":"Adele","pinned":true}"#)
            var noHeader = auth; noHeader[.contentType] = "application/json"
            try await client.execute(uri: "/api/pin", method: .post, headers: noHeader, body: body) { XCTAssertEqual($0.status, .forbidden) }
            try await client.execute(uri: "/api/pin", method: .post, headers: authMut, body: body) { r in
                XCTAssertEqual(r.status, .ok)
                let a = try JSONDecoder().decode([ArtistRow].self, from: Data(buffer: r.body))
                XCTAssertTrue(a.first { $0.dir == "Adele" }!.pinned)
            }
        }
    }

    func testPreviewRoundTrip() async throws {
        try await server.buildApplication().test(.router) { client in
            let sel = Selection(mode: .artists(["Adele"]), cap: nil, ignoreSettle: true)
            let body = ByteBuffer(bytes: try JSONEncoder().encode(sel))
            try await client.execute(uri: "/api/preview", method: .post, headers: authMut, body: body) { r in
                XCTAssertEqual(r.status, .ok)
                let p = try JSONDecoder().decode(PlanPreview.self, from: Data(buffer: r.body))
                XCTAssertEqual(p.albums.count, 1); XCTAssertEqual(p.tracks, 2); XCTAssertEqual(p.bytesIn, 3000)
                XCTAssertEqual(p.albums[0].artist, "Adele")
            }
        }
    }

    func testSettingsRoundTrip() async throws {
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/api/settings", method: .get, headers: auth) { r in
                let got = try JSONDecoder().decode(Settings.self, from: Data(buffer: r.body))
                XCTAssertEqual(got.web.token, "test-token-123")
            }
        }
    }

}
