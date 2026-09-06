// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Convertable",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConvertableCore", targets: ["ConvertableCore"]),
        .executable(name: "convertctl", targets: ["convertctl"]),
        .executable(name: "ConvertableApp", targets: ["ConvertableApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Bridge to Homebrew's TagLib C API (libtag_c). Reads FLAC/ALAC/WAV/MP3 tags, writes MP4/ID3/FLAC tags.
        .systemLibrary(
            name: "CTagLib",
            path: "Sources/CTagLib",
            pkgConfig: "taglib_c",
            providers: [.brew(["taglib"])]
        ),
        // Everything that isn't UI: scan, state, plan, pipeline, tags, Music bridge, review, API.
        .target(
            name: "ConvertableCore",
            dependencies: ["CTagLib"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // HTTP + JSON + SSE server and the embedded dashboard.
        .target(
            name: "ConvertableWeb",
            dependencies: [
                "ConvertableCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            resources: [.copy("Dashboard")]
        ),
        // Diagnostics / scripting CLI over the same core API.
        .executableTarget(
            name: "convertctl",
            dependencies: [
                "ConvertableCore",
                "ConvertableWeb",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Menu bar app; hosts the web server.
        .executableTarget(
            name: "ConvertableApp",
            dependencies: ["ConvertableCore", "ConvertableWeb"]
        ),
        .testTarget(
            name: "ConvertableCoreTests",
            dependencies: ["ConvertableCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "ConvertableWebTests",
            dependencies: [
                "ConvertableWeb",
                "ConvertableCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
