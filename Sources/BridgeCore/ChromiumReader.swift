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
        var historyURL = profile.appendingPathComponent("History")
        let fm = FileManager.default
        if !fm.fileExists(atPath: historyURL.path) {
            let defaultHist = profile.appendingPathComponent("Default/History")
            if fm.fileExists(atPath: defaultHist.path) {
                historyURL = defaultHist
            } else {
                let ls = profile.appendingPathComponent("Local State")
                var candidate: URL?
                if let lsData = try? Data(contentsOf: ls),
                   let lsObj = try? JSONSerialization.jsonObject(with: lsData) as? [String: Any],
                   let pDict = lsObj["profile"] as? [String: Any],
                   let lastUsed = pDict["last_used"] as? String {
                    let lastUsedHist = profile.appendingPathComponent("\(lastUsed)/History")
                    if fm.fileExists(atPath: lastUsedHist.path) {
                        candidate = lastUsedHist
                    }
                }
                if candidate == nil, let children = try? fm.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil) {
                    for child in children where child.lastPathComponent.hasPrefix("Profile") || child.lastPathComponent == "Default" {
                        let childHist = child.appendingPathComponent("History")
                        if fm.fileExists(atPath: childHist.path) {
                            candidate = childHist
                            break
                        }
                    }
                }
                if let candidate {
                    historyURL = candidate
                }
            }
        }
        if fm.fileExists(atPath: historyURL.path) {
            do {
                try PlacesReader.withSafeReadCopy(historyURL) { safeURL in
                    do {
                        try PlacesReader.rows(safeURL, sql: "SELECT url,title,last_visit_time,visit_count,typed_count FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC") { q in
                            guard let rawURL = PlacesReader.string(q, 0) else { return }
                            let u = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !u.isEmpty, !u.hasPrefix("chrome:"), !u.hasPrefix("chrome-extension:"), !u.hasPrefix("dia:"), !u.hasPrefix("brave:"), !u.hasPrefix("edge:"), !u.hasPrefix("about:"), !u.hasPrefix("data:") else { return }
                            let t = (PlacesReader.string(q, 1) ?? u).trimmingCharacters(in: .whitespacesAndNewlines)
                            let vCount = Int(sqlite3_column_int(q, 3))
                            let tCount = Int(sqlite3_column_int(q, 4))
                            result.history.append(.init(url: u, title: t.isEmpty ? u : t, time: sqlite3_column_double(q, 2) / 1000 - 11644473600000, visitCount: max(1, vCount), typedCount: max(0, tCount)))
                        }
                    } catch {
                        try PlacesReader.rows(safeURL, sql: "SELECT url,title,last_visit_time FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC") { q in
                            guard let rawURL = PlacesReader.string(q, 0) else { return }
                            let u = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !u.isEmpty, !u.hasPrefix("chrome:"), !u.hasPrefix("chrome-extension:"), !u.hasPrefix("dia:"), !u.hasPrefix("brave:"), !u.hasPrefix("edge:"), !u.hasPrefix("about:"), !u.hasPrefix("data:") else { return }
                            let t = (PlacesReader.string(q, 1) ?? u).trimmingCharacters(in: .whitespacesAndNewlines)
                            result.history.append(.init(url: u, title: t.isEmpty ? u : t, time: sqlite3_column_double(q, 2) / 1000 - 11644473600000))
                        }
                    }
                }
            } catch { result.warnings.append("History could not be read: \(error.localizedDescription). Close the source browser and retry; original files remain in the backup.") }
        }
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
