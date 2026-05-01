import Foundation
import PackagePlugin

@main
struct BuildXCFrameworksPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let packageDirectoryURL = context.package.directoryURL
        let scriptURL = packageDirectoryURL
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("build-xcframeworks.sh", isDirectory: false)
        let process = Process()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments
        process.currentDirectoryURL = packageDirectoryURL
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PluginError.scriptFailed(status: process.terminationStatus)
        }
    }
}

private enum PluginError: Error, CustomStringConvertible {
    case scriptFailed(status: Int32)

    var description: String {
        switch self {
        case .scriptFailed(let status):
            return "build-xcframeworks.sh failed with exit status \(status)."
        }
    }
}
