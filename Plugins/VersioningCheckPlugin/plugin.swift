import PackagePlugin

@main
struct VersioningCheckPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        [.prebuildCommand(
            displayName: "Verify pinned version presentation bundle",
            executable: Path("/usr/bin/python3"),
            arguments: [context.package.directory.appending("scripts/check-calendar-display.py").string],
            outputFilesDirectory: context.pluginWorkDirectory.appending("verified")
        )]
    }
}
