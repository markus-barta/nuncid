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
            plugins: [.plugin(name: "VersioningCheckPlugin")]
        ),
        .plugin(name: "VersioningCheckPlugin", capability: .buildTool())
    ],
    swiftLanguageVersions: [.v5]
)
