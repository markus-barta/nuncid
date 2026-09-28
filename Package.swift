// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Nuncid",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Nuncid", targets: ["Nuncid"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "Nuncid",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources/calendar-version-display.json"],
            resources: [.process("Resources/Brand"), .process("Resources/Release.json"),
                        .copy("Resources/VersioningBundle")],
            // The debug binary loads Sparkle from beside itself. Newer SwiftPM
            // product layouts do not add @loader_path, so unpackaged tests
            // cannot start without it. The packaged app still adds Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"])],
            plugins: [.plugin(name: "VersioningCheckPlugin")]
        ),
        .plugin(name: "VersioningCheckPlugin", capability: .buildTool())
    ],
    swiftLanguageVersions: [.v5]
)
