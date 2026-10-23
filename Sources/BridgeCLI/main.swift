import Foundation
import BridgeCore
@main struct Inspect {
static func main() {
do {
    guard [2,3].contains(CommandLine.arguments.count) else { throw BridgeError.message("Usage: bridge-inspect [browser-id] PROFILE_PATH (read-only inventory)") }
    let browser = CommandLine.arguments.count == 3 ? BrowserID(rawValue: CommandLine.arguments[1]) : .zen
    guard let browser else { throw BridgeError.message("Unknown browser ID. Use helium, arc, zen, dia, chrome, firefox, brave, safari, edge, opera or vivaldi.") }
    let value = try BrowserReader.read(profile: URL(fileURLWithPath: CommandLine.arguments.last!), browser: browser)
    print("Tabs: \(value.tabs.count), spaces: \(value.spaces.count), folders: \(value.folders.count), bookmarks: \(value.bookmarks.count), history: \(value.history.count). Source: \(value.sourceFile)")
    for warning in value.warnings { print("Warning: \(warning)") }
} catch { print(error.localizedDescription); exit(1) }
}
}
