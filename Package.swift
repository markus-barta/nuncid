// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Nuncid",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Nuncid", targets: ["Nuncid"])],
    targets: [
        .executableTarget(
            name: "Nuncid",
            exclude: ["Resources/calendar-version-display.json"],
            resources: [.process("Resources/Brand"), .process("Resources/Release.json"),
                        .copy("Resources/VersioningBundle")],
            plugins: [.plugin(name: "VersioningCheckPlugin")]
        ),
        .plugin(name: "VersioningCheckPlugin", capability: .buildTool())
    ],
    swiftLanguageVersions: [.v5]
)
