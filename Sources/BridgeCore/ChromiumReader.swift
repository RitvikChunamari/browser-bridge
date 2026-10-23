import Foundation
import CSQLite

enum ChromiumReader {
    static func read(profile: URL) -> Snapshot {
        var result = Snapshot()
        result.sourceFile = "Bookmarks / History"
        let bookmarks = profile.appendingPathComponent("Bookmarks")
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: bookmarks)) as? [String: Any]
            guard let roots = object?["roots"] as? [String: Any] else { throw BridgeError.message("Unrecognized bookmarks structure.") }
            var next: Int64 = 1
            func visit(_ node: [String: Any], parent: Int64) {
                guard let type = node["type"] as? String, type == "folder" || type == "url" else { return }
                let id = next; next += 1
                result.bookmarks.append(.init(id: id, parent: parent, title: node["name"] as? String ?? "", url: type == "url" ? node["url"] as? String : nil, type: type == "folder" ? 2 : 1))
                for child in node["children"] as? [[String: Any]] ?? [] { visit(child, parent: id) }
            }
            for key in roots.keys.sorted() { if let node = roots[key] as? [String: Any] { visit(node, parent: 0) } }
        } catch { result.warnings.append("Bookmarks could not be read: \(error.localizedDescription). Original files remain in the backup.") }
        do {
            try PlacesReader.rows(profile.appendingPathComponent("History"), sql: "SELECT url,title,last_visit_time FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC") { q in
                guard let url = PlacesReader.string(q, 0) else { return }
                result.history.append(.init(url: url, title: PlacesReader.string(q, 1) ?? url, time: sqlite3_column_double(q, 2) / 1000 - 11644473600000))
            }
        } catch { result.warnings.append("History could not be read: \(error.localizedDescription). Close the source browser and retry; original files remain in the backup.") }
        func count(_ relative: String, table: String) -> Int {
            let file = profile.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
            var count = 0
            do { try PlacesReader.rows(file, sql: "SELECT count(*) FROM \(table)") { count = Int(sqlite3_column_int($0, 0)) } }
            catch { result.warnings.append("\(relative) inventory could not be read; encrypted data remains archive-only.") }
            return count
        }
        result.passwordCount = count("Login Data", table: "logins")
        result.cookieCount = count(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Network/Cookies").path) ? "Network/Cookies" : "Cookies", table: "cookies")
        result.warnings.append("Open tabs, pins and tab groups require live capture in the source browser. Offline binary sessions remain in the backup.")
        result.warnings.append("Passwords and cookies are inventoried without decryption; encrypted credentials and signed-in sessions are archive-only.")
        return result
    }
}
