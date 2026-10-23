import Foundation
import CSQLite

enum PlacesReader {
    static func rows(_ url: URL, sql: String, consume: (OpaquePointer) -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw BridgeError.message("Cannot open \(url.lastPathComponent) read-only.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
            let detail = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown SQLite error"
            throw BridgeError.message("\(url.lastPathComponent): \(detail)")
        }
        defer { sqlite3_finalize(query) }
        var status = sqlite3_step(query)
        while status == SQLITE_ROW { consume(query); status = sqlite3_step(query) }
        guard status == SQLITE_DONE else { throw BridgeError.message("Could not finish reading \(url.lastPathComponent). Close the source browser and retry.") }
    }
    static func string(_ query: OpaquePointer, _ col: Int32) -> String? {
        guard let value = sqlite3_column_text(query, col) else { return nil }; return String(cString: value)
    }
    static func read(_ url: URL) throws -> ([Bookmark], [HistoryItem]) {
        var bookmarks: [Bookmark] = [], history: [HistoryItem] = []
        try rows(url, sql: "SELECT b.id,b.parent,b.title,p.url,b.type FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk=p.id ORDER BY b.parent,b.position") { q in
            bookmarks.append(Bookmark(id: sqlite3_column_int64(q, 0), parent: sqlite3_column_int64(q, 1), title: string(q, 2) ?? "", url: string(q, 3), type: Int(sqlite3_column_int(q, 4))))
        }
        try rows(url, sql: "SELECT url,title,last_visit_date FROM moz_places WHERE last_visit_date IS NOT NULL ORDER BY last_visit_date DESC") { q in
            guard let url = string(q, 0) else { return }
            history.append(HistoryItem(url: url, title: string(q, 1) ?? url, time: sqlite3_column_double(q, 2) / 1000))
        }
        return (bookmarks, history)
    }
    static func cookieCount(_ url: URL) throws -> Int {
        var count = 0; try rows(url, sql: "SELECT count(*) FROM moz_cookies") { count = Int(sqlite3_column_int($0, 0)) }; return count
    }
}
