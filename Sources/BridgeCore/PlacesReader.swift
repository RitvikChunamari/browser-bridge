import Foundation
import CSQLite

enum PlacesReader {
    public static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func withSafeReadCopy<T>(_ url: URL, block: (URL) throws -> T) throws -> T {
        // Attempt direct read first (supported zero-lock via immutable=1)
        if let result = try? block(url) {
            return result
        }

        // If direct read failed (e.g. database is locked by active browser process),
        // copy database and WAL/SHM/journal to a temporary directory for an isolated, unlocked read
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("bridge_sqlite_reader_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent(url.lastPathComponent)
        try fm.copyItem(at: url, to: tempDB)

        let wal = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-wal")
        if fm.fileExists(atPath: wal.path) {
            try? fm.copyItem(at: wal, to: tempDir.appendingPathComponent("\(url.lastPathComponent)-wal"))
        }

        let shm = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-shm")
        if fm.fileExists(atPath: shm.path) {
            try? fm.copyItem(at: shm, to: tempDir.appendingPathComponent("\(url.lastPathComponent)-shm"))
        }

        let journal = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-journal")
        if fm.fileExists(atPath: journal.path) {
            try? fm.copyItem(at: journal, to: tempDir.appendingPathComponent("\(url.lastPathComponent)-journal"))
        }

        return try block(tempDB)
    }

    static func rows(_ url: URL, sql: String, consume: (OpaquePointer) -> Void) throws {
        var db: OpaquePointer?
        let uri = "file:\(url.path)?immutable=1"
        var status = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if status != SQLITE_OK {
            if let d = db { sqlite3_close(d); db = nil }
            status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        }
        if status != SQLITE_OK {
            if let d = db { sqlite3_close(d); db = nil }
            status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        }
        guard status == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw BridgeError.message("Cannot open \(url.lastPathComponent) read-only.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
            let detail = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown SQLite error"
            throw BridgeError.message("\(url.lastPathComponent): \(detail)")
        }
        defer { sqlite3_finalize(query) }
        var stepStatus = sqlite3_step(query)
        while stepStatus == SQLITE_ROW { consume(query); stepStatus = sqlite3_step(query) }
        guard stepStatus == SQLITE_DONE else { throw BridgeError.message("Could not finish reading \(url.lastPathComponent). Close the source browser and retry.") }
    }

    static func string(_ query: OpaquePointer, _ col: Int32) -> String? {
        guard let value = sqlite3_column_text(query, col) else { return nil }; return String(cString: value)
    }

    static func read(_ url: URL) throws -> ([Bookmark], [HistoryItem]) {
        try withSafeReadCopy(url) { safeURL in
            var bookmarks: [Bookmark] = [], history: [HistoryItem] = []
            do {
                try rows(safeURL, sql: "SELECT b.id,b.parent,b.title,p.url,b.type FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk=p.id ORDER BY b.parent,b.position") { q in
                    bookmarks.append(Bookmark(id: sqlite3_column_int64(q, 0), parent: sqlite3_column_int64(q, 1), title: string(q, 2) ?? "", url: string(q, 3), type: Int(sqlite3_column_int(q, 4))))
                }
            } catch {
                if !error.localizedDescription.contains("no such table") {
                    throw error
                }
            }
            do {
                try rows(safeURL, sql: "SELECT url,title,last_visit_date,visit_count,typed FROM moz_places WHERE last_visit_date IS NOT NULL AND last_visit_date > 0 ORDER BY last_visit_date DESC") { q in
                    guard let rawURL = string(q, 0) else { return }
                    let u = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !u.isEmpty, !u.hasPrefix("place:"), !u.hasPrefix("about:"), !u.hasPrefix("chrome:"), !u.hasPrefix("moz-extension:") else { return }
                    let t = (string(q, 1) ?? u).trimmingCharacters(in: .whitespacesAndNewlines)
                    let vCount = Int(sqlite3_column_int(q, 3))
                    let tCount = Int(sqlite3_column_int(q, 4))
                    history.append(HistoryItem(url: u, title: t.isEmpty ? u : t, time: sqlite3_column_double(q, 2) / 1000, visitCount: max(1, vCount), typedCount: max(0, tCount)))
                }
            } catch {
                try rows(safeURL, sql: "SELECT url,title,last_visit_date FROM moz_places WHERE last_visit_date IS NOT NULL AND last_visit_date > 0 ORDER BY last_visit_date DESC") { q in
                    guard let rawURL = string(q, 0) else { return }
                    let u = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !u.isEmpty, !u.hasPrefix("place:"), !u.hasPrefix("about:"), !u.hasPrefix("chrome:"), !u.hasPrefix("moz-extension:") else { return }
                    let t = (string(q, 1) ?? u).trimmingCharacters(in: .whitespacesAndNewlines)
                    history.append(HistoryItem(url: u, title: t.isEmpty ? u : t, time: sqlite3_column_double(q, 2) / 1000))
                }
            }
            return (bookmarks, history)
        }
    }

    static func cookieCount(_ url: URL) throws -> Int {
        try withSafeReadCopy(url) { safeURL in
            var count = 0
            try rows(safeURL, sql: "SELECT count(*) FROM moz_cookies") { count = Int(sqlite3_column_int($0, 0)) }
            return count
        }
    }
}
