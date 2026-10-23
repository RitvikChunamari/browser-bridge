import Foundation

public enum ConnectorInstallation {
    public static let chromiumID = "gagbnkkjaiikbencmbaiancdbigcjlhd"
    public static let hostName = "local.browserbridge.connector"
    public static func install(browser: BrowserID, executable: URL, resources: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard browser.family != .safari else { throw ConnectorError.rejected("Safari uses guided file transfer; no connector is installed.") }
        let fm = FileManager.default
        let base = home.appendingPathComponent("Library/Application Support/Browser Bridge")
        guard base.resolvingSymlinksInPath() == base.standardizedFileURL else { throw ConnectorError.rejected("Connector folder must not be redirected by symbolic links.") }
        let hostDir = base.appendingPathComponent("NativeHost")
        try fm.createDirectory(at: hostDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let host = hostDir.appendingPathComponent("browser-bridge-host")
        // Refuse redirected host directories before replacing the stable executable.
        guard hostDir.resolvingSymlinksInPath() == hostDir.standardizedFileURL else { throw ConnectorError.rejected("Native host folder must not be redirected by symbolic links.") }
        let temp = hostDir.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: executable, to: temp)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
        if fm.fileExists(atPath: host.path) { _ = try fm.replaceItemAt(host, withItemAt: temp) } else { try fm.moveItem(at: temp, to: host) }
        let extensionDir = base.appendingPathComponent("Connectors/\(browser.rawValue)")
        if fm.fileExists(atPath: extensionDir.path) { try fm.removeItem(at: extensionDir) }
        try fm.createDirectory(at: extensionDir.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: resources, to: extensionDir)
        if browser.family == .firefox {
            try fm.removeItem(at: extensionDir.appendingPathComponent("manifest.json"))
            try fm.copyItem(at: extensionDir.appendingPathComponent("manifest-firefox.json"), to: extensionDir.appendingPathComponent("manifest.json"))
        }
        var manifest: [String: Any] = ["name": hostName, "description": "Browser Bridge local profile connector", "path": host.path, "type": "stdio"]
        manifest[browser.family == .firefox ? "allowed_extensions" : "allowed_origins"] = browser.family == .firefox ? ["connector@browser-bridge.local"] : ["chrome-extension://\(chromiumID)/"]
        let manifestDirectories: [String]
        if browser.family == .firefox { manifestDirectories = ["Library/Application Support/Mozilla/NativeMessagingHosts"] }
        else { manifestDirectories = browser.dataPaths.map { $0 + "/NativeMessagingHosts" } }
        for path in manifestDirectories {
            let directory = home.appendingPathComponent(path)
            guard directory.resolvingSymlinksInPath() == directory.standardizedFileURL else { throw ConnectorError.rejected("Native messaging manifest directory must not be a symbolic link.") }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(hostName).json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return extensionDir
    }
}
