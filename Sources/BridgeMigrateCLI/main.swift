import Foundation
import BridgeCore

@main
struct BridgeMigrateMain {
    static func main() async {
        do {
            let output = try await OneClickCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
            if !output.isEmpty {
                print(output)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
