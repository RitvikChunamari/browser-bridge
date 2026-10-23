import Foundation
import Testing
import CSQLite
@testable import BridgeCore

struct ExportTests {
    @Test func compressedSessionRejectsBadOffsetsAndSupportsOverlappingMatches() throws {
        let header = Array("mozLz40\0".utf8) + [UInt8(5), 0, 0, 0]
        #expect(try ZenReader.decodeLZ4(Data(header + [0x10, 97, 1, 0])) == Data("aaaaa".utf8))
        #expect(throws: (any Error).self) { try ZenReader.decodeLZ4(Data(header + [0x00, 0, 0])) }
        #expect(throws: (any Error).self) { try ZenReader.readSession(Data("mozLz40\0".utf8)) }
    }

    @Test func mirroredWindowsDoNotDuplicateEssentials() throws {
        let tab: [String: Any] = ["zenSyncId":"shared", "zenEssential":true, "entries":[["url":"https://example.com"]]]
        let json = try JSONSerialization.data(withJSONObject: ["windows":[["tabs":[tab]],["tabs":[tab]]]])
        let snapshot = try ZenReader.readSession(json)
        #expect(snapshot.tabs.count == 1)
        #expect(snapshot.tabs[0].essential)
    }

    @Test func readsBookmarksAndOriginalHistoryFromFirefoxDatabase() throws {
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("places.sqlite").path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY,url TEXT,title TEXT,last_visit_date INTEGER);
        CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY,parent INTEGER,title TEXT,fk INTEGER,type INTEGER,position INTEGER);
        INSERT INTO moz_places VALUES(1,'https://example.com','Example',1700000000000000);
        INSERT INTO moz_bookmarks VALUES(1,0,'Root',NULL,2,0),(2,1,'Saved',1,1,0);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK); sqlite3_close(db)
        let snapshot = try ZenReader.read(profile: root)
        #expect(snapshot.bookmarks.count == 2)
        #expect(snapshot.bookmarks[1].title == "Saved")
        #expect(snapshot.history[0].time == 1700000000000)
    }
    @Test func lockedPlacesDoesNotHideReadableTabs() throws {
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(#"{"tabs":[{"zenSyncId":"t","entries":[{"url":"https://example.com"}]}]}"#.utf8).write(to: root.appendingPathComponent("zen-sessions.jsonlz4"))
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("places.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE locked(value); BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        let snapshot = try ZenReader.read(profile: root)
        #expect(snapshot.tabs.count == 1)
        #expect(snapshot.warnings.contains { $0.contains("bookmarks") && $0.contains("history") })
    }
    @Test func testPreservesWorkspaceFolderAndEssentialSemantics() throws {
        let session = Data(#"{"spaces":[{"uuid":"work","name":"Work"}],"folders":[{"id":"outer","name":"Projects","workspaceId":"work"},{"id":"inner","name":"Research","parentId":"outer","workspaceId":"work"}],"tabs":[{"entries":[{"url":"https://example.com/old","title":"Old"},{"url":"https://example.com/new","title":"New"}],"index":2,"zenSyncId":"one","zenEssential":true,"pinned":true,"zenWorkspace":"work","groupId":"inner"}]}"#.utf8)
        let snapshot = try ZenReader.readSession(session)
        #expect(snapshot.spaces.map(\.name) == ["Work"])
        #expect(snapshot.folders.last?.parentID == "outer")
        #expect(snapshot.tabs.first?.url == "https://example.com/new")
        #expect(snapshot.tabs.first?.essential == true)
        #expect(snapshot.tabs.first?.folderID == "inner")
    }
}
