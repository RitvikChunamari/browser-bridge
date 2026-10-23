import Foundation

public struct PortableCapture: Codable, Sendable {
    public let schema: Int
    public let format: String
    public let browser: BrowserID
    public let capturedAt: String
    public let snapshot: Snapshot

    public static func load(_ url: URL, expectedBrowser: BrowserID) throws -> PortableCapture {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1024 * 1024 else { throw BridgeError.message("Capture exceeds the 256 MB safety limit.") }
        if ["html", "htm"].contains(url.pathExtension.lowercased()) {
            return PortableCapture(schema: 1, format: "browser-bridge-capture", browser: expectedBrowser,
                capturedAt: ISO8601DateFormatter().string(from: Date()), snapshot: try BookmarkHTML.read(Data(contentsOf: url)))
        }
        let capture = try JSONDecoder().decode(PortableCapture.self, from: Data(contentsOf: url))
        guard capture.schema == 1, capture.format == "browser-bridge-capture", capture.browser == expectedBrowser else {
            throw BridgeError.message("Choose a Browser Bridge capture made for \(expectedBrowser.name). Browser labels must match the selected source.")
        }
        guard capture.snapshot.tabs.count <= 200_000, capture.snapshot.folders.count <= 100_000 else { throw BridgeError.message("This capture is too large to import safely.") }
        return capture
    }

    public func supplement(_ original: Snapshot) -> Snapshot {
        var result = original
        if result.tabs.isEmpty {
            result.tabs = snapshot.tabs; result.spaces = snapshot.spaces; result.folders = snapshot.folders
            result.warnings.removeAll { $0.hasPrefix("Open tabs, pins and tab groups require live capture") }
            result.sourceFile += " + live capture"
        } else {
            result.warnings.append("The native session already contains tabs, so its organization takes precedence. The attached live capture is preserved separately rather than guessing matches by URL.")
        }
        if result.bookmarks.isEmpty { result.bookmarks = snapshot.bookmarks }
        if result.history.isEmpty { result.history = snapshot.history }
        if result.nativeOrganization == nil { result.nativeOrganization = snapshot.nativeOrganization }
        result.warnings += snapshot.warnings
        result.warnings.append("Live capture attached from \(capturedAt). Its browser label is selected by the exporter user; freshness and exact profile identity must be checked by the user.")
        return result
    }
}

public enum HelperBundle {
    public static func write(from resources: URL, to destination: URL, browser: BrowserID) throws {
        guard browser.family != .safari else { throw BridgeError.message("Safari uses file-based import/export, not this unpacked extension helper.") }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw BridgeError.message("Choose a new helper folder; an existing folder will not be overwritten.") }
        try fm.copyItem(at: resources, to: destination)
        if browser.family == .firefox {
            let chromiumManifest = destination.appendingPathComponent("manifest.json")
            try fm.removeItem(at: chromiumManifest)
            try fm.copyItem(at: destination.appendingPathComponent("manifest-firefox.json"), to: chromiumManifest)
        }
        let variant = destination.appendingPathComponent("manifest-firefox.json")
        if fm.fileExists(atPath: variant.path) { try fm.removeItem(at: variant) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        if let files = fm.enumerator(at: destination, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let file as URL in files {
                let directory = try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                try fm.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: file.path)
            }
        }
    }
}
