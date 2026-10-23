import Foundation

public enum BrowserReader {
    public static func discover(browser: BrowserID, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [BrowserProfile] {
        var profiles: [BrowserProfile] = []
        for root in browser.roots(home: home) {
            switch browser.family {
            case .firefox: profiles += try ZenReader.profiles(root: root)
            case .safari: profiles.append(.init(name: "Safari data folder · manual profile selection", path: root))
            case .chromium:
                let fm = FileManager.default
                if fm.fileExists(atPath: root.appendingPathComponent("Bookmarks").path) || fm.fileExists(atPath: root.appendingPathComponent("Preferences").path) {
                    profiles.append(.init(name: browser.name, path: root))
                }
                for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) where child.lastPathComponent == "Default" || child.lastPathComponent.hasPrefix("Profile ") {
                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    var name = child.lastPathComponent
                    if let data = try? Data(contentsOf: child.appendingPathComponent("Preferences")), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let profile = object["profile"] as? [String: Any], let label = profile["name"] as? String { name = label }
                    profiles.append(.init(name: name, path: child))
                }
            }
        }
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.path.standardizedFileURL.path).inserted }.sorted { $0.path.path < $1.path.path }
    }

    public static func read(profile: URL, browser: BrowserID) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: profile.path) else { throw BridgeError.message("The selected profile no longer exists.") }
        switch browser.family {
        case .firefox: return try ZenReader.read(profile: profile)
        case .safari: return SafariReader.read(profile: profile)
        case .chromium:
            var result = ChromiumReader.read(profile: profile)
            if browser == .arc { result.warnings.append("Arc sidebar, Spaces, Favorites and nested folders are experimental and archive-only. Use live capture for visible tabs; native sidebar layout is not decoded.") }
            if browser == .vivaldi { result.warnings.append("Vivaldi workspaces and tab stacks require live capture or remain archive-only; native workspace layout is not decoded.") }
            return result
        }
    }
}
