import Foundation
import CSQLite

enum SafariReader {
    static func read(profile: URL) -> Snapshot {
        var result = Snapshot()
        result.warnings.append("Safari discovery identifies data folders, not named profiles. Choose the intended folder manually; named-profile identity is not established by this adapter.")
        result.sourceFile = "Bookmarks.plist / History.db"
        do {
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: profile.appendingPathComponent("Bookmarks.plist")), format: nil)
            guard let root = object as? [String: Any] else { throw BridgeError.message("Unrecognized Safari bookmark format.") }
            var next: Int64 = 1
            func visit(_ node: [String: Any], parent: Int64) {
                let type = node["WebBookmarkType"] as? String
                guard type == "WebBookmarkTypeList" || type == "WebBookmarkTypeLeaf" else { return }
                let id = next; next += 1
                let title = node["Title"] as? String ?? (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                result.bookmarks.append(.init(id: id, parent: parent, title: title, url: node["URLString"] as? String, type: type == "WebBookmarkTypeList" ? 2 : 1))
                for child in node["Children"] as? [[String: Any]] ?? [] { visit(child, parent: id) }
            }
            visit(root, parent: 0)
        } catch { result.warnings.append("Safari bookmarks unavailable: \(error.localizedDescription). Grant file access or export bookmarks from Safari for file-based import.") }
        let histDB = profile.appendingPathComponent("History.db")
        if FileManager.default.fileExists(atPath: histDB.path) {
            do {
                try PlacesReader.withSafeReadCopy(histDB) { safeURL in
                    try PlacesReader.rows(safeURL, sql: "SELECT i.url,v.title,v.visit_time FROM history_visits v JOIN history_items i ON v.history_item=i.id ORDER BY v.visit_time DESC") { q in
                        guard let rawURL = PlacesReader.string(q, 0) else { return }
                        let u = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !u.isEmpty, !u.hasPrefix("about:"), !u.hasPrefix("javascript:"), !u.hasPrefix("data:") else { return }
                        let t = (PlacesReader.string(q, 1) ?? u).trimmingCharacters(in: .whitespacesAndNewlines)
                        result.history.append(.init(url: u, title: t.isEmpty ? u : t, time: (sqlite3_column_double(q, 2) + 978307200) * 1000))
                    }
                }
            } catch { result.warnings.append("Safari history unavailable: \(error.localizedDescription). macOS may require Full Disk Access; original files are only backed up when readable.") }
        }
        result.warnings.append("Safari tabs, Tab Groups, pins, passwords and cookies are not decoded. Use Safari's supported exports; native state is archive-only when readable.")
        return result
    }
}
