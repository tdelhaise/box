import PackagePlugin

@main
struct BoxBuildInfoPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard target.name == "BoxBuildInfoSupport" else {
            return []
        }

        let tool = try context.tool(named: "BoxBuildInfoGenerator")
        let output = context.pluginWorkDirectoryURL.appending(path: "GeneratedBuildInfo.swift")

        return [
            .buildCommand(
                displayName: "Generating BoxBuildInfo.swift",
                executable: tool.url,
                arguments: [
                    context.package.directoryURL.path(percentEncoded: false),
                    output.path(percentEncoded: false)
                ],
                environment: [:],
                outputFiles: [output]
            )
        ]
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension BoxBuildInfoPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        guard target.displayName == "BoxBuildInfoSupport" else {
            return []
        }
        let tool = try context.tool(named: "BoxBuildInfoGenerator")
        let output = context.pluginWorkDirectoryURL.appending(path: "GeneratedBuildInfo.swift")

        return [
            .buildCommand(
                displayName: "Generating BoxBuildInfo.swift",
                executable: tool.url,
                arguments: [
                    context.xcodeProject.directoryURL.path(percentEncoded: false),
                    output.path(percentEncoded: false)
                ],
                environment: [:],
                outputFiles: [output]
            )
        ]
    }
}
#endif
