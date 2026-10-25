import Foundation
import Testing
import CSQLite
@testable import BridgeCore

@Test func testOneClickMigrationDirectToChromiumAndRollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("SourceProfile")
    let destProfile = root.appendingPathComponent("DestProfile")
    try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    // Setup source bookmarks JSON (Chromium format)
    let sourceBookmarks: [String: Any] = [
        "roots": [
            "bookmark_bar": [
                "children": [
                    ["name": "GitHub", "type": "url", "url": "https://github.com"],
                    ["name": "Swift", "type": "url", "url": "https://swift.org"]
                ],
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let sourceData = try JSONSerialization.data(withJSONObject: sourceBookmarks)
    try sourceData.write(to: sourceProfile.appendingPathComponent("Bookmarks"))

    // Setup destination with an existing bookmark
    let destBookmarks: [String: Any] = [
        "roots": [
            "bookmark_bar": [
                "children": [
                    ["name": "Existing Destination Site", "type": "url", "url": "https://example.com"]
                ],
                "name": "Bookmarks bar",
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let destData = try JSONSerialization.data(withJSONObject: destBookmarks)
    try destData.write(to: destProfile.appendingPathComponent("Bookmarks"))

    let backupDir = root.appendingPathComponent("Backups")

    // Run One-Click Migration
    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .chrome,
        sourceProfile: sourceProfile,
        destinationBrowser: .brave,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: true, history: false, groups: true),
        backupDirectory: backupDir,
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.sourceProfilePath == sourceProfile.path)
    #expect(receipt.destinationProfilePath == destProfile.path)
    #expect(receipt.bookmarksCount == 2)
    #expect(FileManager.default.fileExists(atPath: receipt.backupDirectoryPath))

    // Verify Destination Bookmarks file contains both original and migrated items
    let modifiedDestData = try Data(contentsOf: destProfile.appendingPathComponent("Bookmarks"))
    let modifiedJson = try #require(try JSONSerialization.jsonObject(with: modifiedDestData) as? [String: Any])
    let roots = try #require(modifiedJson["roots"] as? [String: Any])
    let bar = try #require(roots["bookmark_bar"] as? [String: Any])
    let children = try #require(bar["children"] as? [[String: Any]])

    // There should be the existing site AND the "Migrated from Chrome" folder
    #expect(children.contains { ($0["name"] as? String) == "Existing Destination Site" })
    let migratedFolder = try #require(children.first { ($0["name"] as? String) == "Migrated from Chrome" })
    let folderChildren = try #require(migratedFolder["children"] as? [[String: Any]])
    let bookmarksSubfolder = try #require(folderChildren.first { ($0["name"] as? String) == "Bookmarks" })
    let subChildren = try #require(bookmarksSubfolder["children"] as? [[String: Any]])
    #expect(subChildren.contains { ($0["name"] as? String) == "GitHub" })
    #expect(subChildren.contains { ($0["name"] as? String) == "Swift" })

    // Test 1-Click Rollback
    try await OneClickMigrator.rollback(receipt: receipt, closeDestinationIfRunning: false)

    let rolledBackData = try Data(contentsOf: destProfile.appendingPathComponent("Bookmarks"))
    let rolledBackJson = try #require(try JSONSerialization.jsonObject(with: rolledBackData) as? [String: Any])
    let rolledRoots = try #require(rolledBackJson["roots"] as? [String: Any])
    let rolledBar = try #require(rolledRoots["bookmark_bar"] as? [String: Any])
    let rolledChildren = try #require(rolledBar["children"] as? [[String: Any]])

    #expect(rolledChildren.contains { ($0["name"] as? String) == "Existing Destination Site" })
    #expect(!rolledChildren.contains { ($0["name"] as? String) == "Migrated from Chrome" })
}

@Test func testOneClickHandlesMissingOrMalformedDestinationBookmarks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("SourceProfile")
    let destProfile = root.appendingPathComponent("DestProfile")
    try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    // Setup source bookmarks JSON
    let sourceBookmarks: [String: Any] = [
        "roots": [
            "bookmark_bar": [
                "children": [
                    ["name": "Vercel", "type": "url", "url": "https://vercel.com"]
                ],
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let sourceData = try JSONSerialization.data(withJSONObject: sourceBookmarks)
    try sourceData.write(to: sourceProfile.appendingPathComponent("Bookmarks"))

    // Write malformed/corrupted Bookmarks file in destination
    try "corrupted { invalid json".write(to: destProfile.appendingPathComponent("Bookmarks"), atomically: true, encoding: .utf8)

    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .chrome,
        sourceProfile: sourceProfile,
        destinationBrowser: .brave,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: false, history: false, groups: false),
        backupDirectory: root.appendingPathComponent("Backups"),
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.bookmarksCount == 1)

    // Verify self-healed destination Bookmarks
    let healedData = try Data(contentsOf: destProfile.appendingPathComponent("Bookmarks"))
    let healedJson = try #require(try JSONSerialization.jsonObject(with: healedData) as? [String: Any])
    let roots = try #require(healedJson["roots"] as? [String: Any])
    let bar = try #require(roots["bookmark_bar"] as? [String: Any])
    let children = try #require(bar["children"] as? [[String: Any]])
    #expect(children.contains { ($0["name"] as? String) == "Migrated from Chrome" })
}

@Test func testOneClickHandlesMissingBookmarkBarInRoots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("SourceProfile")
    let destProfile = root.appendingPathComponent("DestProfile")
    try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    let sourceBookmarks: [String: Any] = [
        "roots": [
            "bookmark_bar": [
                "children": [
                    ["name": "Linear", "type": "url", "url": "https://linear.app"]
                ],
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let sourceData = try JSONSerialization.data(withJSONObject: sourceBookmarks)
    try sourceData.write(to: sourceProfile.appendingPathComponent("Bookmarks"))

    // Destination has roots, but NO bookmark_bar key
    let destBookmarks: [String: Any] = [
        "roots": [
            "other": [
                "children": [] as [[String: Any]],
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let destData = try JSONSerialization.data(withJSONObject: destBookmarks)
    try destData.write(to: destProfile.appendingPathComponent("Bookmarks"))

    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .edge,
        sourceProfile: sourceProfile,
        destinationBrowser: .chrome,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: false, history: false, groups: false),
        backupDirectory: root.appendingPathComponent("Backups"),
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.bookmarksCount == 1)
}

@Test func testOneClickMigrationToFirefoxGeneratesHTMLAndBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("SourceProfile")
    let destProfile = root.appendingPathComponent("FirefoxProfile")
    try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    let sourceBookmarks: [String: Any] = [
        "roots": [
            "bookmark_bar": [
                "children": [
                    ["name": "Rust Lang", "type": "url", "url": "https://www.rust-lang.org"]
                ],
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let sourceData = try JSONSerialization.data(withJSONObject: sourceBookmarks)
    try sourceData.write(to: sourceProfile.appendingPathComponent("Bookmarks"))

    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .arc,
        sourceProfile: sourceProfile,
        destinationBrowser: .zen,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: true, history: false, groups: true),
        backupDirectory: root.appendingPathComponent("Backups"),
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.sourceProfilePath == sourceProfile.path)
    #expect(receipt.destinationProfilePath == destProfile.path)
    #expect(receipt.destinationBrowser == .zen)
    #expect(FileManager.default.fileExists(atPath: destProfile.appendingPathComponent("Bookmarks.html").path))
    let htmlContent = try String(contentsOf: destProfile.appendingPathComponent("Bookmarks.html"), encoding: .utf8)
    #expect(htmlContent.contains("Rust Lang"))
    #expect(htmlContent.contains("https://www.rust-lang.org"))
}

@Test func testOneClickNetscapeHTMLPreservesNestedFolders() throws {
    var snapshot = Snapshot()
    snapshot.bookmarks = [
        Bookmark(id: 1, parent: 0, title: "Development", url: nil, type: 2),
        Bookmark(id: 2, parent: 1, title: "Swift", url: "https://swift.org", type: 1),
        Bookmark(id: 3, parent: 1, title: "Tools", url: nil, type: 2),
        Bookmark(id: 4, parent: 3, title: "GitHub", url: "https://github.com", type: 1)
    ]
    snapshot.tabs = [
        BrowserTab(id: "t1", url: "https://news.ycombinator.com", title: "Hacker News", pinned: true)
    ]

    let html = OneClickMigrator.generateNetscapeHTML(
        snapshot: snapshot,
        folderTitle: "Migrated from Zen",
        options: TransferOptions(bookmarks: true, tabs: true, history: false, groups: true)
    )

    #expect(html.contains("<DT><H3>Migrated from Zen</H3>"))
    #expect(html.contains("<DT><H3>Development</H3>"))
    #expect(html.contains("<DT><H3>Tools</H3>"))
    #expect(html.contains("<DT><A HREF=\"https://github.com\">GitHub</A>"))
    #expect(html.contains("<DT><A HREF=\"https://swift.org\">Swift</A>"))
    #expect(html.contains("📌 Hacker News"))
}

@Test func testOneClickRejectsSameProfileMigration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sameProfile = root.appendingPathComponent("SameProfile")
    try FileManager.default.createDirectory(at: sameProfile, withIntermediateDirectories: true)

    do {
        _ = try await OneClickMigrator.migrate(
            sourceBrowser: .chrome,
            sourceProfile: sameProfile,
            destinationBrowser: .chrome,
            destinationProfile: sameProfile,
            closeDestinationIfRunning: false
        )
        Issue.record("Expected failure when source and destination are the exact same folder")
    } catch {
        #expect(error.localizedDescription.contains("same folder"))
    }
}

@Test func testOneClickCLIShowsHelp() async throws {
    let help = try await OneClickCLI.run(arguments: ["--help"])
    #expect(help.contains("bridge-migrate"))
    #expect(help.contains("--list-receipts"))
    #expect(help.contains("--rollback"))
    #expect(help.contains("--dry-run"))

    let shortHelp = try await OneClickCLI.run(arguments: ["-h"])
    #expect(shortHelp.contains("Usage:"))
}

@Test func testOneClickCLIDryRun() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("SourceProfile")
    let dest = root.appendingPathComponent("DestProfile")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    let bookmarks: [String: Any] = [
        "roots": ["bookmark_bar": ["children": [["name": "Apple", "type": "url", "url": "https://apple.com"]], "type": "folder"]],
        "version": 1
    ]
    let data = try JSONSerialization.data(withJSONObject: bookmarks)
    try data.write(to: source.appendingPathComponent("Bookmarks"))

    let output = try await OneClickCLI.run(arguments: [
        "chrome", source.path,
        "brave", dest.path,
        "--dry-run"
    ])

    #expect(output.contains("[DRY RUN] 1-Click Migration Simulation"))
    #expect(output.contains("Source:               Chrome"))
    #expect(output.contains("Destination:          Brave"))
    #expect(output.contains("• Bookmarks:        1"))
    #expect(output.contains("No files were modified"))

    // Verify destination was NOT modified
    #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Bookmarks").path))
}

@Test func testOneClickCLIFullMigrationAndRollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let receiptOverride = root.appendingPathComponent("Receipts")
    OneClickMigrator.receiptDirectoryOverride = receiptOverride
    defer {
        OneClickMigrator.receiptDirectoryOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    let source = root.appendingPathComponent("SourceProfile")
    let dest = root.appendingPathComponent("DestProfile")
    let backupDir = root.appendingPathComponent("CLIBackups")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    let bookmarks: [String: Any] = [
        "roots": ["bookmark_bar": ["children": [["name": "Vercel", "type": "url", "url": "https://vercel.com"]], "type": "folder"]],
        "version": 1
    ]
    let data = try JSONSerialization.data(withJSONObject: bookmarks)
    try data.write(to: source.appendingPathComponent("Bookmarks"))

    // Execute migration via CLI
    let migrationOutput = try await OneClickCLI.run(arguments: [
        "chrome", source.path,
        "brave", dest.path,
        "--backup-dir", backupDir.path,
        "--no-close",
        "--no-open"
    ])

    #expect(migrationOutput.contains("⚡ 1-Click Browser Migration Complete!"))
    #expect(migrationOutput.contains("Chrome → Brave"))
    #expect(migrationOutput.contains("• Bookmarks:       1"))

    // Extract Receipt ID
    let lines = migrationOutput.components(separatedBy: "\n")
    guard let receiptLine = lines.first(where: { $0.contains("Receipt ID:") }),
          let receiptId = receiptLine.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) else {
        Issue.record("Could not extract receipt ID from CLI output")
        return
    }

    #expect(!receiptId.isEmpty)

    // Test list receipts
    let listOutput = try await OneClickCLI.run(arguments: ["--list-receipts"])
    #expect(listOutput.contains(receiptId))

    // Rollback via CLI
    let rollbackOutput = try await OneClickCLI.run(arguments: ["--rollback", receiptId, "--no-close"])
    #expect(rollbackOutput.contains("Rollback Successful"))
    #expect(rollbackOutput.contains(receiptId))
    #expect(rollbackOutput.contains("rolled-back"))
}

@Test func testOneClickCLIRejectsInvalidArguments() async throws {
    do {
        _ = try await OneClickCLI.run(arguments: ["nonexistentbrowser", "chrome"])
        Issue.record("Expected unknown browser error")
    } catch {
        #expect(error.localizedDescription.contains("Unknown source browser"))
    }

    do {
        _ = try await OneClickCLI.run(arguments: ["--rollback"])
        Issue.record("Expected missing receipt ID error")
    } catch {
        #expect(error.localizedDescription.contains("Missing receipt ID"))
    }
}

@Test func testOneClickMigrationFromFirefoxPlacesToChromium() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("FirefoxSource")
    let destProfile = root.appendingPathComponent("ChromeDest")
    try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    // Set up source Firefox places.sqlite with parent ID 1 hierarchy
    var db: OpaquePointer?
    #expect(sqlite3_open(sourceProfile.appendingPathComponent("places.sqlite").path, &db) == SQLITE_OK)
    let schema = """
    CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, rev_host TEXT, visit_count INTEGER, hidden INTEGER, typed INTEGER, frecency INTEGER, last_visit_date INTEGER);
    CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT);
    INSERT INTO moz_places (id, url, title, last_visit_date) VALUES (1, 'https://getfirefox.com', 'Mozilla Firefox', 1700000000);
    INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (1, 2, NULL, 0, 0, 'placesRoot', 'rootGuid____');
    INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (2, 2, NULL, 1, 0, 'Bookmarks Menu', 'menuGuid____');
    INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (3, 2, NULL, 1, 1, 'Bookmarks Toolbar', 'toolbarGuid_');
    INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (4, 1, 1, 3, 0, 'Mozilla Firefox', 'itemGuid____');
    """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    // Set up destination Chromium with an existing Bookmarks file
    let destBookmarks: [String: Any] = [
        "roots": [
            "bookmark_bar": [
                "children": [
                    ["name": "Existing Bookmark", "type": "url", "url": "https://chromium.org"]
                ],
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let destData = try JSONSerialization.data(withJSONObject: destBookmarks)
    try destData.write(to: destProfile.appendingPathComponent("Bookmarks"))

    let backupDir = root.appendingPathComponent("Backups")

    // Run One-Click Migration from Firefox to Chrome
    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .firefox,
        sourceProfile: sourceProfile,
        destinationBrowser: .chrome,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: false, history: false, groups: false),
        backupDirectory: backupDir,
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.bookmarksCount >= 1)

    // Inspect destination Chromium Bookmarks file
    let modifiedDestData = try Data(contentsOf: destProfile.appendingPathComponent("Bookmarks"))
    let modifiedJson = try #require(try JSONSerialization.jsonObject(with: modifiedDestData) as? [String: Any])
    let roots = try #require(modifiedJson["roots"] as? [String: Any])
    let bar = try #require(roots["bookmark_bar"] as? [String: Any])
    let children = try #require(bar["children"] as? [[String: Any]])

    let migratedFolder = try #require(children.first { ($0["name"] as? String) == "Migrated from Firefox" })
    let folderChildren = try #require(migratedFolder["children"] as? [[String: Any]])

    func findBookmarkNamed(_ name: String, in items: [[String: Any]]) -> [String: Any]? {
        for item in items {
            if (item["name"] as? String) == name { return item }
            if let nested = item["children"] as? [[String: Any]], let found = findBookmarkNamed(name, in: nested) {
                return found
            }
        }
        return nil
    }

    let foundItem = findBookmarkNamed("Mozilla Firefox", in: folderChildren)
    #expect(foundItem != nil)
    #expect((foundItem?["url"] as? String) == "https://getfirefox.com")
}

@Test func testOneClickMigrationPlacesWithGuidSchema() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("ChromeSource")
    let destProfile = root.appendingPathComponent("FirefoxDest")
    try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    // Setup source Chromium bookmarks
    let sourceBookmarks: [String: Any] = [
        "roots": [
            "bookmark_bar": [
                "children": [
                    ["name": "OpenAI", "type": "url", "url": "https://openai.com"],
                    ["name": "Anthropic", "type": "url", "url": "https://anthropic.com"]
                ],
                "type": "folder"
            ]
        ],
        "version": 1
    ]
    let sourceData = try JSONSerialization.data(withJSONObject: sourceBookmarks)
    try sourceData.write(to: sourceProfile.appendingPathComponent("Bookmarks"))

    // Setup destination Firefox places.sqlite with NOT NULL guid column
    var db: OpaquePointer?
    #expect(sqlite3_open(destProfile.appendingPathComponent("places.sqlite").path, &db) == SQLITE_OK)
    let schema = """
    CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, rev_host TEXT, visit_count INTEGER, hidden INTEGER, typed INTEGER, frecency INTEGER, last_visit_date INTEGER);
    CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT NOT NULL UNIQUE);
    INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (1, 2, NULL, 0, 0, 'root', 'root________');
    INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (3, 2, NULL, 1, 0, 'toolbar', 'toolbar_____');
    """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let backupDir = root.appendingPathComponent("Backups")

    // Run One-Click Migration to Firefox
    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .chrome,
        sourceProfile: sourceProfile,
        destinationBrowser: .firefox,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: false, history: false, groups: false),
        backupDirectory: backupDir,
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.bookmarksCount == 2)

    // Query destination places.sqlite to verify GUIDs were populated and unique
    var readDb: OpaquePointer?
    #expect(sqlite3_open(destProfile.appendingPathComponent("places.sqlite").path, &readDb) == SQLITE_OK)
    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(readDb, "SELECT title, guid FROM moz_bookmarks WHERE title IN ('OpenAI', 'Anthropic')", -1, &stmt, nil) == SQLITE_OK)

    var foundTitles: [String] = []
    var foundGuids: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let t = sqlite3_column_text(stmt, 0), let g = sqlite3_column_text(stmt, 1) {
            foundTitles.append(String(cString: t))
            foundGuids.append(String(cString: g))
        }
    }
    sqlite3_finalize(stmt)
    sqlite3_close(readDb)

    #expect(foundTitles.contains("OpenAI"))
    #expect(foundTitles.contains("Anthropic"))
    #expect(foundGuids.count == 2)
    for guid in foundGuids {
        #expect(guid.count == 12)
    }
    #expect(foundGuids[0] != foundGuids[1])
}

@Test func testOneClickRollbackHandlesWALFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("ChromeSource")
    let destProfile = root.appendingPathComponent("FirefoxDest")
    try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    let sourceBookmarks: [String: Any] = [
        "roots": ["bookmark_bar": ["children": [["name": "Rust", "type": "url", "url": "https://rust-lang.org"]], "type": "folder"]],
        "version": 1
    ]
    try JSONSerialization.data(withJSONObject: sourceBookmarks).write(to: sourceProfile.appendingPathComponent("Bookmarks"))

    let origPlaces = "ORIGINAL_PLACES_CONTENT".data(using: .utf8)!
    let origWal = "ORIGINAL_WAL_CONTENT".data(using: .utf8)!
    let origShm = "ORIGINAL_SHM_CONTENT".data(using: .utf8)!

    try origPlaces.write(to: destProfile.appendingPathComponent("places.sqlite"))
    try origWal.write(to: destProfile.appendingPathComponent("places.sqlite-wal"))
    try origShm.write(to: destProfile.appendingPathComponent("places.sqlite-shm"))

    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .chrome,
        sourceProfile: sourceProfile,
        destinationBrowser: .firefox,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: false, history: false, groups: false),
        backupDirectory: root.appendingPathComponent("Backups"),
        closeDestinationIfRunning: false,
        openDestination: false
    )

    // Simulate destination WAL being overwritten during browser execution
    try "MODIFIED_WAL_CONTENT".data(using: .utf8)!.write(to: destProfile.appendingPathComponent("places.sqlite-wal"))

    // Execute rollback
    try await OneClickMigrator.rollback(receipt: receipt, closeDestinationIfRunning: false)

    // Verify WAL and SHM restored to original
    let restoredWal = try Data(contentsOf: destProfile.appendingPathComponent("places.sqlite-wal"))
    #expect(restoredWal == origWal)
    let restoredShm = try Data(contentsOf: destProfile.appendingPathComponent("places.sqlite-shm"))
    #expect(restoredShm == origShm)
    #expect(!FileManager.default.fileExists(atPath: destProfile.appendingPathComponent("Bookmarks.html").path))
}

@Test func testOneClickMigratesFoldersWithTabsAndEssentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("ZenSource")
    let destProfile = root.appendingPathComponent("DiaDest")
    try FileManager.default.createDirectory(at: sourceProfile.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destProfile, withIntermediateDirectories: true)

    // Build Zen session with Space, Nested Folders, Essentials, Pinned tabs, and Folder tabs
    let zenSessionJSON = """
    {
      "spaces": [
        { "uuid": "work-space", "name": "Work Space" }
      ],
      "folders": [
        { "id": "f-projects", "name": "Projects", "workspaceId": "work-space" },
        { "id": "f-research", "name": "Deep Research", "parentId": "f-projects", "workspaceId": "work-space" }
      ],
      "tabs": [
        {
          "zenSyncId": "t-essential",
          "zenEssential": true,
          "entries": [{ "url": "https://mail.google.com", "title": "Work Mail" }]
        },
        {
          "zenSyncId": "t-pinned",
          "pinned": true,
          "zenWorkspace": "work-space",
          "entries": [{ "url": "https://calendar.google.com", "title": "Team Calendar" }]
        },
        {
          "zenSyncId": "t-research",
          "groupId": "f-research",
          "zenWorkspace": "work-space",
          "entries": [{ "url": "https://arxiv.org/abs/2301.00001", "title": "Paper on AI" }]
        },
        {
          "zenSyncId": "t-open",
          "zenWorkspace": "work-space",
          "entries": [{ "url": "https://news.ycombinator.com", "title": "Tech News" }]
        }
      ]
    }
    """
    try zenSessionJSON.write(
        to: sourceProfile.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"),
        atomically: true,
        encoding: .utf8
    )

    // Run One-Click Migration
    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .zen,
        sourceProfile: sourceProfile,
        destinationBrowser: .dia,
        destinationProfile: destProfile,
        options: TransferOptions(bookmarks: true, tabs: true, history: false, groups: true),
        backupDirectory: root.appendingPathComponent("Backups"),
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.tabsCount == 4)
    #expect(receipt.groupsCount >= 3) // 1 space + 2 folders

    // Parse destination Bookmarks file
    let bookmarksFile = destProfile.appendingPathComponent("Bookmarks")
    #expect(FileManager.default.fileExists(atPath: bookmarksFile.path))
    let data = try Data(contentsOf: bookmarksFile)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let roots = try #require(json["roots"] as? [String: Any])
    let bar = try #require(roots["bookmark_bar"] as? [String: Any])
    let barChildren = try #require(bar["children"] as? [[String: Any]])

    let migFolder = try #require(barChildren.first { ($0["name"] as? String) == "Migrated from Zen" })
    let topFolders = try #require(migFolder["children"] as? [[String: Any]])

    // 1. Verify Essentials folder is top-level with essential tab
    let essFolder = try #require(topFolders.first { ($0["name"] as? String) == "⭐ Essentials" })
    let essItems = try #require(essFolder["children"] as? [[String: Any]])
    #expect(essItems.contains { ($0["name"] as? String) == "Work Mail" && ($0["url"] as? String) == "https://mail.google.com" })

    // 2. Verify Space folder exists
    let spaceFolder = try #require(topFolders.first { ($0["name"] as? String) == "Work Space" })
    let spaceItems = try #require(spaceFolder["children"] as? [[String: Any]])

    // 3. Verify Pinned Tabs inside Space
    let spacePins = try #require(spaceItems.first { ($0["name"] as? String) == "📌 Pinned Tabs" })
    let pinTabs = try #require(spacePins["children"] as? [[String: Any]])
    #expect(pinTabs.contains { ($0["name"] as? String) == "Team Calendar" })

    // 4. Verify Projects folder contains Deep Research subfolder
    let projectsFolder = try #require(spaceItems.first { ($0["name"] as? String) == "Projects" })
    let projectsChildren = try #require(projectsFolder["children"] as? [[String: Any]])

    let researchFolder = try #require(projectsChildren.first { ($0["name"] as? String) == "Deep Research" })
    let researchChildren = try #require(researchFolder["children"] as? [[String: Any]])

    // 5. Verify the tab "Paper on AI" is inside Deep Research!
    #expect(researchChildren.contains {
        ($0["name"] as? String) == "Paper on AI" && ($0["url"] as? String) == "https://arxiv.org/abs/2301.00001"
    })

    // 6. Verify Open Tabs inside Space
    let openFolder = try #require(spaceItems.first { ($0["name"] as? String) == "Open Tabs" })
    let openTabs = try #require(openFolder["children"] as? [[String: Any]])
    #expect(openTabs.contains { ($0["name"] as? String) == "Tech News" })

    // 7. Verify Netscape HTML generation also preserves this hierarchy
    let snapshot = try BrowserReader.read(profile: sourceProfile, browser: .zen)
    let html = OneClickMigrator.generateNetscapeHTML(
        snapshot: snapshot,
        folderTitle: "Migrated from Zen",
        options: TransferOptions(bookmarks: true, tabs: true, history: false, groups: true)
    )
    #expect(html.contains("<DT><H3>⭐ Essentials</H3>"))
    #expect(html.contains("<DT><A HREF=\"https://mail.google.com\">Work Mail</A>"))
    #expect(html.contains("<DT><H3>Work Space</H3>"))
    #expect(html.contains("<DT><H3>📌 Pinned Tabs</H3>"))
    #expect(html.contains("<DT><H3>Projects</H3>"))
    #expect(html.contains("<DT><H3>Deep Research</H3>"))
    #expect(html.contains("<DT><A HREF=\"https://arxiv.org/abs/2301.00001\">Paper on AI</A>"))
}

@Test func testOneClickMigratesMultiSpaceDirectToDiaAndRollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("ZenSource")
    let diaUserData = root.appendingPathComponent("DiaUserData")
    try FileManager.default.createDirectory(at: sourceProfile.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: diaUserData, withIntermediateDirectories: true)

    // Pre-create Dia's Local State with an existing profile (e.g. Profile 4 for "higher education")
    let initialLocalState: [String: Any] = [
        "profile": [
            "info_cache": [
                "Profile 4": [
                    "name": "higher education",
                    "is_using_default_name": false
                ]
            ],
            "profiles_order": ["Profile 4"],
            "last_used": "Profile 4"
        ]
    ]
    let lsData = try JSONSerialization.data(withJSONObject: initialLocalState, options: [.prettyPrinted])
    try lsData.write(to: diaUserData.appendingPathComponent("Local State"))

    // Build Zen session with 3 spaces and essentials
    let zenSessionJSON = """
    {
      "spaces": [
        { "uuid": "sp-personal", "name": "Personal" },
        { "uuid": "sp-work", "name": "UI/UX" },
        { "uuid": "sp-edu", "name": "higher education" }
      ],
      "folders": [
        { "id": "f-design", "name": "Design Systems", "workspaceId": "sp-work" }
      ],
      "tabs": [
        {
          "zenSyncId": "t-ess1",
          "zenEssential": true,
          "entries": [{ "url": "https://gmail.com", "title": "My Mail" }]
        },
        {
          "zenSyncId": "t-pers1",
          "zenWorkspace": "sp-personal",
          "entries": [{ "url": "https://reddit.com", "title": "Reddit" }]
        },
        {
          "zenSyncId": "t-work1",
          "groupId": "f-design",
          "zenWorkspace": "sp-work",
          "entries": [{ "url": "https://figma.com", "title": "Figma" }]
        },
        {
          "zenSyncId": "t-edu1",
          "zenWorkspace": "sp-edu",
          "pinned": true,
          "entries": [{ "url": "https://mit.edu", "title": "MIT" }]
        }
      ]
    }
    """
    try zenSessionJSON.write(
        to: sourceProfile.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"),
        atomically: true,
        encoding: .utf8
    )

    // Run Migration targeting Dia's User Data directory
    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .zen,
        sourceProfile: sourceProfile,
        destinationBrowser: .dia,
        destinationProfile: diaUserData,
        options: TransferOptions(bookmarks: true, tabs: true, history: false, groups: true),
        backupDirectory: root.appendingPathComponent("Backups"),
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")
    #expect(receipt.tabsCount == 4)
    #expect(receipt.groupsCount >= 3)

    // 1. Verify Local State has all 3 spaces registered as Dia profiles
    let updatedLSData = try Data(contentsOf: diaUserData.appendingPathComponent("Local State"))
    let updatedLS = try #require(try JSONSerialization.jsonObject(with: updatedLSData) as? [String: Any])
    let profileDict = try #require(updatedLS["profile"] as? [String: Any])
    let infoCache = try #require(profileDict["info_cache"] as? [String: Any])

    var names = Set<String>()
    for (_, v) in infoCache {
        if let dict = v as? [String: Any], let name = dict["name"] as? String {
            names.insert(name)
        }
    }
    #expect(names.contains("Personal"))
    #expect(names.contains("UI/UX"))
    #expect(names.contains("higher education"))

    // 2. Verify "higher education" reused Profile 4
    let p4 = try #require(infoCache["Profile 4"] as? [String: Any])
    #expect((p4["name"] as? String) == "higher education")

    // 3. Verify Profile 4's Bookmarks has both the essential and its pinned tab
    let p4BookmarksFile = diaUserData.appendingPathComponent("Profile 4/Bookmarks")
    #expect(FileManager.default.fileExists(atPath: p4BookmarksFile.path))
    let p4Data = try Data(contentsOf: p4BookmarksFile)
    let p4JSON = try #require(try JSONSerialization.jsonObject(with: p4Data) as? [String: Any])
    let p4Roots = try #require(p4JSON["roots"] as? [String: Any])
    let p4Bar = try #require(p4Roots["bookmark_bar"] as? [String: Any])
    let p4Children = try #require(p4Bar["children"] as? [[String: Any]])

    // Essential tab is in Profile 4's bookmarks
    #expect(p4Children.contains { ($0["url"] as? String) == "https://gmail.com" })
    // Pinned tab "MIT" is in Profile 4's bookmarks
    let p4Pins = try #require(p4Children.first { ($0["name"] as? String) == "📌 Pinned Tabs" })
    let p4PinChildren = try #require(p4Pins["children"] as? [[String: Any]])
    #expect(p4PinChildren.contains { ($0["url"] as? String) == "https://mit.edu" })

    // 4. Test rollback restores original Local State
    try await OneClickMigrator.rollback(receipt: receipt, closeDestinationIfRunning: false)
    let rolledLSData = try Data(contentsOf: diaUserData.appendingPathComponent("Local State"))
    let rolledLS = try #require(try JSONSerialization.jsonObject(with: rolledLSData) as? [String: Any])
    let rolledProfDict = try #require(rolledLS["profile"] as? [String: Any])
    let rolledInfo = try #require(rolledProfDict["info_cache"] as? [String: Any])
    #expect(rolledInfo.count == 1)
    #expect((rolledInfo["Profile 4"] as? [String: Any])?["name"] as? String == "higher education")
}

@Test func testOneClickDiaPreservesEssentialsInEverySpace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceProfile = root.appendingPathComponent("ZenSource")
    let diaUserData = root.appendingPathComponent("DiaUserData")
    try FileManager.default.createDirectory(at: sourceProfile.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: diaUserData, withIntermediateDirectories: true)

    // Pre-create Dia's Local State with an active starter Profile 9 named "Profile"
    let initialLocalState: [String: Any] = [
        "profile": [
            "info_cache": [
                "Profile 9": [
                    "name": "Profile",
                    "is_using_default_name": false
                ]
            ],
            "profiles_order": ["Profile 9"],
            "last_used": "Profile 9"
        ]
    ]
    let lsData = try JSONSerialization.data(withJSONObject: initialLocalState, options: [.prettyPrinted])
    try lsData.write(to: diaUserData.appendingPathComponent("Local State"))

    // Build Zen session with 3 spaces and 3 essentials
    let zenSessionJSON = """
    {
      "spaces": [
        { "uuid": "sp-pers", "name": "Personal" },
        { "uuid": "sp-work", "name": "Work" },
        { "uuid": "sp-ent", "name": "Entertainment" }
      ],
      "tabs": [
        {
          "zenSyncId": "ess-1",
          "zenEssential": true,
          "entries": [{ "url": "https://mail.google.com", "title": "Gmail" }]
        },
        {
          "zenSyncId": "ess-2",
          "zenEssential": true,
          "entries": [{ "url": "https://youtube.com", "title": "YouTube" }]
        },
        {
          "zenSyncId": "ess-3",
          "zenEssential": true,
          "entries": [{ "url": "https://chatgpt.com", "title": "ChatGPT" }]
        },
        {
          "zenSyncId": "tab-pers",
          "zenWorkspace": "sp-pers",
          "entries": [{ "url": "https://apple.com", "title": "Apple" }]
        },
        {
          "zenSyncId": "tab-work",
          "zenWorkspace": "sp-work",
          "pinned": true,
          "entries": [{ "url": "https://linear.app", "title": "Linear" }]
        },
        {
          "zenSyncId": "tab-ent",
          "zenWorkspace": "sp-ent",
          "entries": [{ "url": "https://netflix.com", "title": "Netflix" }]
        }
      ]
    }
    """
    try zenSessionJSON.write(
        to: sourceProfile.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"),
        atomically: true,
        encoding: .utf8
    )

    // Run Migration
    let receipt = try await OneClickMigrator.migrate(
        sourceBrowser: .zen,
        sourceProfile: sourceProfile,
        destinationBrowser: .dia,
        destinationProfile: diaUserData,
        options: TransferOptions(bookmarks: true, tabs: true, history: false, groups: true),
        backupDirectory: root.appendingPathComponent("Backups"),
        closeDestinationIfRunning: false,
        openDestination: false
    )

    #expect(receipt.status == "complete")

    // Verify Profile 9 was reused for Personal
    let updatedLSData = try Data(contentsOf: diaUserData.appendingPathComponent("Local State"))
    let updatedLS = try #require(try JSONSerialization.jsonObject(with: updatedLSData) as? [String: Any])
    let profileDict = try #require(updatedLS["profile"] as? [String: Any])
    let infoCache = try #require(profileDict["info_cache"] as? [String: Any])
    let p9 = try #require(infoCache["Profile 9"] as? [String: Any])
    #expect((p9["name"] as? String) == "Personal")

    // Verify ALL profile directories have ALL 3 Essentials present identically
    let expectedProfiles = ["Profile 9", "Profile 1", "Profile 2"]
    for pDir in expectedProfiles {
        let bmFile = diaUserData.appendingPathComponent("\(pDir)/Bookmarks")
        #expect(FileManager.default.fileExists(atPath: bmFile.path))
        let bmData = try Data(contentsOf: bmFile)
        let bmJson = try #require(try JSONSerialization.jsonObject(with: bmData) as? [String: Any])
        let roots = try #require(bmJson["roots"] as? [String: Any])
        let bar = try #require(roots["bookmark_bar"] as? [String: Any])
        let children = try #require(bar["children"] as? [[String: Any]])

        // 1. Direct bookmark buttons on Bookmarks bar
        #expect(children.contains { ($0["url"] as? String) == "https://mail.google.com" })
        #expect(children.contains { ($0["url"] as? String) == "https://youtube.com" })
        #expect(children.contains { ($0["url"] as? String) == "https://chatgpt.com" })

        // 2. ⭐ Essentials folder contains all 3 essentials
        let essFolder = try #require(children.first { ($0["name"] as? String) == "⭐ Essentials" })
        let essChildren = try #require(essFolder["children"] as? [[String: Any]])
        #expect(essChildren.count == 3)
        #expect(essChildren.contains { ($0["url"] as? String) == "https://mail.google.com" })
        #expect(essChildren.contains { ($0["url"] as? String) == "https://youtube.com" })
        #expect(essChildren.contains { ($0["url"] as? String) == "https://chatgpt.com" })

        // 3. ⭐ Pinned Favorites folder contains all 3 essentials
        let favFolder = try #require(children.first { ($0["name"] as? String) == "⭐ Pinned Favorites" })
        let favChildren = try #require(favFolder["children"] as? [[String: Any]])
        #expect(favChildren.count == 3)
    }

    // Rollback cleans up
    try await OneClickMigrator.rollback(receipt: receipt, closeDestinationIfRunning: false)
}




