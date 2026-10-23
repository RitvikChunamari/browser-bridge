import Foundation
import Testing
import CSQLite
@testable import BridgeCore

struct BrowserReaderTests {
    @Test func chromiumExportsNestedBookmarksAndOriginalHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[{"type":"folder","name":"Work","children":[{"type":"url","name":"Example","url":"https://example.com"}]}]}}}"#.utf8).write(to: root.appendingPathComponent("Bookmarks"))
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("History").path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE urls(url TEXT,title TEXT,last_visit_time INTEGER); INSERT INTO urls VALUES('https://example.com','Example',13344473600000000);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let snapshot = try BrowserReader.read(profile: root, browser: .chrome)
        #expect(snapshot.bookmarks.map(\.title) == ["Bar", "Work", "Example"])
        #expect(snapshot.bookmarks[2].parent == snapshot.bookmarks[1].id)
        #expect(snapshot.history.first?.time == 1700000000000)
        #expect(snapshot.warnings.contains { $0.contains("live capture") })
    }
    @Test func safariPreservesFolderTreeAndVisitDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Bookmarks", "Children": [["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com", "URIDictionary": ["title": "Apple"]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: root.appendingPathComponent("Bookmarks.plist"))
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("History.db").path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE history_items(id INTEGER,url TEXT); CREATE TABLE history_visits(history_item INTEGER,title TEXT,visit_time REAL); INSERT INTO history_items VALUES(1,'https://apple.com'); INSERT INTO history_visits VALUES(1,'Apple',721692800);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let snapshot = try BrowserReader.read(profile: root, browser: .safari)
        #expect(snapshot.bookmarks.map(\.title) == ["Bookmarks", "Apple"])
        #expect(snapshot.bookmarks[1].parent == snapshot.bookmarks[0].id)
        #expect(snapshot.history.first?.time == 1700000000000)
    }

    @Test func discoveryFindsAllConfiguredBrowserProfilesWithoutDuplicates() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for browser in BrowserID.allCases {
            let root = home.appendingPathComponent(browser.dataPaths[0])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if browser.family == .firefox {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Profiles/main"), withIntermediateDirectories: true)
                try Data("[Profile0]\nName=Personal\nIsRelative=1\nPath=Profiles/main\n".utf8).write(to: root.appendingPathComponent("profiles.ini"))
            } else if browser.family == .chromium {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
            }
            let profiles = try BrowserReader.discover(browser: browser, home: home)
            #expect(profiles.count == 1)
        }
    }

    @Test func firefoxCanReadLegacyUncompressedSessionFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"windows":[{"tabs":[{"pinned":true,"entries":[{"url":"https://mozilla.org","title":"Mozilla"}]}]}]}"#.utf8).write(to: root.appendingPathComponent("sessionstore.js"))
        let snapshot = try BrowserReader.read(profile: root, browser: .firefox)
        #expect(snapshot.tabs.first?.url == "https://mozilla.org")
        #expect(snapshot.tabs.first?.pinned == true)
    }
}
