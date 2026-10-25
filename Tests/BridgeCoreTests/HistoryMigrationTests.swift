import Foundation
import Testing
import CSQLite
@testable import BridgeCore

struct HistoryMigrationTests {
    private func countRows(in dbURL: URL, table: String) throws -> Int {
        var count = 0
        try PlacesReader.rows(dbURL, sql: "SELECT count(*) FROM \(table);") { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    @Test func testChromiumHistoryDirectWriteAndRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let historyFile = root.appendingPathComponent("History")
        let items: [HistoryItem] = [
            HistoryItem(url: "https://news.ycombinator.com", title: "Hacker News", time: 1700000000000),
            HistoryItem(url: "https://github.com/trending", title: "GitHub Trending", time: 1700000500000),
            HistoryItem(url: "place:sort=8", title: "Ignored Internal", time: 1700000600000) // Non-http should be skipped
        ]

        let written = try OneClickMigrator.writeChromiumHistory(to: historyFile, items: items)
        #expect(written == 2)

        // Verify SQLite tables directly
        let count = try countRows(in: historyFile, table: "urls")
        #expect(count == 2)

        let visitCount = try countRows(in: historyFile, table: "visits")
        #expect(visitCount == 2)

        // Verify ChromiumReader reads the written history accurately
        let snapshot = try BrowserReader.read(profile: root, browser: .chrome)
        #expect(snapshot.history.count == 2)
        #expect(snapshot.history.contains { $0.url == "https://news.ycombinator.com" && $0.time == 1700000000000 })
        #expect(snapshot.history.contains { $0.url == "https://github.com/trending" && $0.time == 1700000500000 })
    }

    @Test func testChromiumHistoryLockTolerance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let historyFile = root.appendingPathComponent("History")
        let items: [HistoryItem] = [
            HistoryItem(url: "https://apple.com", title: "Apple", time: 1700000000000)
        ]
        _ = try OneClickMigrator.writeChromiumHistory(to: historyFile, items: items)

        // Hold an exclusive lock on the History database
        var lockDB: OpaquePointer?
        #expect(sqlite3_open(historyFile.path, &lockDB) == SQLITE_OK)
        #expect(sqlite3_exec(lockDB, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)

        // ChromiumReader should use withSafeReadCopy and successfully read without failing
        let snapshot = try BrowserReader.read(profile: root, browser: .dia)
        #expect(snapshot.history.count == 1)
        #expect(snapshot.history.first?.url == "https://apple.com")

        sqlite3_exec(lockDB, "ROLLBACK;", nil, nil, nil)
        sqlite3_close(lockDB)
    }

    @Test func testFirefoxHistoryDirectWriteAndRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let placesFile = root.appendingPathComponent("places.sqlite")
        let items: [HistoryItem] = [
            HistoryItem(url: "https://mozilla.org", title: "Mozilla", time: 1700000000000),
            HistoryItem(url: "https://rust-lang.org", title: "Rust", time: 1700000100000)
        ]

        let written = try OneClickMigrator.writeFirefoxHistory(to: placesFile, items: items)
        #expect(written == 2)

        let snapshot = try BrowserReader.read(profile: root, browser: .firefox)
        #expect(snapshot.history.count == 2)
        #expect(snapshot.history.contains { $0.url == "https://mozilla.org" && $0.time == 1700000000000 })
        #expect(snapshot.history.contains { $0.url == "https://rust-lang.org" && $0.time == 1700000100000 })
    }

    @Test func testOneClickZenToDiaFullHistoryMigrationAndRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let zenProfile = root.appendingPathComponent("ZenProfile")
        let diaUserData = root.appendingPathComponent("DiaUserData")
        try FileManager.default.createDirectory(at: zenProfile.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: diaUserData.appendingPathComponent("Profile 9"), withIntermediateDirectories: true)

        // 1. Create Zen session with 1 space and 1 essential
        let zenSessionJSON = """
        {
          "spaces": [{ "uuid": "sp-work", "name": "Work" }],
          "tabs": [{
            "zenSyncId": "t-ess",
            "zenEssential": true,
            "entries": [{ "url": "https://mail.google.com", "title": "Mail" }]
          }]
        }
        """
        try zenSessionJSON.write(to: zenProfile.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"), atomically: true, encoding: .utf8)

        // 2. Create Zen places.sqlite with history
        var zenDB: OpaquePointer?
        #expect(sqlite3_open(zenProfile.appendingPathComponent("places.sqlite").path, &zenDB) == SQLITE_OK)
        let initZen = """
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER);
        INSERT INTO moz_places VALUES(1, 'https://arc.net', 'The Browser Company', 1700000000000000);
        INSERT INTO moz_places VALUES(2, 'https://dia.com', 'Dia Browser', 1700000200000000);
        """
        #expect(sqlite3_exec(zenDB, initZen, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(zenDB)

        // 3. Create Dia Local State with Profile 9
        let lsData = try JSONSerialization.data(withJSONObject: [
            "profile": [
                "info_cache": ["Profile 9": ["name": "Profile"]],
                "profiles_order": ["Profile 9"],
                "last_used": "Profile 9"
            ]
        ])
        try lsData.write(to: diaUserData.appendingPathComponent("Local State"))

        // Pre-existing history in Profile 9
        let preExistingHistory = diaUserData.appendingPathComponent("Profile 9/History")
        _ = try OneClickMigrator.writeChromiumHistory(to: preExistingHistory, items: [
            HistoryItem(url: "https://initial-site.org", title: "Initial", time: 1690000000000)
        ])

        // 4. Run Migration with default options (history included by default)
        let receipt = try await OneClickMigrator.migrate(
            sourceBrowser: .zen,
            sourceProfile: zenProfile,
            destinationBrowser: .dia,
            destinationProfile: diaUserData,
            options: TransferOptions(bookmarks: true, tabs: true, history: true, groups: true),
            backupDirectory: root.appendingPathComponent("Backups"),
            closeDestinationIfRunning: false,
            openDestination: false
        )

        #expect(receipt.status == "complete")
        #expect(receipt.historyCount >= 2)

        // 5. Inspect Profile 9 History file
        let rowCount = try countRows(in: preExistingHistory, table: "urls")
        #expect(rowCount >= 3) // Initial + 2 migrated

        // 6. Test Rollback restores original pre-existing History
        try await OneClickMigrator.rollback(receipt: receipt, closeDestinationIfRunning: false)

        let restoredCount = try countRows(in: preExistingHistory, table: "urls")
        #expect(restoredCount == 1) // Only initial site restored!
    }

    @Test func testOneClickCLIHistoryFlags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        let dest = root.appendingPathComponent("Dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let items: [HistoryItem] = [
            HistoryItem(url: "https://wikipedia.org", title: "Wikipedia", time: 1700000000000)
        ]
        _ = try OneClickMigrator.writeChromiumHistory(to: source.appendingPathComponent("History"), items: items)

        // Default CLI dry run should show History: 1
        let defaultOutput = try await OneClickCLI.run(arguments: [
            "chrome", source.path,
            "brave", dest.path,
            "--dry-run"
        ])
        #expect(defaultOutput.contains("• History:          1"))

        // CLI dry run with --no-history should show History: 0
        let noHistoryOutput = try await OneClickCLI.run(arguments: [
            "chrome", source.path,
            "brave", dest.path,
            "--no-history",
            "--dry-run"
        ])
        #expect(noHistoryOutput.contains("• History:          0"))
    }

    @Test func testStringMemorySafetyAndSpecialCharacters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chromHist = root.appendingPathComponent("Chromium_History")
        let ffPlaces = root.appendingPathComponent("Firefox_places.sqlite")

        let items: [HistoryItem] = [
            HistoryItem(url: "https://example.com/search?q=🚀+migration&lang=日本語", title: "🚀 Quick Transfer 日本語", time: 1700000000000, visitCount: 3, typedCount: 1),
            HistoryItem(url: "https://café.fr/menu?item=croissant&price=€2.50", title: "Café Français 🥐", time: 1700000100000, visitCount: 5, typedCount: 0)
        ]

        let cWritten = try OneClickMigrator.writeChromiumHistory(to: chromHist, items: items)
        #expect(cWritten == 2)

        let fWritten = try OneClickMigrator.writeFirefoxHistory(to: ffPlaces, items: items)
        #expect(fWritten == 2)

        // Read and verify Chromium items preserve exact Unicode strings
        var cUrls: [String] = [], cTitles: [String] = []
        try PlacesReader.rows(chromHist, sql: "SELECT url, title, visit_count, typed_count FROM urls ORDER BY id ASC") { q in
            if let u = PlacesReader.string(q, 0), let t = PlacesReader.string(q, 1) {
                cUrls.append(u)
                cTitles.append(t)
            }
        }
        #expect(cUrls.contains("https://example.com/search?q=🚀+migration&lang=日本語"))
        #expect(cTitles.contains("🚀 Quick Transfer 日本語"))
        #expect(cUrls.contains("https://café.fr/menu?item=croissant&price=€2.50"))
        #expect(cTitles.contains("Café Français 🥐"))

        // Read and verify Firefox items preserve exact Unicode strings
        var fUrls: [String] = [], fTitles: [String] = []
        try PlacesReader.rows(ffPlaces, sql: "SELECT url, title FROM moz_places ORDER BY id ASC") { q in
            if let u = PlacesReader.string(q, 0), let t = PlacesReader.string(q, 1) {
                fUrls.append(u)
                fTitles.append(t)
            }
        }
        #expect(fUrls.contains("https://example.com/search?q=🚀+migration&lang=日本語"))
        #expect(fTitles.contains("🚀 Quick Transfer 日本語"))
    }

    @Test func testFirefoxRevHostAndFrecencyCalculation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let placesFile = root.appendingPathComponent("places.sqlite")
        let items: [HistoryItem] = [
            HistoryItem(url: "https://www.google.com/search?q=zen", title: "Google Search", time: 1700000000000, visitCount: 4, typedCount: 2),
            HistoryItem(url: "https://news.ycombinator.com/news", title: "Hacker News", time: 1700000200000, visitCount: 1, typedCount: 0)
        ]

        let written = try OneClickMigrator.writeFirefoxHistory(to: placesFile, items: items)
        #expect(written == 2)

        // Verify rev_host calculation
        var revHosts: [String: String] = [:]
        var frecencies: [String: Int] = [:]
        try PlacesReader.rows(placesFile, sql: "SELECT url, rev_host, frecency FROM moz_places") { q in
            if let u = PlacesReader.string(q, 0), let rh = PlacesReader.string(q, 1) {
                revHosts[u] = rh
                frecencies[u] = Int(sqlite3_column_int(q, 2))
            }
        }

        #expect(revHosts["https://www.google.com/search?q=zen"] == "moc.elgoog.www.")
        #expect(revHosts["https://news.ycombinator.com/news"] == "moc.rotanibmocy.swen.")
        #expect((frecencies["https://www.google.com/search?q=zen"] ?? 0) >= 4000)
    }

    @Test func testZeroLockReadingOnLiveActiveBrowser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbFile = root.appendingPathComponent("History")
        _ = try OneClickMigrator.writeChromiumHistory(to: dbFile, items: [
            HistoryItem(url: "https://swift.org", title: "Swift", time: 1700000000000)
        ])

        // Hold an exclusive lock on the database
        var lockDB: OpaquePointer?
        #expect(sqlite3_open(dbFile.path, &lockDB) == SQLITE_OK)
        #expect(sqlite3_exec(lockDB, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)

        // Direct reading via PlacesReader.rows (using file:?immutable=1) should succeed without error
        var readURLs: [String] = []
        try PlacesReader.rows(dbFile, sql: "SELECT url FROM urls") { q in
            if let u = PlacesReader.string(q, 0) { readURLs.append(u) }
        }
        #expect(readURLs.contains("https://swift.org"))

        sqlite3_exec(lockDB, "ROLLBACK;", nil, nil, nil)
        sqlite3_close(lockDB)
    }

    @Test func testRollbackDeletesNewlyCreatedHistoryFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("Src")
        let dst = root.appendingPathComponent("Dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let srcHist = src.appendingPathComponent("History")
        _ = try OneClickMigrator.writeChromiumHistory(to: srcHist, items: [
            HistoryItem(url: "https://rust-lang.org", title: "Rust", time: 1700000000000)
        ])

        let dstHist = dst.appendingPathComponent("History")
        #expect(!FileManager.default.fileExists(atPath: dstHist.path))

        // Migrate into clean destination
        let receipt = try await OneClickMigrator.migrate(
            sourceBrowser: .chrome,
            sourceProfile: src,
            destinationBrowser: .brave,
            destinationProfile: dst,
            options: TransferOptions(bookmarks: false, tabs: false, history: true, groups: false),
            backupDirectory: root.appendingPathComponent("Backup"),
            closeDestinationIfRunning: false,
            openDestination: false
        )

        #expect(FileManager.default.fileExists(atPath: dstHist.path))

        // Roll back: since dst originally had NO History file, rollback must delete it
        try await OneClickMigrator.rollback(receipt: receipt, closeDestinationIfRunning: false)
        #expect(!FileManager.default.fileExists(atPath: dstHist.path))
    }

    @Test func testChromiumUserDataRootProfileResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("SourceProfile")
        let chromeUserData = root.appendingPathComponent("Google/Chrome")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chromeUserData.appendingPathComponent("Default"), withIntermediateDirectories: true)

        _ = try OneClickMigrator.writeChromiumHistory(to: src.appendingPathComponent("History"), items: [
            HistoryItem(url: "https://browserbridge.app", title: "Browser Bridge", time: 1700000000000)
        ])

        let receipt = try await OneClickMigrator.migrate(
            sourceBrowser: .chrome,
            sourceProfile: src,
            destinationBrowser: .chrome,
            destinationProfile: chromeUserData,
            options: TransferOptions(bookmarks: false, tabs: false, history: true, groups: false),
            backupDirectory: root.appendingPathComponent("Backup"),
            closeDestinationIfRunning: false,
            openDestination: false
        )

        #expect(receipt.status == "complete")
        // Verify History is placed in Default/History and not orphaned at Google/Chrome/History
        let defaultHist = chromeUserData.appendingPathComponent("Default/History")
        #expect(FileManager.default.fileExists(atPath: defaultHist.path))
        let rowCount = try countRows(in: defaultHist, table: "urls")
        #expect(rowCount == 1)
    }

    @Test func testHistoryOnlyMigrationPreservesExistingBookmarksAndSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("Src")
        let diaUserData = root.appendingPathComponent("Dia/User Data")
        let profile9 = diaUserData.appendingPathComponent("Profile 9")
        let sessionsDir = profile9.appendingPathComponent("Sessions")

        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Write active session file in Profile 9
        let sessionFile = sessionsDir.appendingPathComponent("Session_1234567890")
        try "active-dia-session-data".write(to: sessionFile, atomically: true, encoding: .utf8)

        // Write existing Bookmarks in Profile 9
        let existingBookmarksJson = """
        {
            "roots": {
                "bookmark_bar": {
                    "children": [
                        { "name": "Preserved Existing Bookmark", "type": "url", "url": "https://example.org" },
                        { "name": "Migrated from Zen", "type": "folder", "children": [
                            { "name": "Existing Zen Tab", "type": "url", "url": "https://old.zen.tab" }
                        ]}
                    ],
                    "name": "Bookmarks bar",
                    "type": "folder"
                }
            },
            "version": 1
        }
        """
        try existingBookmarksJson.write(to: profile9.appendingPathComponent("Bookmarks"), atomically: true, encoding: .utf8)

        // Write Local State pointing to Profile 9
        let localStateJson = """
        {
            "profile": {
                "info_cache": {
                    "Profile 9": {
                        "name": "Personal"
                    }
                },
                "last_used": "Profile 9",
                "profiles_order": ["Profile 9"]
            }
        }
        """
        try localStateJson.write(to: diaUserData.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)

        // Populate source history
        _ = try OneClickMigrator.writeChromiumHistory(to: src.appendingPathComponent("History"), items: [
            HistoryItem(url: "https://apple.com", title: "Apple", time: 1700000000000),
            HistoryItem(url: "https://swift.org", title: "Swift", time: 1700000001000)
        ])

        // Run history-only migration
        let receipt = try await OneClickMigrator.migrate(
            sourceBrowser: .chrome,
            sourceProfile: src,
            destinationBrowser: .dia,
            destinationProfile: diaUserData,
            options: TransferOptions(bookmarks: false, tabs: false, history: true, groups: false),
            backupDirectory: root.appendingPathComponent("Backup"),
            closeDestinationIfRunning: false,
            openDestination: false
        )

        #expect(receipt.status == "complete")
        #expect(receipt.historyCount == 2)
        #expect(receipt.bookmarksCount == 0)
        #expect(receipt.tabsCount == 0)
        #expect(receipt.groupsCount == 0)
        #expect(!receipt.warnings.contains { $0.contains("Could not write history to Default") })

        // 1. Verify Sessions directory and file were NOT deleted
        #expect(FileManager.default.fileExists(atPath: sessionFile.path))
        let sessionContent = try String(contentsOf: sessionFile, encoding: .utf8)
        #expect(sessionContent == "active-dia-session-data")

        // 2. Verify Bookmarks file was NOT overwritten or clobbered
        let bmData = try Data(contentsOf: profile9.appendingPathComponent("Bookmarks"))
        let bmObj = try #require(try JSONSerialization.jsonObject(with: bmData) as? [String: Any])
        let roots = try #require(bmObj["roots"] as? [String: Any])
        let bar = try #require(roots["bookmark_bar"] as? [String: Any])
        let children = try #require(bar["children"] as? [[String: Any]])
        #expect(children.contains { ($0["name"] as? String) == "Preserved Existing Bookmark" })
        let zenFolder = try #require(children.first { ($0["name"] as? String) == "Migrated from Zen" })
        let zenChildren = try #require(zenFolder["children"] as? [[String: Any]])
        #expect(zenChildren.contains { ($0["name"] as? String) == "Existing Zen Tab" })

        // 3. Verify History was written to Profile 9/History
        let prof9Hist = profile9.appendingPathComponent("History")
        #expect(FileManager.default.fileExists(atPath: prof9Hist.path))
        let histCount = try countRows(in: prof9Hist, table: "urls")
        #expect(histCount == 2)

        // 4. Verify no Default directory was erroneously created with History
        #expect(!FileManager.default.fileExists(atPath: diaUserData.appendingPathComponent("Default/History").path))
    }

    @Test func testChromiumHistoryCompleteSchemaInitialization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let histFile = root.appendingPathComponent("Profile 1/History")
        let items: [HistoryItem] = [
            HistoryItem(url: "https://example.com", title: "Example", time: 1700000000000)
        ]

        let count = try OneClickMigrator.writeChromiumHistory(to: histFile, items: items)
        #expect(count == 1)

        // Verify complete Chromium v70 table suite exists (22 tables) so Chromium/Dia never razes the database
        let requiredTables = [
            "meta", "urls", "visits", "visit_source", "keyword_search_terms", "downloads",
            "downloads_slices", "downloads_url_chains", "segments", "segment_usage",
            "content_annotations", "context_annotations", "clusters", "clusters_and_visits",
            "cluster_keywords", "cluster_visit_duplicates", "visited_links",
            "history_sync_metadata", "journeys", "journey_history_entries",
            "journey_continuation_queries", "journey_sync_metadata"
        ]
        for tbl in requiredTables {
            let rowCount = try countRows(in: histFile, table: tbl)
            #expect(rowCount >= 0)
        }

        // Verify all 18 Chromium indexes are present
        let requiredIndexes = [
            "urls_url_index", "visits_url_index", "visits_time_index", "visits_from_index",
            "visits_originator_id_index", "keyword_search_terms_index1", "keyword_search_terms_index2",
            "keyword_search_terms_index3", "segments_name", "segments_url_id",
            "segment_usage_time_slot_segment_id", "segments_usage_seg_id", "clusters_for_visit",
            "cluster_keywords_cluster_id_index", "visited_links_index", "journeys_creation_time_idx",
            "journey_history_entries_timestamp_idx", "journey_continuation_queries_journey_id_idx"
        ]
        var createdIndexes = Set<String>()
        try PlacesReader.rows(histFile, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL;") { stmt in
            if let cStr = sqlite3_column_text(stmt, 0) {
                createdIndexes.insert(String(cString: cStr))
            }
        }
        for idx in requiredIndexes {
            #expect(createdIndexes.contains(idx))
        }

        // Verify meta table contains Chromium version 70 and required keys
        var metaKeys: [String: String] = [:]
        try PlacesReader.rows(histFile, sql: "SELECT key, value FROM meta;") { stmt in
            if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                metaKeys[String(cString: k)] = String(cString: v)
            }
        }
        #expect(metaKeys["version"] == "70")
        #expect(metaKeys["last_compatible_version"] == "16")
        #expect(metaKeys["mmap_status"] == "-1")
        #expect(metaKeys["early_expiration_threshold"] != nil)

        // Sibling template copy test: create Profile 2 and ensure it leverages Profile 1
        let prof2Hist = root.appendingPathComponent("Profile 2/History")
        let items2: [HistoryItem] = [
            HistoryItem(url: "https://example.org/second", title: "Second", time: 1700000100000)
        ]
        let count2 = try OneClickMigrator.writeChromiumHistory(to: prof2Hist, items: items2)
        #expect(count2 == 1)
        let prof2Urls = try countRows(in: prof2Hist, table: "urls")
        #expect(prof2Urls >= 1)
    }
}

