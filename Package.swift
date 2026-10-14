// swift-tools-version:6.0
import PackageDescription

/// DuckDB ships as a prebuilt dylib (install name `@rpath/libduckdb.dylib`) next to its header.
/// Development builds find it through an rpath to this folder; `scripts/build-app.sh` copies it
/// into the app bundle and points the app at `Contents/Frameworks` instead.
let duckdbLibraryPath = Context.packageDirectory + "/Vendor/duckdb"

let package = Package(
    name: "FoxlumeQuery",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FoxlumeQuery", targets: ["FoxlumeQuery"]),
        .executable(name: "fqprobe", targets: ["fqprobe"]),
    ],
    targets: [
        /// The DuckDB C API, imported from the vendored `duckdb.h`.
        .target(
            name: "CDuckDB",
            linkerSettings: [
                .linkedLibrary("duckdb"),
                .unsafeFlags(["-L", duckdbLibraryPath, "-Xlinker", "-rpath", "-Xlinker", duckdbLibraryPath]),
            ]
        ),
        .target(
            name: "FoxlumeQueryCore",
            dependencies: ["CDuckDB"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "FoxlumeQuery",
            dependencies: ["FoxlumeQueryCore"]
        ),
        /// Command line probe used to exercise drivers against real servers without the UI.
        .executableTarget(
            name: "fqprobe",
            dependencies: ["FoxlumeQueryCore"]
        ),
        .testTarget(
            name: "FoxlumeQueryCoreTests",
            dependencies: ["FoxlumeQueryCore"]
        ),
        /// App-level checks (editor completion, filter bar, workspace caches) against the real AppKit classes.
        .testTarget(
            name: "FoxlumeQueryAppTests",
            dependencies: ["FoxlumeQuery", "FoxlumeQueryCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
