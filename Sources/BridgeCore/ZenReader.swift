import Foundation

public enum ZenReader {
    public static func profiles(root: URL) throws -> [BrowserProfile] {
        let fm = FileManager.default
        var found: [BrowserProfile] = []
        let ini = root.appendingPathComponent("profiles.ini")
        if let text = try? String(contentsOf: ini, encoding: .utf8) {
            var section: [String: String] = [:]
            func flush() {
                guard let path = section["Path"] else { return }
                let url = section["IsRelative"] == "0" ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
                if fm.fileExists(atPath: url.path) { found.append(.init(name: section["Name"] ?? url.lastPathComponent, path: url)) }
            }
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { flush(); section = [:] }
                else if let eq = line.firstIndex(of: "=") { section[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
            }
            flush()
        }
        return Array(Set(found)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func read(profile: URL) throws -> Snapshot {
        let fm = FileManager.default
        let candidates = ["zen-sessions.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4", "sessionstore-backups/previous.jsonlz4", "sessionstore.js", "sessionstore-backups/recovery.js", "sessionstore-backups/previous.js"]
            .map { profile.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
            .sorted { modification($0) > modification($1) }
        var snapshot: Snapshot?
        var errors: [String] = []
        for file in candidates {
            do {
                var value = try readSession(Data(contentsOf: file))
                value.sourceFile = file.lastPathComponent
                if snapshot == nil { snapshot = value }
                if file.lastPathComponent == "zen-sessions.jsonlz4", value.tabs.isEmpty,
                   !value.spaces.isEmpty || !value.folders.isEmpty { continue }
                snapshot = value
                break
            }
            catch { errors.append("Could not read \(file.lastPathComponent): \(error.localizedDescription)") }
        }
        var result = snapshot ?? Snapshot()
        // Zen keeps persistent organization separately from Firefox's more recent live session.
        // Only supplement a generic session lacking organization, matching stable IDs rather than URLs.
        let organizationFile = profile.appendingPathComponent("zen-sessions.jsonlz4")
        if result.sourceFile != "zen-sessions.jsonlz4", result.spaces.isEmpty, result.folders.isEmpty,
           fm.fileExists(atPath: organizationFile.path) {
            do {
                let organization = try readSession(Data(contentsOf: organizationFile))
                if !organization.spaces.isEmpty || !organization.folders.isEmpty {
                    result.spaces = organization.spaces
                    result.folders = organization.folders
                    let byID = Dictionary(organization.tabs.filter { !$0.id.hasPrefix("window-") }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    result.tabs = result.tabs.map { live in
                        guard let native = byID[live.id] else { return live }
                        return BrowserTab(id: live.id, url: live.url, title: live.title,
                            pinned: native.pinned, essential: native.essential,
                            spaceID: native.spaceID, folderID: native.folderID, order: live.order,
                            originalURL: native.originalURL ?? live.originalURL, container: native.container)
                    }
                    let seen = Set(result.tabs.map(\.id))
                    for tab in organization.tabs where !tab.id.hasPrefix("window-") && !seen.contains(tab.id) && (tab.pinned || tab.essential) {
                        result.tabs.append(BrowserTab(id: tab.id, url: tab.url, title: tab.title,
                            pinned: tab.pinned, essential: tab.essential, spaceID: tab.spaceID,
                            folderID: tab.folderID, order: result.tabs.count, originalURL: tab.originalURL, container: tab.container))
                    }
                    result.sourceFile += " + zen-sessions.jsonlz4 organization"
                    result.warnings.append("Organization was supplemented from Zen's separate persistent session using stable tab IDs. Persistent pins absent from the live session are retained; review freshness before importing.")
                }
            } catch { errors.append("Could not supplement Zen organization: \(error.localizedDescription)") }
        }
        result.warnings += errors
        if snapshot == nil { result.warnings.append("No readable tab session found. Bookmarks and history may still be available.") }
        let places = profile.appendingPathComponent("places.sqlite")
        if fm.fileExists(atPath: places.path) {
            do {
                let data = try PlacesReader.read(places)
                result.bookmarks = data.0; result.history = data.1
            } catch { result.warnings.append("Could not read bookmarks and history: \(error.localizedDescription). Close the source browser and rescan; original database files are still included in backups.") }
        } else { result.warnings.append("places.sqlite is missing; bookmarks and history could not be read.") }
        let logins = profile.appendingPathComponent("logins.json")
        if fm.fileExists(atPath: logins.path) {
            do {
                let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: logins)) as? [String: Any]
                result.passwordCount = (obj?["logins"] as? [Any])?.count ?? 0
            } catch { result.warnings.append("Password inventory unreadable; original credential files will still be backed up.") }
        }
        let cookies = profile.appendingPathComponent("cookies.sqlite")
        if fm.fileExists(atPath: cookies.path) {
            do { result.cookieCount = try PlacesReader.cookieCount(cookies) }
            catch { result.warnings.append("Cookie inventory unreadable; original cookie files will still be backed up.") }
        }
        return result
    }

    public static func readSession(_ data: Data) throws -> Snapshot {
        let json = data.starts(with: Array("mozLz40\0".utf8)) ? try decodeLZ4(data) : data
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw BridgeError.message("Session is not a JSON object.") }
        let windows = root["windows"] as? [[String: Any]] ?? [root]
        var result = Snapshot()
        var seenTabs = Set<String>(), seenFolders = Set<String>(), seenSpaces = Set<String>()
        for window in windows {
            for space in window["spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["uuid"] as? String, seenSpaces.insert(id).inserted else { continue }
                result.spaces.append(Space(id: id, name: space["name"] as? String ?? "Unnamed space"))
            }
            for folder in window["folders"] as? [[String: Any]] ?? [] {
                guard let id = folder["id"] as? String, seenFolders.insert(id).inserted else { continue }
                result.folders.append(Folder(id: id, name: folder["name"] as? String ?? "Untitled folder", parentID: folder["parentId"] as? String, spaceID: folder["workspaceId"] as? String))
            }
            for (position, tab) in (window["tabs"] as? [[String: Any]] ?? []).enumerated() {
                let entries = tab["entries"] as? [[String: Any]] ?? []
                let index = (tab["index"] as? Int ?? entries.count) - 1
                guard !entries.isEmpty else { continue }
                let entry = entries[min(max(0, index), entries.count - 1)]
                guard let url = entry["url"] as? String else { continue }
                let id = tab["zenSyncId"] as? String ?? tab["zenPinnedId"] as? String ?? "window-\(windows.count)-\(result.tabs.count)-\(position)"
                guard seenTabs.insert(id).inserted else { continue }
                let initial = tab["_zenPinnedInitialState"] as? [String: Any]
                result.tabs.append(BrowserTab(id: id, url: url, title: entry["title"] as? String ?? url,
                    pinned: tab["pinned"] as? Bool ?? false, essential: tab["zenEssential"] as? Bool ?? false,
                    spaceID: tab["zenWorkspace"] as? String, folderID: tab["groupId"] as? String,
                    order: result.tabs.count, originalURL: initial?["url"] as? String, container: tab["userContextId"] as? Int ?? 0))
            }
        }
        if result.tabs.isEmpty && root["tabs"] == nil && root["windows"] == nil && root["spaces"] == nil && root["folders"] == nil { throw BridgeError.message("Unrecognized Firefox/Zen session structure.") }
        return result
    }

    private static func modification(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

    // Firefox uses a raw LZ4 block after its eight-byte magic and LE output size.
    public static func decodeLZ4(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw BridgeError.message("Truncated compressed session.") }
        let expected = (0..<4).reduce(0) { $0 | Int(bytes[8 + $1]) << (8 * $1) }
        guard expected <= 256 * 1024 * 1024 else { throw BridgeError.message("Session exceeds the 256 MB safety limit.") }
        var output = [UInt8](); output.reserveCapacity(expected)
        var i = 12
        func extended(_ base: Int) throws -> Int {
            var length = base
            if base == 15 {
                while true {
                    guard i < bytes.count else { throw BridgeError.message("Truncated LZ4 length.") }
                    let value = Int(bytes[i]); i += 1; length += value
                    guard length <= expected else { throw BridgeError.message("Invalid LZ4 length.") }
                    if value != 255 { break }
                }
            }
            return length
        }
        while i < bytes.count {
            let token = bytes[i]; i += 1
            let literal = try extended(Int(token >> 4))
            guard literal <= bytes.count - i, output.count + literal <= expected else { throw BridgeError.message("Invalid LZ4 literals.") }
            output.append(contentsOf: bytes[i..<(i + literal)]); i += literal
            if i == bytes.count { break }
            guard i + 1 < bytes.count else { throw BridgeError.message("Truncated LZ4 offset.") }
            let offset = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
            let length = try extended(Int(token & 15)) + 4
            guard offset > 0, offset <= output.count, output.count + length <= expected else { throw BridgeError.message("Invalid LZ4 back reference.") }
            for _ in 0..<length { output.append(output[output.count - offset]) }
        }
        guard output.count == expected else { throw BridgeError.message("Compressed session size does not match its header.") }
        return Data(output)
    }
}
