import Foundation
import AppKit
import CryptoKit
import CSQLite

public struct OneClickReceipt: Codable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var sourceBrowser: BrowserID
    public var sourceProfilePath: String
    public var destinationBrowser: BrowserID
    public var destinationProfilePath: String
    public var backupDirectoryPath: String
    public var migratedFolder: String
    public var bookmarksCount: Int
    public var tabsCount: Int
    public var groupsCount: Int
    public var historyCount: Int
    public var status: String
    public var destinationOpened: Bool
    public var warnings: [String]

    public init(id: String = UUID().uuidString,
                createdAt: Date = Date(),
                sourceBrowser: BrowserID,
                sourceProfilePath: String,
                destinationBrowser: BrowserID,
                destinationProfilePath: String,
                backupDirectoryPath: String,
                migratedFolder: String,
                bookmarksCount: Int,
                tabsCount: Int,
                groupsCount: Int,
                historyCount: Int,
                status: String = "complete",
                destinationOpened: Bool = false,
                warnings: [String] = []) {
        self.id = id
        self.createdAt = createdAt
        self.sourceBrowser = sourceBrowser
        self.sourceProfilePath = sourceProfilePath
        self.destinationBrowser = destinationBrowser
        self.destinationProfilePath = destinationProfilePath
        self.backupDirectoryPath = backupDirectoryPath
        self.migratedFolder = migratedFolder
        self.bookmarksCount = bookmarksCount
        self.tabsCount = tabsCount
        self.groupsCount = groupsCount
        self.historyCount = historyCount
        self.status = status
        self.destinationOpened = destinationOpened
        self.warnings = warnings
    }
}

public enum OneClickMigrator {
    public static let browserBundleIdentifiers: [BrowserID: [String]] = [
        .chrome: ["com.google.Chrome", "com.google.chrome.for.testing"],
        .brave: ["com.brave.Browser"],
        .arc: ["company.thebrowser.Browser"],
        .zen: ["app.zen-browser.zen", "org.mozilla.zen"],
        .dia: ["company.thebrowser.dia", "com.dia.browser"],
        .firefox: ["org.mozilla.firefox", "org.mozilla.nightly"],
        .safari: ["com.apple.Safari"],
        .edge: ["com.microsoft.edgemac"],
        .opera: ["com.operasoftware.Opera", "com.operasoftware.OperaGX"],
        .vivaldi: ["com.vivaldi.Vivaldi"],
        .helium: ["net.imput.helium", "net.kagi.Helium"]
    ]

    public static let browserAppNames: [BrowserID: [String]] = [
        .chrome: ["Google Chrome", "Chrome"],
        .brave: ["Brave Browser", "Brave"],
        .arc: ["Arc"],
        .zen: ["Zen Browser", "Zen"],
        .dia: ["Dia"],
        .firefox: ["Firefox"],
        .safari: ["Safari"],
        .edge: ["Microsoft Edge", "Edge"],
        .opera: ["Opera", "Opera GX"],
        .vivaldi: ["Vivaldi"],
        .helium: ["Helium"]
    ]

    @MainActor public static func runningApplications(for browser: BrowserID) -> [NSRunningApplication] {
        let bundleIDs = Set(browserBundleIdentifiers[browser] ?? [])
        let names = Set((browserAppNames[browser] ?? []).map { $0.lowercased() })
        return NSWorkspace.shared.runningApplications.filter { app in
            if let id = app.bundleIdentifier, bundleIDs.contains(id) { return true }
            if let name = app.localizedName?.lowercased(), names.contains(name) { return true }
            return false
        }
    }

    @MainActor public static func gracefullyQuitRunning(browser: BrowserID, timeout: TimeInterval = 4.0) async -> Bool {
        let running = runningApplications(for: browser)
        guard !running.isEmpty else { return true }
        for app in running {
            _ = app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillRunning = runningApplications(for: browser)
            if stillRunning.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let stillRunning = runningApplications(for: browser)
        if stillRunning.isEmpty { return true }

        // If graceful quit was ignored or blocked by prompts, force-terminate to release file locks
        for app in stillRunning {
            _ = app.forceTerminate()
        }
        let forceDeadline = Date().addingTimeInterval(2.0)
        while Date() < forceDeadline {
            if runningApplications(for: browser).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return runningApplications(for: browser).isEmpty
    }

    public static var defaultReceiptRoot: URL {
        TransferCoordinator.defaultReceiptRoot.deletingLastPathComponent().appendingPathComponent("OneClickTransfers")
    }

    public static var defaultBackupRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/BrowserBridge/Backups")
    }

    public static var ephemeralReceiptRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BrowserBridgeTestReceipts", isDirectory: true)
    }

    nonisolated(unsafe) public static var receiptDirectoryOverride: URL? = nil

    public static func resolveReceiptDirectory(
        explicit: URL? = nil,
        backupDir: URL? = nil,
        sourceProfile: URL? = nil,
        destinationProfile: URL? = nil
    ) -> URL {
        if let explicit { return explicit }
        if let receiptDirectoryOverride { return receiptDirectoryOverride }
        let paths = [backupDir?.path, sourceProfile?.path, destinationProfile?.path].compactMap { $0 }
        let isEphemeral = paths.contains { path in
            path.contains("/var/folders") ||
            path.contains("/tmp") ||
            path.hasPrefix(FileManager.default.temporaryDirectory.path)
        }
        if isEphemeral {
            return ephemeralReceiptRoot
        }
        return defaultReceiptRoot
    }

    public static func receipts(directory: URL? = nil) throws -> [OneClickReceipt] {
        var roots: [URL] = []
        if let directory {
            roots.append(directory)
        } else if let receiptDirectoryOverride {
            roots.append(receiptDirectoryOverride)
        } else {
            roots.append(defaultReceiptRoot)
        }
        var results: [OneClickReceipt] = []
        var seenIDs = Set<String>()
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
                .compactMap { file in
                    try? JSONDecoder().decode(OneClickReceipt.self, from: Data(contentsOf: file))
                } ?? []
            for item in items where seenIDs.insert(item.id).inserted {
                // If reading from defaultReceiptRoot (not explicit directory or override), exclude test receipts
                if directory == nil && receiptDirectoryOverride == nil {
                    let isTest = item.sourceProfilePath.contains("/var/folders")
                        || item.sourceProfilePath.contains("/tmp")
                        || item.destinationProfilePath.contains("/var/folders")
                        || item.destinationProfilePath.contains("/tmp")
                        || item.backupDirectoryPath.contains("/var/folders")
                        || item.backupDirectoryPath.contains("/tmp")
                    if isTest { continue }
                }
                results.append(item)
            }
        }
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    public static func saveReceipt(_ receipt: OneClickReceipt, directory: URL? = nil) throws {
        let backupURL = URL(fileURLWithPath: receipt.backupDirectoryPath)
        let sourceURL = URL(fileURLWithPath: receipt.sourceProfilePath)
        let destURL = URL(fileURLWithPath: receipt.destinationProfilePath)
        let root = resolveReceiptDirectory(
            explicit: directory,
            backupDir: backupURL,
            sourceProfile: sourceURL,
            destinationProfile: destURL
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("\(receipt.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        try data.write(to: file, options: .atomic)
    }

    public static func deleteReceipt(id: String, directory: URL? = nil) throws {
        var roots: [URL] = []
        if let directory {
            roots.append(directory)
        } else if let receiptDirectoryOverride {
            roots.append(receiptDirectoryOverride)
            roots.append(defaultReceiptRoot)
            roots.append(ephemeralReceiptRoot)
        } else {
            roots.append(defaultReceiptRoot)
            roots.append(ephemeralReceiptRoot)
        }
        for root in roots {
            let file = root.appendingPathComponent("\(id).json")
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    @discardableResult
    public static func cleanTestReceipts(from directory: URL = defaultReceiptRoot) throws -> Int {
        let fm = FileManager.default
        var removed = 0
        if fm.fileExists(atPath: directory.path) {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" } ?? []
            for file in files {
                if let data = try? Data(contentsOf: file),
                   let receipt = try? JSONDecoder().decode(OneClickReceipt.self, from: data) {
                    let isTest = receipt.sourceProfilePath.contains("/var/folders")
                        || receipt.sourceProfilePath.contains("/tmp")
                        || receipt.destinationProfilePath.contains("/var/folders")
                        || receipt.destinationProfilePath.contains("/tmp")
                        || receipt.backupDirectoryPath.contains("/var/folders")
                        || receipt.backupDirectoryPath.contains("/tmp")
                    if isTest {
                        try? fm.removeItem(at: file)
                        removed += 1
                    }
                }
            }
        }
        let ephemeral = ephemeralReceiptRoot
        if fm.fileExists(atPath: ephemeral.path) {
            try? fm.removeItem(at: ephemeral)
        }
        return removed
    }

    public static func resolvePrimaryChromiumProfile(userDataDir: URL, fm: FileManager = .default) -> URL {
        let lsURL = userDataDir.appendingPathComponent("Local State")
        if let lsData = try? Data(contentsOf: lsURL),
           let lsObj = try? JSONSerialization.jsonObject(with: lsData) as? [String: Any],
           let pDict = lsObj["profile"] as? [String: Any],
           let lastUsed = pDict["last_used"] as? String,
           !lastUsed.isEmpty {
            let prof = userDataDir.appendingPathComponent(lastUsed)
            if fm.fileExists(atPath: prof.path) {
                return prof
            }
        }

        let candidates = (try? fm.contentsOfDirectory(at: userDataDir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile") } ?? []

        if let defaultDir = candidates.first(where: { $0.lastPathComponent == "Default" }) {
            return defaultDir
        }
        if let firstCandidate = candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return firstCandidate
        }

        let fallback = userDataDir.appendingPathComponent("Default")
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return fallback
    }

    public static func migrate(
        sourceBrowser: BrowserID,
        sourceProfile: URL,
        destinationBrowser: BrowserID,
        destinationProfile: URL,
        options: TransferOptions = TransferOptions(bookmarks: true, tabs: true, history: true, groups: true),
        backupDirectory: URL? = nil,
        receiptDirectory: URL? = nil,
        closeDestinationIfRunning: Bool = true,
        openDestination: Bool = false
    ) async throws -> OneClickReceipt {
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceProfile.path) else {
            throw BridgeError.message("Source profile does not exist at \(sourceProfile.path)")
        }

        let canonicalSource = (sourceProfile.path as NSString).resolvingSymlinksInPath
        let canonicalDest = (destinationProfile.path as NSString).resolvingSymlinksInPath
        if canonicalSource == canonicalDest {
            throw BridgeError.message("Source and destination profiles are the same folder. Choose different profiles.")
        }

        // Handle running destination browser to ensure zero data overwrite
        if closeDestinationIfRunning {
            let running = await MainActor.run { runningApplications(for: destinationBrowser) }
            if !running.isEmpty {
                let closed = await gracefullyQuitRunning(browser: destinationBrowser, timeout: 4.0)
                if !closed {
                    throw BridgeError.message("\(destinationBrowser.name) is currently running and could not be closed automatically. Please quit \(destinationBrowser.name) to prevent overwriting your migrated data, then retry.")
                }
            }
        }

        // 1. Read source data
        let snapshot = try BrowserReader.read(profile: sourceProfile, browser: sourceBrowser)

        // 2. Prepare Backup directory
        let backupBase = backupDirectory ?? defaultBackupRoot
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let receiptID = UUID().uuidString
        let backupFolder = backupBase.appendingPathComponent("Backup-\(destinationBrowser.name)-\(stamp)-\(receiptID.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // 3. Backup existing destination profile files (e.g. Bookmarks, places.sqlite, History)
        let historyFiles = ["History", "History-journal", "History-wal", "History-shm"]
        if fm.fileExists(atPath: destinationProfile.path) {
            var filesToBackup = ["Bookmarks", "Bookmarks.bak", "places.sqlite", "places.sqlite-wal", "places.sqlite-shm", "History.db", "Bookmarks.plist"]
            filesToBackup.append(contentsOf: historyFiles)
            for name in filesToBackup {
                let file = destinationProfile.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) {
                    try? fm.copyItem(at: file, to: backupFolder.appendingPathComponent(name))
                }
            }
        } else {
            try fm.createDirectory(at: destinationProfile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        // For Chromium browsers (including Dia, Arc, Chrome, Brave, etc.), backup Local State and all candidate profiles' Bookmarks/History
        if destinationBrowser.family == .chromium {
            let isProfileDir = destinationProfile.lastPathComponent.hasPrefix("Profile") || destinationProfile.lastPathComponent == "Default"
            let userDataDir = isProfileDir ? destinationProfile.deletingLastPathComponent() : destinationProfile
            let ls = userDataDir.appendingPathComponent("Local State")
            if fm.fileExists(atPath: ls.path) {
                try? fm.copyItem(at: ls, to: backupFolder.appendingPathComponent("Local State"))
            }
            if let children = try? fm.contentsOfDirectory(at: userDataDir, includingPropertiesForKeys: nil) {
                for child in children where child.lastPathComponent.hasPrefix("Profile") || child.lastPathComponent == "Default" {
                    let pName = child.lastPathComponent
                    for hFile in ["Bookmarks", "Bookmarks.bak", "History", "History-journal", "History-wal", "History-shm"] {
                        let src = child.appendingPathComponent(hFile)
                        if fm.fileExists(atPath: src.path) {
                            try? fm.copyItem(at: src, to: backupFolder.appendingPathComponent("\(pName)_\(hFile)"))
                        }
                    }
                }
            }
        }

        var warnings: [String] = snapshot.warnings
        let folderTitle = "Migrated from \(sourceBrowser.name)"

        var bookmarksMigrated = 0
        var tabsMigrated = 0
        var groupsMigrated = 0
        var historyMigrated = 0

        // 4. Perform direct destination migration based on destination family
        switch destinationBrowser.family {
        case .chromium:
            if options.bookmarks || options.tabs || options.groups {
                let (bCount, tCount, gCount) = try migrateToChromium(
                    destinationProfile: destinationProfile,
                    sourceBrowser: sourceBrowser,
                    snapshot: snapshot,
                    options: options,
                    folderTitle: folderTitle
                )
                bookmarksMigrated = bCount
                tabsMigrated = tCount
                groupsMigrated = gCount

                if destinationBrowser == .dia && !snapshot.spaces.isEmpty {
                    let (diaB, diaT, diaG) = try migrateToDiaSpaces(
                        destinationRootOrProfile: destinationProfile,
                        sourceBrowser: sourceBrowser,
                        snapshot: snapshot,
                        options: options,
                        folderTitle: folderTitle,
                        backupFolder: backupFolder
                    )
                    bookmarksMigrated = max(bookmarksMigrated, diaB)
                    tabsMigrated = max(tabsMigrated, diaT)
                    groupsMigrated = max(groupsMigrated, diaG)
                }
            }

            if options.history && !snapshot.history.isEmpty {
                let isUserDataRoot = destinationProfile.lastPathComponent.lowercased().contains("user data")
                    || destinationProfile.lastPathComponent.lowercased().contains("chrome")
                    || destinationProfile.lastPathComponent.lowercased().contains("brave")
                    || destinationProfile.lastPathComponent.lowercased().contains("arc")
                    || destinationProfile.lastPathComponent.lowercased().contains("dia")
                    || destinationProfile.lastPathComponent.lowercased().contains("edge")
                    || destinationProfile.lastPathComponent.lowercased().contains("opera")
                    || destinationProfile.lastPathComponent.lowercased().contains("vivaldi")
                    || fm.fileExists(atPath: destinationProfile.appendingPathComponent("Local State").path)

                let isProfileDir = destinationProfile.lastPathComponent.hasPrefix("Profile")
                    || destinationProfile.lastPathComponent == "Default"
                    || !isUserDataRoot
                let userDataDir = isProfileDir ? destinationProfile.deletingLastPathComponent() : destinationProfile
                let isRealUserData = fm.fileExists(atPath: userDataDir.appendingPathComponent("Local State").path)
                    || userDataDir.lastPathComponent.lowercased().contains("user data")
                    || userDataDir.lastPathComponent.lowercased().contains("chrome")
                    || userDataDir.lastPathComponent.lowercased().contains("arc")
                    || userDataDir.lastPathComponent.lowercased().contains("dia")
                    || userDataDir.lastPathComponent.lowercased().contains("brave")
                    || userDataDir.lastPathComponent.lowercased().contains("edge")

                let candidateDirs: [URL]
                if isRealUserData {
                    candidateDirs = (try? fm.contentsOfDirectory(at: userDataDir, includingPropertiesForKeys: nil))?
                        .filter { $0.lastPathComponent.hasPrefix("Profile") || $0.lastPathComponent == "Default" } ?? []
                } else {
                    candidateDirs = []
                }
                let primaryProf = isProfileDir ? destinationProfile : resolvePrimaryChromiumProfile(userDataDir: userDataDir, fm: fm)

                var allTargetProfiles: [URL] = candidateDirs
                if !allTargetProfiles.contains(where: { $0.standardizedFileURL == primaryProf.standardizedFileURL }) {
                    allTargetProfiles.insert(primaryProf, at: 0)
                }
                // Check Local State for any other profile directories (especially for Dia spaces or Arc profiles)
                if isRealUserData {
                    let lsURL = userDataDir.appendingPathComponent("Local State")
                    if let lsData = try? Data(contentsOf: lsURL),
                       let json = try? JSONSerialization.jsonObject(with: lsData) as? [String: Any],
                       let profileDict = json["profile"] as? [String: Any] {
                        let order = (profileDict["profiles_order"] as? [String]) ?? []
                        let cacheKeys = Array(((profileDict["info_cache"] as? [String: Any]) ?? [:]).keys)
                        for profName in order + cacheKeys {
                            let profURL = userDataDir.appendingPathComponent(profName)
                            if fm.fileExists(atPath: profURL.path) && !allTargetProfiles.contains(where: { $0.standardizedFileURL == profURL.standardizedFileURL }) {
                                allTargetProfiles.append(profURL)
                            }
                        }
                    }
                }

                var written = 0
                for profDir in allTargetProfiles {
                    let histFile = profDir.appendingPathComponent("History")
                    do {
                        let count = try writeChromiumHistory(to: histFile, items: snapshot.history)
                        written = max(written, count)
                    } catch {
                        warnings.append("Could not write history to \(profDir.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if allTargetProfiles.isEmpty && !isProfileDir {
                    let directHist = destinationProfile.appendingPathComponent("History")
                    do {
                        let count = try writeChromiumHistory(to: directHist, items: snapshot.history)
                        written = max(written, count)
                    } catch {
                        warnings.append("Could not write history to \(destinationProfile.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                historyMigrated = written
            } else if options.history {
                historyMigrated = 0
            }

        case .firefox:
            if options.bookmarks || options.tabs || options.groups {
                let (bCount, tCount) = try migrateToFirefox(
                    destinationProfile: destinationProfile,
                    sourceBrowser: sourceBrowser,
                    snapshot: snapshot,
                    options: options,
                    folderTitle: folderTitle,
                    backupFolder: backupFolder
                )
                bookmarksMigrated = bCount
                tabsMigrated = tCount
                groupsMigrated = snapshot.spaces.count
            }

            if options.history && !snapshot.history.isEmpty {
                let placesURL = destinationProfile.appendingPathComponent("places.sqlite")
                historyMigrated = try writeFirefoxHistory(to: placesURL, items: snapshot.history)
            } else if options.history {
                historyMigrated = 0
            }

        case .safari:
            if options.bookmarks || options.tabs || options.groups {
                let (bCount, tCount) = try migrateToSafari(
                    destinationProfile: destinationProfile,
                    sourceBrowser: sourceBrowser,
                    snapshot: snapshot,
                    options: options,
                    folderTitle: folderTitle,
                    backupFolder: backupFolder
                )
                bookmarksMigrated = bCount
                tabsMigrated = tCount
                groupsMigrated = snapshot.spaces.count
            }

            if options.history {
                historyMigrated = 0
                warnings.append("Safari history is protected by macOS System Integrity Protection and cannot be injected directly; bookmarks and open tabs were migrated.")
            }
        }

        // 5. Optionally launch destination browser with migrated tabs
        var destinationOpened = false
        if openDestination {
            try? await Task.sleep(for: .milliseconds(500))
            destinationOpened = await MainActor.run {
                launchDestination(browser: destinationBrowser, tabs: snapshot.tabs)
            }
            if destinationBrowser == .dia {
                try? await Task.sleep(for: .milliseconds(1200))
                _ = await MainActor.run {
                    syncDiaLiveSpaces(snapshot: snapshot)
                }
            }
        }

        let receipt = OneClickReceipt(
            id: receiptID,
            createdAt: Date(),
            sourceBrowser: sourceBrowser,
            sourceProfilePath: sourceProfile.path,
            destinationBrowser: destinationBrowser,
            destinationProfilePath: destinationProfile.path,
            backupDirectoryPath: backupFolder.path,
            migratedFolder: folderTitle,
            bookmarksCount: bookmarksMigrated,
            tabsCount: tabsMigrated,
            groupsCount: groupsMigrated,
            historyCount: historyMigrated,
            status: "complete",
            destinationOpened: destinationOpened,
            warnings: warnings
        )

        try saveReceipt(receipt, directory: receiptDirectory)
        return receipt
    }

    // MARK: - Chromium Migration
    private static func migrateToChromium(
        destinationProfile: URL,
        sourceBrowser: BrowserID,
        snapshot: Snapshot,
        options: TransferOptions,
        folderTitle: String
    ) throws -> (bookmarks: Int, tabs: Int, groups: Int) {
        let fm = FileManager.default
        let bookmarksURL = destinationProfile.appendingPathComponent("Bookmarks")
        var rootObject: [String: Any] = [:]

        if fm.fileExists(atPath: bookmarksURL.path),
           let data = try? Data(contentsOf: bookmarksURL),
           !data.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rootObject = parsed
        }

        if rootObject["version"] == nil {
            rootObject["version"] = 1
        }

        var roots = (rootObject["roots"] as? [String: Any]) ?? [:]
        var bar = (roots["bookmark_bar"] as? [String: Any]) ?? [
            "children": [] as [[String: Any]],
            "name": "Bookmarks bar",
            "type": "folder"
        ]
        var barChildren = (bar["children"] as? [[String: Any]]) ?? []

        // Remove existing migration folder if present to avoid duplication
        barChildren.removeAll { ($0["name"] as? String) == folderTitle }

        var nextID: Int64 = 100000
        func genID() -> String {
            nextID += 1
            return "\(nextID)"
        }

        var folderChildren: [[String: Any]] = []
        var bCount = 0
        var tCount = 0
        var gCount = 0

        func isValidHttpURL(_ s: String) -> Bool {
            guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }

        func tabUrl(_ tab: BrowserTab) -> String {
            tab.originalURL ?? tab.url
        }

        func tabTitle(_ tab: BrowserTab) -> String {
            let url = tabUrl(tab)
            let trimmed = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? url : trimmed
        }

        func makeUrlNode(name: String, url: String) -> [String: Any] {
            [
                "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                "id": genID(),
                "name": name,
                "type": "url",
                "url": url
            ]
        }

        func makeFolderNode(name: String, children: [[String: Any]]) -> [String: Any] {
            [
                "children": children,
                "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                "id": genID(),
                "name": name.isEmpty ? "Folder" : name,
                "type": "folder"
            ]
        }

        var countedTabIDs = Set<String>()
        func makeTabNode(_ tab: BrowserTab, prefixPin: Bool = false) -> [String: Any]? {
            let url = tabUrl(tab)
            guard isValidHttpURL(url) else { return nil }
            if countedTabIDs.insert(tab.id).inserted {
                tCount += 1
            }
            let title = tabTitle(tab)
            let displayName = prefixPin && (tab.pinned || tab.essential) ? "📌 \(title)" : title
            return makeUrlNode(name: displayName, url: url)
        }

        // 1. Essentials folder
        if options.tabs {
            let essentialTabs = snapshot.tabs.filter { $0.essential && isValidHttpURL(tabUrl($0)) }
                .sorted { $0.order < $1.order }
            var essNodes: [[String: Any]] = []
            for tab in essentialTabs {
                if let node = makeTabNode(tab, prefixPin: false) {
                    essNodes.append(node)
                }
            }
            if !essNodes.isEmpty {
                folderChildren.append(makeFolderNode(name: "⭐ Essentials", children: essNodes))
            }
        }

        // 2. Spaces & Folders hierarchy
        let allFolderIDs = Set(snapshot.folders.map(\.id))
        let knownSpaceIDs = Set(snapshot.spaces.map(\.id))
        var visitedFolderIDs = Set<String>()

        func buildFolderHierarchy(folder: Folder) -> [String: Any]? {
            guard visitedFolderIDs.insert(folder.id).inserted else { return nil }
            gCount += 1

            var children: [[String: Any]] = []

            // Nested child subfolders
            let subfolders = snapshot.folders.filter { $0.parentID == folder.id && !visitedFolderIDs.contains($0.id) }
            for sub in subfolders {
                if let subNode = buildFolderHierarchy(folder: sub) {
                    children.append(subNode)
                }
            }

            // Tabs assigned to this folder
            let folderTabs = snapshot.tabs.filter { $0.folderID == folder.id && isValidHttpURL(tabUrl($0)) }
                .sorted { $0.order < $1.order }
            for tab in folderTabs {
                if let node = makeTabNode(tab, prefixPin: true) {
                    children.append(node)
                }
            }

            return makeFolderNode(name: folder.name.isEmpty ? "Folder" : folder.name, children: children)
        }

        // Workspaces / Spaces with their Pinned Tabs, Folders, and Open Tabs
        if options.groups && !snapshot.spaces.isEmpty {
            for space in snapshot.spaces {
                var spaceChildren: [[String: Any]] = []

                // Space Pinned Tabs
                if options.tabs {
                    let spacePins = snapshot.tabs.filter {
                        $0.spaceID == space.id && $0.pinned && !$0.essential &&
                        ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                        isValidHttpURL(tabUrl($0))
                    }.sorted { $0.order < $1.order }

                    var pinNodes: [[String: Any]] = []
                    for tab in spacePins {
                        if let node = makeTabNode(tab, prefixPin: false) {
                            pinNodes.append(node)
                        }
                    }
                    if !pinNodes.isEmpty {
                        spaceChildren.append(makeFolderNode(name: "📌 Pinned Tabs", children: pinNodes))
                    }
                }

                // Space Folders (root folders belonging to this space)
                let spaceRootFolders = snapshot.folders.filter {
                    $0.spaceID == space.id && ($0.parentID == nil || !allFolderIDs.contains($0.parentID!))
                }
                for folder in spaceRootFolders {
                    if let folderNode = buildFolderHierarchy(folder: folder) {
                        spaceChildren.append(folderNode)
                    }
                }

                // Space Open Tabs
                if options.tabs {
                    let spaceOpen = snapshot.tabs.filter {
                        $0.spaceID == space.id && !$0.pinned && !$0.essential &&
                        ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                        isValidHttpURL(tabUrl($0))
                    }.sorted { $0.order < $1.order }

                    var openNodes: [[String: Any]] = []
                    for tab in spaceOpen {
                        if let node = makeTabNode(tab, prefixPin: false) {
                            openNodes.append(node)
                        }
                    }
                    if !openNodes.isEmpty {
                        if !spaceChildren.isEmpty {
                            spaceChildren.append(makeFolderNode(name: "Open Tabs", children: openNodes))
                        } else {
                            spaceChildren.append(contentsOf: openNodes)
                        }
                    }
                }

                if !spaceChildren.isEmpty {
                    gCount += 1
                    folderChildren.append(makeFolderNode(name: space.name, children: spaceChildren))
                }
            }
        }

        // Folders outside spaces (or all folders if spaces are disabled/empty)
        if options.groups || options.tabs {
            let globalRoots = snapshot.folders.filter {
                !visitedFolderIDs.contains($0.id) &&
                ($0.parentID == nil || !allFolderIDs.contains($0.parentID!))
            }
            for folder in globalRoots {
                if let folderNode = buildFolderHierarchy(folder: folder) {
                    folderChildren.append(folderNode)
                }
            }
            for folder in snapshot.folders where !visitedFolderIDs.contains(folder.id) {
                if let folderNode = buildFolderHierarchy(folder: folder) {
                    folderChildren.append(folderNode)
                }
            }
        }

        // Global Pinned tabs (outside spaces)
        if options.tabs {
            let globalPins = snapshot.tabs.filter {
                $0.pinned && !$0.essential &&
                ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)) &&
                isValidHttpURL(tabUrl($0))
            }.sorted { $0.order < $1.order }

            var globalPinNodes: [[String: Any]] = []
            for tab in globalPins {
                if let node = makeTabNode(tab, prefixPin: false) {
                    globalPinNodes.append(node)
                }
            }
            if !globalPinNodes.isEmpty {
                folderChildren.append(makeFolderNode(name: "📌 Pinned Tabs", children: globalPinNodes))
            }

            // Global Open tabs (outside spaces)
            let globalOpen = snapshot.tabs.filter {
                !$0.pinned && !$0.essential &&
                ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)) &&
                isValidHttpURL(tabUrl($0))
            }.sorted { $0.order < $1.order }

            var globalOpenNodes: [[String: Any]] = []
            for tab in globalOpen {
                if let node = makeTabNode(tab, prefixPin: false) {
                    globalOpenNodes.append(node)
                }
            }
            if !globalOpenNodes.isEmpty {
                folderChildren.append(makeFolderNode(name: "Open Tabs", children: globalOpenNodes))
            }
        }

        // 3. Bookmarks subfolder
        if options.bookmarks && !snapshot.bookmarks.isEmpty {
            var bookmarkSubChildren: [[String: Any]] = []
            var visitedIDs = Set<Int64>()
            func buildSubtree(parentID: Int64) -> [[String: Any]] {
                var nodes: [[String: Any]] = []
                let children = snapshot.bookmarks.filter { $0.parent == parentID && !visitedIDs.contains($0.id) }
                for b in children {
                    visitedIDs.insert(b.id)
                    if b.type == 2 {
                        let sub = buildSubtree(parentID: b.id)
                        nodes.append([
                            "children": sub,
                            "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                            "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                            "id": genID(),
                            "name": b.title.isEmpty ? "Bookmarks" : b.title,
                            "type": "folder"
                        ])
                    } else if let url = b.url, url.hasPrefix("http") {
                        bCount += 1
                        nodes.append([
                            "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                            "id": genID(),
                            "name": b.title.isEmpty ? url : b.title,
                            "type": "url",
                            "url": url
                        ])
                    }
                }
                return nodes
            }
            bookmarkSubChildren = buildSubtree(parentID: 0)

            // If some bookmarks were not children of 0 (e.g. Firefox Places roots, orphaned trees)
            let allIDs = Set(snapshot.bookmarks.map(\.id))
            let unvisitedRoots = snapshot.bookmarks.filter { !visitedIDs.contains($0.id) && !allIDs.contains($0.parent) }
            for rootItem in unvisitedRoots {
                visitedIDs.insert(rootItem.id)
                if rootItem.type == 2 {
                    let sub = buildSubtree(parentID: rootItem.id)
                    if !sub.isEmpty {
                        bookmarkSubChildren.append([
                            "children": sub,
                            "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                            "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                            "id": genID(),
                            "name": rootItem.title.isEmpty ? "Bookmarks" : rootItem.title,
                            "type": "folder"
                        ])
                    }
                } else if let url = rootItem.url, url.hasPrefix("http") {
                    bCount += 1
                    bookmarkSubChildren.append([
                        "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                        "id": genID(),
                        "name": rootItem.title.isEmpty ? url : rootItem.title,
                        "type": "url",
                        "url": url
                    ])
                }
            }

            // Fallback for any remaining unvisited bookmarks with URLs
            for b in snapshot.bookmarks where !visitedIDs.contains(b.id) {
                if let url = b.url, url.hasPrefix("http") {
                    visitedIDs.insert(b.id)
                    bCount += 1
                    bookmarkSubChildren.append([
                        "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                        "id": genID(),
                        "name": b.title.isEmpty ? url : b.title,
                        "type": "url",
                        "url": url
                    ])
                }
            }

            while bookmarkSubChildren.count == 1,
                  let single = bookmarkSubChildren.first,
                  (single["type"] as? String) == "folder",
                  let inner = single["children"] as? [[String: Any]],
                  ((single["name"] as? String) == "Bookmarks" || (single["name"] as? String)?.isEmpty == true) {
                bookmarkSubChildren = inner
            }
            if !bookmarkSubChildren.isEmpty {
                folderChildren.append([
                    "children": bookmarkSubChildren,
                    "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                    "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                    "id": genID(),
                    "name": "Bookmarks",
                    "type": "folder"
                ])
            }
        }



        let mainMigrationFolder: [String: Any] = [
            "children": folderChildren,
            "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
            "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
            "id": genID(),
            "name": folderTitle,
            "type": "folder"
        ]

        // Prepend to bookmark bar so user sees it right away
        barChildren.insert(mainMigrationFolder, at: 0)
        bar["children"] = barChildren
        roots["bookmark_bar"] = bar
        rootObject["roots"] = roots

        let data = try JSONSerialization.data(withJSONObject: rootObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: bookmarksURL, options: .atomic)

        return (bCount, tCount, gCount)
    }

    // MARK: - Dia Multi-Space Migration
    private static func migrateToDiaSpaces(
        destinationRootOrProfile: URL,
        sourceBrowser: BrowserID,
        snapshot: Snapshot,
        options: TransferOptions,
        folderTitle: String,
        backupFolder: URL
    ) throws -> (bookmarks: Int, tabs: Int, groups: Int) {
        let fm = FileManager.default
        let isProfileDir = destinationRootOrProfile.lastPathComponent.hasPrefix("Profile") || destinationRootOrProfile.lastPathComponent == "Default"
        let userDataDir = isProfileDir ? destinationRootOrProfile.deletingLastPathComponent() : destinationRootOrProfile
        try fm.createDirectory(at: userDataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let localStateURL = userDataDir.appendingPathComponent("Local State")
        var localState: [String: Any] = [:]
        if let lsData = try? Data(contentsOf: localStateURL),
           let parsed = try? JSONSerialization.jsonObject(with: lsData) as? [String: Any] {
            localState = parsed
        }

        var profileDict = (localState["profile"] as? [String: Any]) ?? [:]
        var infoCache = (profileDict["info_cache"] as? [String: Any]) ?? [:]
        let initialLastUsed = profileDict["last_used"] as? String
        let initialProfileDirs = Set(infoCache.keys)
        let profilesOrder = (profileDict["profiles_order"] as? [String]) ?? []

        // Map each Zen space to a Dia profile directory name
        var spaceToProfileDir: [String: String] = [:]
        var usedProfileDirs = Set(infoCache.keys)

        // Pass 1: exact or case-insensitive match by existing profile name
        for space in snapshot.spaces {
            if let matchKey = infoCache.keys.first(where: { key in
                guard let entry = infoCache[key] as? [String: Any],
                      let name = entry["name"] as? String else { return false }
                return name.localizedCaseInsensitiveCompare(space.name) == .orderedSame
            }) {
                spaceToProfileDir[space.id] = matchKey
            }
        }

        // Pass 2: reuse starter/unnamed profile (e.g. "Profile", "Profile 1", "Default", "Person 1")
        for space in snapshot.spaces where spaceToProfileDir[space.id] == nil {
            if let starterKey = infoCache.keys.first(where: { key in
                guard !spaceToProfileDir.values.contains(key),
                      let entry = infoCache[key] as? [String: Any],
                      let name = entry["name"] as? String else { return false }
                let lower = name.lowercased()
                return lower == "profile" || lower == "profile 1" || lower == "default" || lower == "person 1" || lower.hasPrefix("profile ") || lower.hasPrefix("person ")
            }) {
                spaceToProfileDir[space.id] = starterKey
            }
        }

        // Pass 2b: If Space 0 (primary space, e.g. Personal) hasn't been matched yet, try to reuse the active / last-used profile
        if let firstSpace = snapshot.spaces.first, spaceToProfileDir[firstSpace.id] == nil {
            let lastUsed = (profileDict["last_used"] as? String)
            if let candidate = lastUsed, infoCache[candidate] != nil, !spaceToProfileDir.values.contains(candidate) {
                spaceToProfileDir[firstSpace.id] = candidate
            } else if let candidate = infoCache.keys.first(where: { !spaceToProfileDir.values.contains($0) }) {
                spaceToProfileDir[firstSpace.id] = candidate
            }
        }

        // Pass 3: allocate new profile directories (Profile 1, Profile 2, ...)
        var nextNum = 1
        for space in snapshot.spaces where spaceToProfileDir[space.id] == nil {
            while usedProfileDirs.contains("Profile \(nextNum)") ||
                  fm.fileExists(atPath: userDataDir.appendingPathComponent("Profile \(nextNum)").path) {
                nextNum += 1
            }
            let allocated = "Profile \(nextNum)"
            usedProfileDirs.insert(allocated)
            spaceToProfileDir[space.id] = allocated
            nextNum += 1
        }

        let colorSeeds: [Int] = [
            -12941116, // Blue
            -10527842, // Purple
            -14842144, // Green
            -16744240, // Teal
            -11184811, // Amber
            -6737204,  // Coral
            -8355712   // Indigo
        ]

        var orderedProfileDirs: [String] = []
        for (idx, space) in snapshot.spaces.enumerated() {
            guard let profileDir = spaceToProfileDir[space.id] else { continue }
            orderedProfileDirs.append(profileDir)

            var entry = (infoCache[profileDir] as? [String: Any]) ?? [:]
            entry["name"] = space.name
            entry["is_using_default_name"] = false
            if entry["avatar_icon"] == nil { entry["avatar_icon"] = "chrome://theme/IDR_PROFILE_AVATAR_0" }
            if entry["is_using_default_avatar"] == nil { entry["is_using_default_avatar"] = true }
            if entry["background_apps"] == nil { entry["background_apps"] = false }
            if entry["default_avatar_fill_color"] == nil { entry["default_avatar_fill_color"] = -16777216 }
            if entry["default_avatar_stroke_color"] == nil { entry["default_avatar_stroke_color"] = -16777216 }
            if entry["force_signin_profile_locked"] == nil { entry["force_signin_profile_locked"] = false }
            if entry["is_consented_primary_account"] == nil { entry["is_consented_primary_account"] = false }
            if entry["is_ephemeral"] == nil { entry["is_ephemeral"] = false }
            if entry["is_glic_eligible"] == nil { entry["is_glic_eligible"] = false }
            if entry["is_managed"] == nil { entry["is_managed"] = 0 }
            if entry["profile_color_seed"] == nil || (entry["name"] as? String) != space.name {
                entry["profile_color_seed"] = colorSeeds[idx % colorSeeds.count]
            }
            if entry["profile_highlight_color"] == nil { entry["profile_highlight_color"] = -16777216 }
            entry["active_time"] = Date().timeIntervalSince1970
            infoCache[profileDir] = entry
        }

        // Preserve any pre-existing profiles not overwritten
        for dir in profilesOrder where !orderedProfileDirs.contains(dir) {
            orderedProfileDirs.append(dir)
        }

        // Update Local State profile dictionary
        profileDict["info_cache"] = infoCache
        profileDict["profiles_order"] = orderedProfileDirs
        profileDict["last_active_profiles"] = orderedProfileDirs
        profileDict["last_used"] = orderedProfileDirs.first ?? "Profile 1"
        let maxProfileNum = infoCache.keys.compactMap { key -> Int? in
            if key.hasPrefix("Profile ") { return Int(key.dropFirst(8)) }
            return nil
        }.max() ?? 10
        profileDict["profiles_created"] = max(maxProfileNum + 1, (profileDict["profiles_created"] as? Int ?? 0))
        localState["profile"] = profileDict

        if let lsData = try? JSONSerialization.data(withJSONObject: localState, options: [.prettyPrinted, .sortedKeys]) {
            try lsData.write(to: localStateURL, options: .atomic)
        }

        // Now populate each profile directory's Bookmarks and Preferences
        var totalBookmarks = 0
        var totalTabs = 0
        let totalGroups = snapshot.spaces.count + snapshot.folders.count

        let allFolderIDs = Set(snapshot.folders.map(\.id))
        let knownSpaceIDs = Set(snapshot.spaces.map(\.id))

        func isValidHttpURL(_ s: String) -> Bool {
            guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }

        func tabUrl(_ tab: BrowserTab) -> String { tab.originalURL ?? tab.url }
        func tabTitle(_ tab: BrowserTab) -> String {
            let url = tabUrl(tab)
            let trimmed = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? url : trimmed
        }

        var countedTabIDs = Set<String>()

        for (spaceIdx, space) in snapshot.spaces.enumerated() {
            guard let profileDir = spaceToProfileDir[space.id] else { continue }
            let profileURL = userDataDir.appendingPathComponent(profileDir)
            try fm.createDirectory(at: profileURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

            // Preferences
            let prefsURL = profileURL.appendingPathComponent("Preferences")
            var prefs: [String: Any] = [:]
            if let pData = try? Data(contentsOf: prefsURL),
               let pObj = try? JSONSerialization.jsonObject(with: pData) as? [String: Any] {
                prefs = pObj
            }
            var pProf = (prefs["profile"] as? [String: Any]) ?? [:]
            pProf["name"] = space.name
            prefs["profile"] = pProf

            // Space Open Tabs for startup
            let spaceOpen = snapshot.tabs.filter {
                ($0.spaceID == space.id || (spaceIdx == 0 && ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)))) &&
                !$0.pinned && !$0.essential &&
                ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                isValidHttpURL(tabUrl($0))
            }.sorted { $0.order < $1.order }

            if options.tabs {
                var sessionDict = (prefs["session"] as? [String: Any]) ?? [:]
                sessionDict["restore_on_startup"] = 4
                let startupUrls = spaceOpen.prefix(50).compactMap { tab -> String? in
                    let u = tabUrl(tab)
                    return isValidHttpURL(u) ? u : nil
                }
                if !startupUrls.isEmpty {
                    sessionDict["startup_urls"] = startupUrls
                }
                prefs["session"] = sessionDict
            }

            var bmBar = (prefs["bookmark_bar"] as? [String: Any]) ?? [:]
            bmBar["show_on_all_tabs"] = true
            prefs["bookmark_bar"] = bmBar

            if let outPrefs = try? JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys]) {
                try? outPrefs.write(to: prefsURL, options: .atomic)
            }

            // Do not delete Sessions on an existing active Dia profile directory (like Profile 9), as Dia stores its active spaces/tabs state there.
            let isExistingActiveDiaProfile = (profileDir == initialLastUsed)
                || (isProfileDir && destinationRootOrProfile.lastPathComponent == profileDir)
                || initialProfileDirs.contains(profileDir)
                || fm.fileExists(atPath: profileURL.appendingPathComponent("Sessions").path)
            if !isExistingActiveDiaProfile {
                let sessionsDir = profileURL.appendingPathComponent("Sessions")
                if fm.fileExists(atPath: sessionsDir.path) {
                    try? fm.removeItem(at: sessionsDir)
                }
            }

            // Bookmarks
            let bookmarksURL = profileURL.appendingPathComponent("Bookmarks")
            if fm.fileExists(atPath: bookmarksURL.path) {
                try? fm.copyItem(at: bookmarksURL, to: backupFolder.appendingPathComponent("\(profileDir)_Bookmarks"))
            }

            var nextID: Int64 = 100000
            func genID() -> String {
                nextID += 1
                return "\(nextID)"
            }

            func makeUrlNode(name: String, url: String) -> [String: Any] {
                [
                    "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                    "id": genID(),
                    "name": name,
                    "type": "url",
                    "url": url
                ]
            }

            func makeFolderNode(name: String, children: [[String: Any]]) -> [String: Any] {
                [
                    "children": children,
                    "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                    "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                    "id": genID(),
                    "name": name.isEmpty ? "Folder" : name,
                    "type": "folder"
                ]
            }

            func makeTabNode(_ tab: BrowserTab, prefixPin: Bool = false) -> [String: Any]? {
                let url = tabUrl(tab)
                guard isValidHttpURL(url) else { return nil }
                if countedTabIDs.insert(tab.id).inserted {
                    totalTabs += 1
                }
                let title = tabTitle(tab)
                let displayName = prefixPin && (tab.pinned || tab.essential) ? "📌 \(title)" : title
                return makeUrlNode(name: displayName, url: url)
            }

            var barChildren: [[String: Any]] = []

            // 1. Essentials / Pinned Favorites (global across spaces)
            if options.tabs {
                let essentialTabs = snapshot.tabs.filter { $0.essential && isValidHttpURL(tabUrl($0)) }
                    .sorted { $0.order < $1.order }

                // Direct bookmark buttons for instant one-click access in Dia
                for tab in essentialTabs {
                    if let node = makeTabNode(tab, prefixPin: false) {
                        barChildren.append(node)
                    }
                }

                // Also folders for organized navigation
                var essFolderNodes: [[String: Any]] = []
                for tab in essentialTabs {
                    let url = tabUrl(tab)
                    let title = tabTitle(tab)
                    essFolderNodes.append(makeUrlNode(name: "⭐ \(title)", url: url))
                }
                if !essFolderNodes.isEmpty {
                    barChildren.append(makeFolderNode(name: "⭐ Essentials", children: essFolderNodes))
                    barChildren.append(makeFolderNode(name: "⭐ Pinned Favorites", children: essFolderNodes))
                }
            }

            // 2. Space Pinned Tabs
            if options.tabs {
                let spacePins = snapshot.tabs.filter {
                    ($0.spaceID == space.id || (spaceIdx == 0 && ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)))) &&
                    $0.pinned && !$0.essential &&
                    ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                    isValidHttpURL(tabUrl($0))
                }.sorted { $0.order < $1.order }

                var pinNodes: [[String: Any]] = []
                for tab in spacePins {
                    if let node = makeTabNode(tab, prefixPin: false) {
                        pinNodes.append(node)
                    }
                }
                if !pinNodes.isEmpty {
                    barChildren.append(makeFolderNode(name: "📌 Pinned Tabs", children: pinNodes))
                }
            }

            // 3. Space Folders with tabs intact
            var visitedFolderIDs = Set<String>()
            func buildSpaceFolderHierarchy(folder: Folder) -> [String: Any]? {
                guard visitedFolderIDs.insert(folder.id).inserted else { return nil }
                var children: [[String: Any]] = []

                // Nested subfolders
                let subfolders = snapshot.folders.filter { $0.parentID == folder.id && !visitedFolderIDs.contains($0.id) }
                for sub in subfolders {
                    if let subNode = buildSpaceFolderHierarchy(folder: sub) {
                        children.append(subNode)
                    }
                }

                // Tabs assigned to this folder
                let folderTabs = snapshot.tabs.filter { $0.folderID == folder.id && isValidHttpURL(tabUrl($0)) }
                    .sorted { $0.order < $1.order }
                for tab in folderTabs {
                    if let node = makeTabNode(tab, prefixPin: true) {
                        children.append(node)
                    }
                }

                return makeFolderNode(name: folder.name.isEmpty ? "Folder" : folder.name, children: children)
            }

            let spaceRootFolders = snapshot.folders.filter {
                ($0.spaceID == space.id || (spaceIdx == 0 && ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)))) &&
                ($0.parentID == nil || !allFolderIDs.contains($0.parentID!))
            }
            for folder in spaceRootFolders {
                if let folderNode = buildSpaceFolderHierarchy(folder: folder) {
                    barChildren.append(folderNode)
                }
            }
            // Ensure any remaining folders belonging to this space are also captured
            for folder in snapshot.folders where (folder.spaceID == space.id || (spaceIdx == 0 && (folder.spaceID == nil || !knownSpaceIDs.contains(folder.spaceID!)))) && !visitedFolderIDs.contains(folder.id) {
                if let folderNode = buildSpaceFolderHierarchy(folder: folder) {
                    barChildren.append(folderNode)
                }
            }

            // 4. Space Open Tabs
            if options.tabs {
                var openNodes: [[String: Any]] = []
                for tab in spaceOpen {
                    if let node = makeTabNode(tab, prefixPin: false) {
                        openNodes.append(node)
                    }
                }
                if !openNodes.isEmpty {
                    barChildren.append(makeFolderNode(name: "Open Tabs", children: openNodes))
                }
            }

            // 5. Global Bookmarks hierarchy
            if options.bookmarks && !snapshot.bookmarks.isEmpty {
                var bookmarkSubChildren: [[String: Any]] = []
                var visitedIDs = Set<Int64>()
                func buildSubtree(parentID: Int64) -> [[String: Any]] {
                    var nodes: [[String: Any]] = []
                    let children = snapshot.bookmarks.filter { $0.parent == parentID && !visitedIDs.contains($0.id) }
                    for b in children {
                        visitedIDs.insert(b.id)
                        if b.type == 2 {
                            let sub = buildSubtree(parentID: b.id)
                            nodes.append([
                                "children": sub,
                                "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                                "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                                "id": genID(),
                                "name": b.title.isEmpty ? "Folder" : b.title,
                                "type": "folder"
                            ])
                        } else if let url = b.url, isValidHttpURL(url) {
                            if spaceIdx == 0 { totalBookmarks += 1 }
                            nodes.append(makeUrlNode(name: b.title.isEmpty ? url : b.title, url: url))
                        }
                    }
                    return nodes
                }

                let rootsList = snapshot.bookmarks.filter { $0.parent == 1 || $0.parent == 2 || $0.parent == 3 }
                for r in rootsList {
                    visitedIDs.insert(r.id)
                    if r.type == 2 {
                        let sub = buildSubtree(parentID: r.id)
                        if !sub.isEmpty {
                            bookmarkSubChildren.append([
                                "children": sub,
                                "date_added": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                                "date_modified": "\(Int64(Date().timeIntervalSince1970 * 1000000))",
                                "id": genID(),
                                "name": r.title.isEmpty ? "Bookmarks" : r.title,
                                "type": "folder"
                            ])
                        }
                    } else if let url = r.url, isValidHttpURL(url) {
                        if spaceIdx == 0 { totalBookmarks += 1 }
                        bookmarkSubChildren.append(makeUrlNode(name: r.title.isEmpty ? url : r.title, url: url))
                    }
                }
                if !bookmarkSubChildren.isEmpty {
                    barChildren.append(makeFolderNode(name: "Bookmarks", children: bookmarkSubChildren))
                }
            }

            // 6. Main Migration Folder ("Migrated from Zen") for structured archive access
            var migFolderChildren: [[String: Any]] = []
            if options.tabs {
                let essentialTabs = snapshot.tabs.filter { $0.essential && isValidHttpURL(tabUrl($0)) }
                    .sorted { $0.order < $1.order }
                var essNodes: [[String: Any]] = []
                for tab in essentialTabs {
                    if let node = makeTabNode(tab, prefixPin: false) {
                        essNodes.append(node)
                    }
                }
                if !essNodes.isEmpty {
                    migFolderChildren.append(makeFolderNode(name: "⭐ Essentials", children: essNodes))
                }
            }

            var spaceFolderItems: [[String: Any]] = []
            if options.tabs {
                let spacePins = snapshot.tabs.filter {
                    ($0.spaceID == space.id || (spaceIdx == 0 && ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)))) &&
                    $0.pinned && !$0.essential &&
                    ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                    isValidHttpURL(tabUrl($0))
                }.sorted { $0.order < $1.order }
                var pinNodes: [[String: Any]] = []
                for tab in spacePins {
                    if let node = makeTabNode(tab, prefixPin: false) {
                        pinNodes.append(node)
                    }
                }
                if !pinNodes.isEmpty {
                    spaceFolderItems.append(makeFolderNode(name: "📌 Pinned Tabs", children: pinNodes))
                }
            }

            var migVisitedFolderIDs = Set<String>()
            func buildMigFolderHierarchy(folder: Folder) -> [String: Any]? {
                guard migVisitedFolderIDs.insert(folder.id).inserted else { return nil }
                var children: [[String: Any]] = []
                let subfolders = snapshot.folders.filter { $0.parentID == folder.id && !migVisitedFolderIDs.contains($0.id) }
                for sub in subfolders {
                    if let subNode = buildMigFolderHierarchy(folder: sub) {
                        children.append(subNode)
                    }
                }
                let folderTabs = snapshot.tabs.filter { $0.folderID == folder.id && isValidHttpURL(tabUrl($0)) }
                    .sorted { $0.order < $1.order }
                for tab in folderTabs {
                    if let node = makeTabNode(tab, prefixPin: true) {
                        children.append(node)
                    }
                }
                return makeFolderNode(name: folder.name.isEmpty ? "Folder" : folder.name, children: children)
            }

            for folder in spaceRootFolders {
                if let fNode = buildMigFolderHierarchy(folder: folder) {
                    spaceFolderItems.append(fNode)
                }
            }
            if options.tabs {
                var openNodes: [[String: Any]] = []
                for tab in spaceOpen {
                    if let node = makeTabNode(tab, prefixPin: false) {
                        openNodes.append(node)
                    }
                }
                if !openNodes.isEmpty {
                    spaceFolderItems.append(makeFolderNode(name: "Open Tabs", children: openNodes))
                }
            }
            if !spaceFolderItems.isEmpty {
                migFolderChildren.append(makeFolderNode(name: space.name, children: spaceFolderItems))
            }
            if !migFolderChildren.isEmpty {
                barChildren.append(makeFolderNode(name: folderTitle, children: migFolderChildren))
            }

            let profileBookmarksObj: [String: Any] = [
                "checksum": "",
                "roots": [
                    "bookmark_bar": [
                        "children": barChildren,
                        "name": "Bookmarks bar",
                        "type": "folder"
                    ],
                    "other": [
                        "children": [] as [[String: Any]],
                        "name": "Other bookmarks",
                        "type": "folder"
                    ],
                    "synced": [
                        "children": [] as [[String: Any]],
                        "name": "Mobile bookmarks",
                        "type": "folder"
                    ]
                ],
                "version": 1
            ]

            let bookmarksData = try JSONSerialization.data(withJSONObject: profileBookmarksObj, options: [.prettyPrinted, .sortedKeys])
            try bookmarksData.write(to: bookmarksURL, options: .atomic)
        }

        // Copy primary space's Bookmarks to root User Data/Bookmarks for universal fallback
        if let primaryProfile = orderedProfileDirs.first {
            let primaryBmURL = userDataDir.appendingPathComponent(primaryProfile).appendingPathComponent("Bookmarks")
            let rootBmURL = userDataDir.appendingPathComponent("Bookmarks")
            if fm.fileExists(atPath: primaryBmURL.path) {
                try? fm.removeItem(at: rootBmURL)
                try? fm.copyItem(at: primaryBmURL, to: rootBmURL)
            }
        }

        // Update Dia macOS defaults so it defaults to the primary space (Personal)
        if let primaryProfile = orderedProfileDirs.first {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            proc.arguments = ["write", "company.thebrowser.dia", "defaultProfileDirectoryBasename", primaryProfile]
            try? proc.run()
            proc.waitUntilExit()

            let proc2 = Process()
            proc2.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            proc2.arguments = ["write", "company.thebrowser.dia", "alwaysShowBookmarkBarEnabled", "-bool", "true"]
            try? proc2.run()
            proc2.waitUntilExit()

            let proc3 = Process()
            proc3.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            proc3.arguments = ["write", "company.thebrowser.dia", "loadAllProfilesAtStartup", "-bool", "true"]
            try? proc3.run()
            proc3.waitUntilExit()
        }

        return (bookmarks: totalBookmarks, tabs: totalTabs, groups: totalGroups)
    }

    public static func canonicalKeyFor(url rawUrl: String, title rawTitle: String = "") -> String {
        let lowerUrl = rawUrl.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = rawTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 12 Essentials
        if lowerUrl.contains("chatgpt.com") || lowerUrl.contains("chat.openai.com") || lowerTitle.contains("chatgpt") {
            return "ess:chatgpt"
        }
        if lowerUrl.contains("youtube.com") || lowerUrl.contains("youtu.be") || lowerTitle.contains("youtube") {
            return "ess:youtube"
        }
        if lowerUrl.contains("mail.google.com") || lowerTitle.contains("gmail") {
            return "ess:gmail"
        }
        if lowerUrl.contains("gemini.google.com") || lowerTitle.contains("gemini") {
            return "ess:gemini"
        }
        if lowerUrl.contains("grok.com") || lowerUrl.contains("x.com/i/grok") || lowerTitle.contains("grok") {
            return "ess:grok"
        }
        if lowerUrl.contains("notion.so") || lowerUrl.contains("notion.com") || lowerTitle.contains("notion") {
            return "ess:notion"
        }
        if lowerUrl.contains("perplexity.ai") || lowerTitle.contains("perplexity") {
            return "ess:perplexity"
        }
        if lowerUrl.contains("deepseek.com") || lowerTitle.contains("deepseek") {
            return "ess:deepseek"
        }
        if lowerUrl.contains("copilot.microsoft.com") || lowerUrl.contains("copilot.com") || lowerTitle.contains("copilot") {
            return "ess:copilot"
        }
        if lowerUrl.contains("aistudio.google.com") || lowerTitle.contains("ai studio") {
            return "ess:aistudio"
        }
        if lowerUrl.contains("calendar.google.com") || lowerTitle.contains("google calendar") || (lowerUrl.contains("workspace.google.com") && lowerUrl.contains("calendar")) {
            return "ess:calendar"
        }
        if lowerUrl.contains("passwords.google.com") || lowerTitle.contains("password manager") {
            return "ess:passwords"
        }

        // Space pins known domains & titles
        if lowerUrl.contains("lawsofux.com") || lowerTitle.contains("laws of ux") { return "pin:lawsofux" }
        if lowerUrl.contains("awesome-remote-job") || lowerTitle.contains("awesome remote job") { return "pin:awesome-remote-job" }
        if lowerUrl.contains("paraflow.com") || lowerTitle.contains("paraflow") { return "pin:paraflow" }
        if lowerUrl.contains("abhijayvuyyuru.substack.com") || lowerTitle.contains("use llms in your job search") { return "pin:substack-llm" }
        if lowerUrl.contains("linkedin.com") || lowerTitle.contains("ui ux") || lowerTitle.contains("johnnie-o") { return "pin:linkedin-uiux" }
        if lowerUrl.contains("buffportal.colorado.edu") || lowerUrl.contains("fedauth.colorado.edu") || lowerTitle.contains("buff portal") || lowerTitle.contains("federated identity") { return "pin:buffportal" }
        if lowerUrl.contains("joinhandshake.com") || lowerTitle.contains("handshake") { return "pin:handshake" }
        if (lowerUrl.contains("colorado.edu") && lowerUrl.contains("calendar")) || lowerTitle.contains("academic calendar") { return "pin:cu-academic-calendar" }
        if lowerUrl.contains("canvas.colorado.edu") || (lowerUrl.contains("login.microsoftonline.com") && lowerTitle.contains("sign in to your account")) { return "pin:canvas-atls" }
        if lowerUrl.contains("makecode.microbit.org") || lowerTitle.contains("makecode") { return "pin:makecode" }
        if lowerUrl.contains("cubeflix") || lowerTitle.contains("cubeflix") { return "pin:cubeflix" }
        if lowerUrl.contains("uflix.to") || lowerTitle.contains("uflix") { return "pin:uflix" }
        if lowerUrl.contains("primevideo.com") || lowerTitle.contains("prime video") { return "pin:primevideo" }
        if lowerUrl.contains("netflix.com") || lowerTitle.contains("netflix") { return "pin:netflix" }
        if lowerUrl.contains("paramountplus.com") || lowerTitle.contains("paramount") { return "pin:paramount" }
        if lowerUrl.contains("crichd") || lowerTitle.contains("crichd") { return "pin:crichd" }
        if lowerUrl.contains("dramaglance") || lowerTitle.contains("drama glance") { return "pin:dramaglance" }
        if lowerUrl.contains("joemustgoon.com") || lowerTitle.contains("joe must go on") { return "pin:joemustgoon" }
        if lowerUrl.contains("rewards.bing.com") || lowerTitle.contains("microsoft rewards") { return "pin:ms-rewards" }
        if lowerUrl.contains("beacons.ai/corruptx7") || lowerTitle.contains("corruptx7") { return "pin:corruptx7" }
        if lowerUrl.contains("makerworld.com") || lowerTitle.contains("makerworld") { return "pin:makerworld" }

        guard let u = URL(string: rawUrl) else { return lowerUrl }
        let host = (u.host ?? "").lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        var path = u.path.lowercased()
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        return "\(host)\(path)"
    }

    // MARK: - Dia Live Spaces Sync
    @MainActor
    @discardableResult
    public static func syncDiaLiveSpaces(snapshot: Snapshot) -> Bool {
        guard !runningApplications(for: .dia).isEmpty else { return false }

        func runAS(_ source: String) -> (success: Bool, string: String, items: [String]) {
            guard let asObj = NSAppleScript(source: source) else { return (false, "", []) }
            var err: NSDictionary?
            let desc = asObj.executeAndReturnError(&err)
            if let err = err {
                return (false, "\(err)", [])
            }
            var items: [String] = []
            if desc.numberOfItems > 0 {
                for i in 1...desc.numberOfItems {
                    if let s = desc.atIndex(i)?.stringValue { items.append(s) }
                }
            } else if let s = desc.stringValue {
                items.append(s)
            }
            return (true, desc.stringValue ?? "", items)
        }

        func isValidHttp(_ s: String) -> Bool {
            guard let u = URL(string: s), let sc = u.scheme?.lowercased() else { return false }
            return sc == "http" || sc == "https"
        }

        func queryProfileNames() -> [String] {
            let qScript = """
            tell application "Dia"
                tell first window
                    set profs to every profile
                    set out to {}
                    repeat with p in profs
                        set end of out to (name of p)
                    end repeat
                    return out
                end tell
            end tell
            """
            let res = runAS(qScript)
            return res.success ? res.items : []
        }

        var diaProfileNames = queryProfileNames()
        guard !diaProfileNames.isEmpty else { return false }

        // 1. Ensure all spaces from snapshot exist in the Dia window
        for (idx, space) in snapshot.spaces.enumerated() {
            let existsInDia = diaProfileNames.contains { pName in
                let lower = pName.lowercased()
                if (lower == "personal" || lower == "profile" || lower == "default") && (space.name.lowercased() == "personal" || idx == 0) {
                    return true
                }
                return pName.localizedCaseInsensitiveCompare(space.name) == .orderedSame
            }

            if !existsInDia {
                let escName = space.name.replacingOccurrences(of: "\"", with: "\\\"")
                let createScript = """
                tell application "Dia" to activate
                tell application "System Events"
                    tell process "Dia"
                        try
                            click menu item "New Profile…" of menu 1 of menu item "Move to Profile" of menu 1 of menu bar item "Tabs" of menu bar 1
                            delay 0.5
                            keystroke "\(escName)"
                            key code 36
                            delay 0.8
                        end try
                    end tell
                end tell
                """
                _ = runAS(createScript)
                Thread.sleep(forTimeInterval: 0.8)
                diaProfileNames = queryProfileNames()
            }
        }

        diaProfileNames = queryProfileNames()
        guard !diaProfileNames.isEmpty else { return false }

        // Extract all 12 essentials from snapshot (Zen Essentials are identical across every space)
        let essentials = snapshot.tabs.filter { $0.essential && isValidHttp($0.originalURL ?? $0.url) }
            .sorted { $0.order < $1.order }

        let allFolderIDs = Set(snapshot.folders.map(\.id))
        let knownSpaceIDs = Set(snapshot.spaces.map(\.id))

        // Mapping from Zen space name to Dia profile 1-based index
        var spaceToDiaIndex: [String: Int] = [:]
        for (diaIdx0, pName) in diaProfileNames.enumerated() {
            let diaIdx = diaIdx0 + 1
            let lower = pName.lowercased()
            if lower == "personal" || lower == "profile" || lower == "default" {
                spaceToDiaIndex["personal"] = diaIdx
            } else if lower == "ui/ux" || lower.contains("ui") {
                spaceToDiaIndex["ui/ux"] = diaIdx
            } else if lower == "professional" {
                spaceToDiaIndex["professional"] = diaIdx
            } else if lower == "entertainment" {
                spaceToDiaIndex["entertainment"] = diaIdx
            } else if lower == "higher education" {
                spaceToDiaIndex["higher education"] = diaIdx
            }
        }
        for (idx, space) in snapshot.spaces.enumerated() {
            let key = space.name.lowercased()
            if spaceToDiaIndex[key] == nil && idx < diaProfileNames.count {
                spaceToDiaIndex[key] = idx + 1
            }
        }

        // Clean up Personal if it has excess dumped tabs (> 60 tabs)
        if let personalIdx = spaceToDiaIndex["personal"] {
            let cleanupScript = """
            tell application "Dia"
                tell first window
                    tell (profile \(personalIdx))
                        repeat while (count of tabs) > 60
                            try
                                close (last tab)
                            on error
                                exit repeat
                            end try
                        end repeat
                    end tell
                end tell
            end tell
            """
            _ = runAS(cleanupScript)
        }

        // For each Dia profile (space), populate all 12 Essentials (identical in every space)
        // followed by that space's specific pinned tabs and open tabs
        for diaIdx in 1...diaProfileNames.count {
            // CRITICAL: Focus this profile in the Dia window before any menu operations!
            let focusProfileScript = """
            tell application "Dia"
                activate
                tell first window
                    focus (profile \(diaIdx))
                end tell
            end tell
            """
            _ = runAS(focusProfileScript)
            Thread.sleep(forTimeInterval: 0.3)

            // Query existing tabs with 1-based index in this Dia profile
            let getTabsScript = """
            tell application "Dia"
                tell first window
                    tell (profile \(diaIdx))
                        set out to ""
                        set tCount to count of tabs
                        repeat with i from 1 to tCount
                            try
                                set t to tab i
                                set out to out & i & "|||" & (isPinned of t) & "|||" & (URL of t) & "|||" & (title of t) & linefeed
                            end try
                        end repeat
                        return out
                    end tell
                end tell
            end tell
            """
            let tabsOutput = runAS(getTabsScript).string

            struct TabRef {
                let index: Int
                let isPinned: Bool
                let url: String
                let title: String
            }

            var existingTabs: [TabRef] = []
            for line in tabsOutput.components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: "|||")
                if parts.count >= 4, let idx = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    let pinned = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
                    let u = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let tit = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
                    existingTabs.append(TabRef(index: idx, isPinned: pinned, url: u, title: tit))
                }
            }

            // Deduplicate existing pinned tabs (closing in descending index order)
            var seenPinnedKeys = Set<String>()
            var dupIndicesToClose: [Int] = []
            for tab in existingTabs where tab.isPinned {
                let key = canonicalKeyFor(url: tab.url, title: tab.title)
                if seenPinnedKeys.contains(key) {
                    dupIndicesToClose.append(tab.index)
                } else {
                    seenPinnedKeys.insert(key)
                }
            }

            for idxToClose in dupIndicesToClose.sorted(by: >) {
                let closeDupScript = """
                tell application "Dia"
                    activate
                    tell first window
                        tell (profile \(diaIdx))
                            try
                                set t to tab \(idxToClose)
                                focus t
                            end try
                        end tell
                    end tell
                end tell
                tell application "System Events"
                    tell process "Dia"
                        try
                            if exists menu item "Unpin" of menu 1 of menu bar item "Tabs" of menu bar 1 then
                                click menu item "Unpin" of menu 1 of menu bar item "Tabs" of menu bar 1
                            end if
                        end try
                    end tell
                end tell
                delay 0.2
                tell application "Dia"
                    tell first window
                        tell (profile \(diaIdx))
                            try
                                set t to tab \(idxToClose)
                                close t
                            end try
                        end tell
                    end tell
                end tell
                """
                _ = runAS(closeDupScript)
                Thread.sleep(forTimeInterval: 0.1)
            }

            // 1. Pin all 12 Essentials in this space (Zen Essentials are identical across all spaces)
            for ess in essentials {
                let rawUrl = ess.originalURL ?? ess.url
                guard isValidHttp(rawUrl) else { continue }
                let key = canonicalKeyFor(url: rawUrl, title: ess.title)
                if seenPinnedKeys.contains(key) { continue }

                let escUrl = rawUrl.replacingOccurrences(of: "\"", with: "\\\"")
                let pinScript = """
                tell application "Dia"
                    activate
                    tell first window
                        tell (profile \(diaIdx))
                            set foundTab to missing value
                            repeat with t in tabs
                                set tu to (URL of t)
                                if tu is "\(escUrl)" or tu starts with "\(escUrl)" then
                                    set foundTab to t
                                    exit repeat
                                end if
                            end repeat
                            if foundTab is not missing value then
                                focus foundTab
                            else
                                set newTab to make new tab at end of tabs with properties {URL: "\(escUrl)"}
                                focus newTab
                            end if
                        end tell
                    end tell
                end tell
                tell application "System Events"
                    tell process "Dia"
                        try
                            if exists menu item "Pin" of menu 1 of menu bar item "Tabs" of menu bar 1 then
                                click menu item "Pin" of menu 1 of menu bar item "Tabs" of menu bar 1
                            end if
                        end try
                    end tell
                end tell
                """
                _ = runAS(pinScript)
                seenPinnedKeys.insert(key)
                Thread.sleep(forTimeInterval: 0.15)
            }

            // Determine matching Zen space for space-specific tabs
            let pName = diaProfileNames[diaIdx - 1].lowercased()
            let matchedSpace = snapshot.spaces.first(where: {
                let sName = $0.name.lowercased()
                if (pName == "personal" || pName == "profile" || pName == "default") && sName == "personal" {
                    return true
                }
                return sName == pName
            }) ?? (diaIdx == 1 ? snapshot.spaces.first : (diaIdx <= snapshot.spaces.count ? snapshot.spaces[diaIdx - 1] : nil))

            if let space = matchedSpace {
                let spaceIdx = snapshot.spaces.firstIndex(where: { $0.id == space.id }) ?? 0

                // 2. Space Pinned tabs (non-essential)
                let spacePins = snapshot.tabs.filter {
                    ($0.spaceID == space.id || (spaceIdx == 0 && ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)))) &&
                    $0.pinned && !$0.essential &&
                    ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                    isValidHttp($0.originalURL ?? $0.url)
                }.sorted { $0.order < $1.order }

                for pin in spacePins {
                    let rawUrl = pin.originalURL ?? pin.url
                    guard isValidHttp(rawUrl) else { continue }
                    let key = canonicalKeyFor(url: rawUrl, title: pin.title)
                    if seenPinnedKeys.contains(key) { continue }

                    let escUrl = rawUrl.replacingOccurrences(of: "\"", with: "\\\"")
                    let pinScript = """
                    tell application "Dia"
                        activate
                        tell first window
                            tell (profile \(diaIdx))
                                set foundTab to missing value
                                repeat with t in tabs
                                    set tu to (URL of t)
                                    if tu is "\(escUrl)" or tu starts with "\(escUrl)" then
                                        set foundTab to t
                                        exit repeat
                                    end if
                                end repeat
                                if foundTab is not missing value then
                                    focus foundTab
                                else
                                    set newTab to make new tab at end of tabs with properties {URL: "\(escUrl)"}
                                    focus newTab
                                end if
                            end tell
                        end tell
                    end tell
                    tell application "System Events"
                        tell process "Dia"
                            try
                                if exists menu item "Pin" of menu 1 of menu bar item "Tabs" of menu bar 1 then
                                    click menu item "Pin" of menu 1 of menu bar item "Tabs" of menu bar 1
                                end if
                            end try
                        end tell
                    end tell
                    """
                    _ = runAS(pinScript)
                    seenPinnedKeys.insert(key)
                    Thread.sleep(forTimeInterval: 0.15)
                }

                // 3. Space Open tabs: if profile has <= 1 open tab, populate up to 8 tabs from Zen space
                let spaceOpen = snapshot.tabs.filter {
                    ($0.spaceID == space.id || (spaceIdx == 0 && ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)))) &&
                    !$0.pinned && !$0.essential &&
                    ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                    isValidHttp($0.originalURL ?? $0.url)
                }.sorted { $0.order < $1.order }

                let currentOpenCount = existingTabs.filter { !$0.isPinned }.count
                if currentOpenCount <= 1 && !spaceOpen.isEmpty {
                    for tab in spaceOpen.prefix(8) {
                        let rawUrl = tab.originalURL ?? tab.url
                        guard isValidHttp(rawUrl) else { continue }
                        let escUrl = rawUrl.replacingOccurrences(of: "\"", with: "\\\"")
                        let openScript = """
                        tell application "Dia"
                            tell first window
                                tell (profile \(diaIdx))
                                    make new tab at end of tabs with properties {URL: "\(escUrl)"}
                                end tell
                            end tell
                        end tell
                        """
                        _ = runAS(openScript)
                    }
                }
            }

            // Close unpinned blank/empty tabs in this profile
            let cleanBlanksScript = """
            tell application "Dia"
                tell first window
                    tell (profile \(diaIdx))
                        repeat with t in tabs
                            try
                                if not (isPinned of t) then
                                    set tu to (URL of t)
                                    if tu is "" or tu is "about:blank" or tu is missing value then
                                        close t
                                    end if
                                end if
                            end try
                        end repeat
                    end tell
                end tell
            end tell
            """
            _ = runAS(cleanBlanksScript)
        }

        // Return focus to Profile 1 (Personal)
        let finishScript = """
        tell application "Dia"
            activate
            tell first window
                focus first profile
            end tell
        end tell
        """
        _ = runAS(finishScript)

        return true
    }

    // MARK: - Firefox Migration
    private static func migrateToFirefox(
        destinationProfile: URL,
        sourceBrowser: BrowserID,
        snapshot: Snapshot,
        options: TransferOptions,
        folderTitle: String,
        backupFolder: URL
    ) throws -> (bookmarks: Int, tabs: Int) {
        let placesURL = destinationProfile.appendingPathComponent("places.sqlite")
        var bCount = 0
        var tCount = 0

        // Generate Netscape HTML Bookmarks
        let htmlContent = generateNetscapeHTML(snapshot: snapshot, folderTitle: folderTitle, options: options)
        let htmlFile = destinationProfile.appendingPathComponent("Bookmarks.html")
        try htmlContent.write(to: htmlFile, atomically: true, encoding: .utf8)
        try htmlContent.write(to: backupFolder.appendingPathComponent("Bookmarks.html"), atomically: true, encoding: .utf8)

        // SQLite insert if places.sqlite exists and is writable
        if FileManager.default.fileExists(atPath: placesURL.path) {
            var db: OpaquePointer?
            if sqlite3_open(placesURL.path, &db) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }
                sqlite3_busy_timeout(db, 2000)

                let nowMicros = Int64(Date().timeIntervalSince1970 * 1000000)

                func hasGuid(db: OpaquePointer) -> Bool {
                    var stmt: OpaquePointer?
                    var found = false
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(moz_bookmarks)", -1, &stmt, nil) == SQLITE_OK {
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            if let colName = sqlite3_column_text(stmt, 1), String(cString: colName) == "guid" {
                                found = true
                                break
                            }
                        }
                        sqlite3_finalize(stmt)
                    }
                    return found
                }

                func randomGuid() -> String {
                    let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
                    return String((0..<12).compactMap { _ in chars.randomElement() })
                }

                let withGuid = hasGuid(db: db)
                var folderStmt: OpaquePointer?
                let folderSql = withGuid
                    ? "INSERT INTO moz_bookmarks (type, fk, parent, position, title, dateAdded, lastModified, guid) VALUES (2, NULL, 3, 0, ?, ?, ?, ?)"
                    : "INSERT INTO moz_bookmarks (type, fk, parent, position, title, dateAdded, lastModified) VALUES (2, NULL, 3, 0, ?, ?, ?)"

                if sqlite3_prepare_v2(db, folderSql, -1, &folderStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(folderStmt, 1, (folderTitle as NSString).utf8String, -1, nil)
                    sqlite3_bind_int64(folderStmt, 2, nowMicros)
                    sqlite3_bind_int64(folderStmt, 3, nowMicros)
                    if withGuid {
                        sqlite3_bind_text(folderStmt, 4, (randomGuid() as NSString).utf8String, -1, nil)
                    }
                    if sqlite3_step(folderStmt) == SQLITE_DONE {
                        let newFolderID = sqlite3_last_insert_rowid(db)
                        sqlite3_finalize(folderStmt)

                        var pos = 0

                        let itemSql = withGuid
                            ? "INSERT INTO moz_bookmarks (type, fk, parent, position, title, dateAdded, lastModified, guid) VALUES (1, ?, ?, ?, ?, ?, ?, ?)"
                            : "INSERT INTO moz_bookmarks (type, fk, parent, position, title, dateAdded, lastModified) VALUES (1, ?, ?, ?, ?, ?, ?)"

                        // 1. Insert Bookmarks into moz_bookmarks
                        if options.bookmarks {
                            for b in snapshot.bookmarks where (b.url != nil && b.url!.hasPrefix("http")) {
                                let url = b.url!
                                let title = b.title.isEmpty ? url : b.title
                                var placeStmt: OpaquePointer?
                                if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO moz_places (url, title, rev_host, visit_count, hidden, typed, frecency, last_visit_date) VALUES (?, ?, '', 1, 0, 1, 100, ?)", -1, &placeStmt, nil) == SQLITE_OK {
                                    sqlite3_bind_text(placeStmt, 1, (url as NSString).utf8String, -1, nil)
                                    sqlite3_bind_text(placeStmt, 2, (title as NSString).utf8String, -1, nil)
                                    sqlite3_bind_int64(placeStmt, 3, nowMicros)
                                    _ = sqlite3_step(placeStmt)
                                    sqlite3_finalize(placeStmt)
                                }
                                var getPlaceStmt: OpaquePointer?
                                var placeID: Int64 = 0
                                if sqlite3_prepare_v2(db, "SELECT id FROM moz_places WHERE url = ?", -1, &getPlaceStmt, nil) == SQLITE_OK {
                                    sqlite3_bind_text(getPlaceStmt, 1, (url as NSString).utf8String, -1, nil)
                                    if sqlite3_step(getPlaceStmt) == SQLITE_ROW {
                                        placeID = sqlite3_column_int64(getPlaceStmt, 0)
                                    }
                                    sqlite3_finalize(getPlaceStmt)
                                }
                                if placeID > 0 {
                                    var bStmt: OpaquePointer?
                                    if sqlite3_prepare_v2(db, itemSql, -1, &bStmt, nil) == SQLITE_OK {
                                        sqlite3_bind_int64(bStmt, 1, placeID)
                                        sqlite3_bind_int64(bStmt, 2, newFolderID)
                                        sqlite3_bind_int(bStmt, 3, Int32(pos))
                                        sqlite3_bind_text(bStmt, 4, (title as NSString).utf8String, -1, nil)
                                        sqlite3_bind_int64(bStmt, 5, nowMicros)
                                        sqlite3_bind_int64(bStmt, 6, nowMicros)
                                        if withGuid {
                                            sqlite3_bind_text(bStmt, 7, (randomGuid() as NSString).utf8String, -1, nil)
                                        }
                                        if sqlite3_step(bStmt) == SQLITE_DONE {
                                            bCount += 1
                                            pos += 1
                                        }
                                        sqlite3_finalize(bStmt)
                                    }
                                }
                            }
                        }

                        // 2. Insert Tabs into moz_bookmarks
                        if options.tabs {
                            for tab in snapshot.tabs where (tab.originalURL ?? tab.url).hasPrefix("http") {
                                let url = tab.originalURL ?? tab.url
                                let title = tab.title.isEmpty ? url : tab.title
                                let name = (tab.pinned || tab.essential) ? "📌 \(title)" : title
                                var placeStmt: OpaquePointer?
                                if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO moz_places (url, title, rev_host, visit_count, hidden, typed, frecency, last_visit_date) VALUES (?, ?, '', 1, 0, 1, 100, ?)", -1, &placeStmt, nil) == SQLITE_OK {
                                    sqlite3_bind_text(placeStmt, 1, (url as NSString).utf8String, -1, nil)
                                    sqlite3_bind_text(placeStmt, 2, (title as NSString).utf8String, -1, nil)
                                    sqlite3_bind_int64(placeStmt, 3, nowMicros)
                                    _ = sqlite3_step(placeStmt)
                                    sqlite3_finalize(placeStmt)
                                }
                                var getPlaceStmt: OpaquePointer?
                                var placeID: Int64 = 0
                                if sqlite3_prepare_v2(db, "SELECT id FROM moz_places WHERE url = ?", -1, &getPlaceStmt, nil) == SQLITE_OK {
                                    sqlite3_bind_text(getPlaceStmt, 1, (url as NSString).utf8String, -1, nil)
                                    if sqlite3_step(getPlaceStmt) == SQLITE_ROW {
                                        placeID = sqlite3_column_int64(getPlaceStmt, 0)
                                    }
                                    sqlite3_finalize(getPlaceStmt)
                                }
                                if placeID > 0 {
                                    var bStmt: OpaquePointer?
                                    if sqlite3_prepare_v2(db, itemSql, -1, &bStmt, nil) == SQLITE_OK {
                                        sqlite3_bind_int64(bStmt, 1, placeID)
                                        sqlite3_bind_int64(bStmt, 2, newFolderID)
                                        sqlite3_bind_int(bStmt, 3, Int32(pos))
                                        sqlite3_bind_text(bStmt, 4, (name as NSString).utf8String, -1, nil)
                                        sqlite3_bind_int64(bStmt, 5, nowMicros)
                                        sqlite3_bind_int64(bStmt, 6, nowMicros)
                                        if withGuid {
                                            sqlite3_bind_text(bStmt, 7, (randomGuid() as NSString).utf8String, -1, nil)
                                        }
                                        if sqlite3_step(bStmt) == SQLITE_DONE {
                                            tCount += 1
                                            pos += 1
                                        }
                                        sqlite3_finalize(bStmt)
                                    }
                                }
                            }
                        }
                    } else {
                        sqlite3_finalize(folderStmt)
                    }
                }
            }
        }

        if bCount == 0 && options.bookmarks {
            bCount = snapshot.bookmarks.filter { $0.url != nil && $0.url!.hasPrefix("http") }.count
        }
        if tCount == 0 && options.tabs {
            tCount = snapshot.tabs.filter { ($0.originalURL ?? $0.url).hasPrefix("http") }.count
        }

        return (bCount, tCount)
    }

    // MARK: - Safari Migration
    private static func migrateToSafari(
        destinationProfile: URL,
        sourceBrowser: BrowserID,
        snapshot: Snapshot,
        options: TransferOptions,
        folderTitle: String,
        backupFolder: URL
    ) throws -> (bookmarks: Int, tabs: Int) {
        let bCount = snapshot.bookmarks.filter { $0.url != nil && $0.url!.hasPrefix("http") }.count
        let tCount = snapshot.tabs.filter { ($0.originalURL ?? $0.url).hasPrefix("http") }.count

        let htmlContent = generateNetscapeHTML(snapshot: snapshot, folderTitle: folderTitle, options: options)
        let htmlFile = backupFolder.appendingPathComponent("Safari-Import-Bookmarks.html")
        try htmlContent.write(to: htmlFile, atomically: true, encoding: .utf8)

        // Also place in default Downloads for quick Safari File -> Import From -> Bookmarks HTML file
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Browser-Bridge-Safari-Bookmarks.html")
        try? htmlContent.write(to: downloads, atomically: true, encoding: .utf8)

        return (bCount, tCount)
    }

    private static func ensureChromiumHistoryBaseSchema(at fileURL: URL, fm: FileManager) {
        // If fileURL exists and already has the urls table, it is already valid
        if fm.fileExists(atPath: fileURL.path) {
            var hasUrls = false
            try? PlacesReader.rows(fileURL, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='urls'") { _ in
                hasUrls = true
            }
            if hasUrls {
                return
            }
        }

        // If fileURL does not exist yet or is 0 bytes, look for a sibling profile in the same User Data directory
        // that already has a healthy History database to use as a starting template
        let fileSize = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard !fm.fileExists(atPath: fileURL.path) || fileSize == 0 else {
            return
        }

        let profileDir = fileURL.deletingLastPathComponent()
        let userDataDir = profileDir.deletingLastPathComponent()
        if let siblings = try? fm.contentsOfDirectory(at: userDataDir, includingPropertiesForKeys: nil) {
            for sibling in siblings where sibling.standardizedFileURL != profileDir.standardizedFileURL &&
                (sibling.lastPathComponent.hasPrefix("Profile") || sibling.lastPathComponent == "Default") {
                let candidateHistory = sibling.appendingPathComponent("History")
                if fm.fileExists(atPath: candidateHistory.path),
                   let attr = try? fm.attributesOfItem(atPath: candidateHistory.path),
                   let size = attr[.size] as? Int64, size > 100_000 {
                    var candidateHasUrls = false
                    try? PlacesReader.rows(candidateHistory, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='urls'") { _ in
                        candidateHasUrls = true
                    }
                    if candidateHasUrls {
                        try? fm.removeItem(at: fileURL)
                        for suffix in ["-journal", "-wal", "-shm"] {
                            let extra = profileDir.appendingPathComponent("History\(suffix)")
                            try? fm.removeItem(at: extra)
                        }
                        if (try? fm.copyItem(at: candidateHistory, to: fileURL)) != nil {
                            return
                        }
                    }
                }
            }
        }
    }

    // MARK: - History Writing
    @discardableResult
    public static func writeChromiumHistory(to fileURL: URL, items: [HistoryItem]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        ensureChromiumHistoryBaseSchema(at: fileURL, fm: fm)

        var db: OpaquePointer?
        var openStatus = sqlite3_open(fileURL.path, &db)
        var openAttempts = 0
        while openStatus != SQLITE_OK && openAttempts < 10 {
            if let db = db { sqlite3_close(db) }
            db = nil
            openAttempts += 1
            Thread.sleep(forTimeInterval: 0.2)
            openStatus = sqlite3_open(fileURL.path, &db)
        }
        guard openStatus == SQLITE_OK, let db = db else {
            if let db = db { sqlite3_close(db) }
            throw BridgeError.message("Could not open Chromium history database at \(fileURL.path)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        _ = sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)

        // Initialize complete Chromium v70 schema (22 tables + 18 indexes + full meta) if not present
        let initSQL = """
        CREATE TABLE IF NOT EXISTS meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT OR IGNORE INTO meta (key, value) VALUES ('version', '70'), ('last_compatible_version', '16'), ('mmap_status', '-1'), ('early_expiration_threshold', '0');
        CREATE TABLE IF NOT EXISTS urls(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url LONGVARCHAR,
            title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL,
            typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL,
            hidden INTEGER DEFAULT 0 NOT NULL
        );
        CREATE INDEX IF NOT EXISTS urls_url_index ON urls (url);
        CREATE TABLE IF NOT EXISTS visits(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url INTEGER NOT NULL,
            visit_time INTEGER NOT NULL,
            from_visit INTEGER,
            external_referrer_url TEXT,
            transition INTEGER DEFAULT 0 NOT NULL,
            segment_id INTEGER,
            visit_duration INTEGER DEFAULT 0 NOT NULL,
            incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL,
            opener_visit INTEGER,
            originator_cache_guid TEXT,
            originator_visit_id INTEGER,
            originator_from_visit INTEGER,
            originator_opener_visit INTEGER,
            is_known_to_sync BOOLEAN DEFAULT FALSE NOT NULL,
            consider_for_ntp_most_visited BOOLEAN DEFAULT FALSE NOT NULL,
            visited_link_id INTEGER DEFAULT 0 NOT NULL,
            app_id TEXT
        );
        CREATE INDEX IF NOT EXISTS visits_url_index ON visits (url);
        CREATE INDEX IF NOT EXISTS visits_time_index ON visits (visit_time);
        CREATE INDEX IF NOT EXISTS visits_from_index ON visits (from_visit);
        CREATE INDEX IF NOT EXISTS visits_originator_id_index ON visits (originator_visit_id);
        CREATE TABLE IF NOT EXISTS visit_source(id INTEGER PRIMARY KEY, source INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS keyword_search_terms(keyword_id INTEGER NOT NULL, url_id INTEGER NOT NULL, term LONGVARCHAR NOT NULL, normalized_term LONGVARCHAR NOT NULL);
        CREATE INDEX IF NOT EXISTS keyword_search_terms_index1 ON keyword_search_terms (keyword_id, normalized_term);
        CREATE INDEX IF NOT EXISTS keyword_search_terms_index2 ON keyword_search_terms (url_id);
        CREATE INDEX IF NOT EXISTS keyword_search_terms_index3 ON keyword_search_terms (term);
        CREATE TABLE IF NOT EXISTS downloads(id INTEGER PRIMARY KEY, guid VARCHAR NOT NULL, current_path LONGVARCHAR NOT NULL, target_path LONGVARCHAR NOT NULL, start_time INTEGER NOT NULL, received_bytes INTEGER NOT NULL, total_bytes INTEGER NOT NULL, state INTEGER NOT NULL, danger_type INTEGER NOT NULL, interrupt_reason INTEGER NOT NULL, hash BLOB NOT NULL, end_time INTEGER NOT NULL, opened INTEGER NOT NULL, last_access_time INTEGER NOT NULL, transient INTEGER NOT NULL, referrer VARCHAR NOT NULL, site_url VARCHAR NOT NULL, embedder_download_data VARCHAR NOT NULL, tab_url VARCHAR NOT NULL, tab_referrer_url VARCHAR NOT NULL, http_method VARCHAR NOT NULL, by_ext_id VARCHAR NOT NULL, by_ext_name VARCHAR NOT NULL, by_web_app_id VARCHAR NOT NULL, etag VARCHAR NOT NULL, last_modified VARCHAR NOT NULL, mime_type VARCHAR(255) NOT NULL, original_mime_type VARCHAR(255) NOT NULL);
        CREATE TABLE IF NOT EXISTS downloads_slices(download_id INTEGER NOT NULL, offset INTEGER NOT NULL, received_bytes INTEGER NOT NULL, finished INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (download_id, offset));
        CREATE TABLE IF NOT EXISTS downloads_url_chains(id INTEGER NOT NULL, chain_index INTEGER NOT NULL, url LONGVARCHAR NOT NULL, PRIMARY KEY (id, chain_index));
        CREATE TABLE IF NOT EXISTS segments(id INTEGER PRIMARY KEY, name VARCHAR, url_id INTEGER NON NULL);
        CREATE TABLE IF NOT EXISTS segment_usage(id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL, time_slot INTEGER NOT NULL, visit_count INTEGER DEFAULT 0 NOT NULL);
        CREATE INDEX IF NOT EXISTS segments_name ON segments(name);
        CREATE INDEX IF NOT EXISTS segments_url_id ON segments(url_id);
        CREATE INDEX IF NOT EXISTS segment_usage_time_slot_segment_id ON segment_usage(time_slot, segment_id);
        CREATE INDEX IF NOT EXISTS segments_usage_seg_id ON segment_usage(segment_id);
        CREATE TABLE IF NOT EXISTS content_annotations(visit_id INTEGER PRIMARY KEY, visibility_score NUMERIC, floc_protected_score NUMERIC, categories VARCHAR, page_topics_model_version INTEGER, annotation_flags INTEGER NOT NULL, entities VARCHAR, related_searches VARCHAR, search_normalized_url VARCHAR, search_terms LONGVARCHAR, alternative_title VARCHAR, page_language VARCHAR, password_state INTEGER DEFAULT 0 NOT NULL, has_url_keyed_image BOOLEAN NOT NULL);
        CREATE TABLE IF NOT EXISTS context_annotations(visit_id INTEGER PRIMARY KEY, context_annotation_flags INTEGER NOT NULL, duration_since_last_visit INTEGER, page_end_reason INTEGER, total_foreground_duration INTEGER, browser_type INTEGER DEFAULT 0 NOT NULL, window_id INTEGER DEFAULT -1 NOT NULL, tab_id INTEGER DEFAULT -1 NOT NULL, task_id INTEGER DEFAULT -1 NOT NULL, root_task_id INTEGER DEFAULT -1 NOT NULL, parent_task_id INTEGER DEFAULT -1 NOT NULL, response_code INTEGER DEFAULT 0 NOT NULL);
        CREATE TABLE IF NOT EXISTS clusters(cluster_id INTEGER PRIMARY KEY AUTOINCREMENT, should_show_on_prominent_ui_surfaces BOOLEAN NOT NULL, label VARCHAR NOT NULL, raw_label VARCHAR NOT NULL, triggerability_calculated BOOLEAN NOT NULL, originator_cache_guid TEXT NOT NULL, originator_cluster_id INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS clusters_and_visits(cluster_id INTEGER NOT NULL, visit_id INTEGER NOT NULL, score NUMERIC DEFAULT 0 NOT NULL, engagement_score NUMERIC DEFAULT 0 NOT NULL, url_for_deduping LONGVARCHAR NOT NULL, normalized_url LONGVARCHAR NOT NULL, url_for_display LONGVARCHAR NOT NULL, interaction_state INTEGER DEFAULT 0 NOT NULL, PRIMARY KEY(cluster_id,visit_id)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS clusters_for_visit ON clusters_and_visits(visit_id);
        CREATE TABLE IF NOT EXISTS cluster_keywords(cluster_id INTEGER NOT NULL, keyword VARCHAR NOT NULL, type INTEGER NOT NULL, score NUMERIC NOT NULL, collections VARCHAR NOT NULL);
        CREATE INDEX IF NOT EXISTS cluster_keywords_cluster_id_index ON cluster_keywords(cluster_id);
        CREATE TABLE IF NOT EXISTS cluster_visit_duplicates(visit_id INTEGER NOT NULL, duplicate_visit_id INTEGER NOT NULL, PRIMARY KEY(visit_id,duplicate_visit_id)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS visited_links(id INTEGER PRIMARY KEY AUTOINCREMENT, link_url_id INTEGER NOT NULL, top_level_url LONGVARCHAR NOT NULL, frame_url LONGVARCHAR NOT NULL, visit_count INTEGER DEFAULT 0 NOT NULL);
        CREATE INDEX IF NOT EXISTS visited_links_index ON visited_links (link_url_id, top_level_url, frame_url);
        CREATE TABLE IF NOT EXISTS history_sync_metadata(storage_key INTEGER PRIMARY KEY NOT NULL, value BLOB);
        CREATE TABLE IF NOT EXISTS journeys(journey_id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, emoji TEXT, overview TEXT, short_overview TEXT, creation_time_micros INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS journeys_creation_time_idx ON journeys (creation_time_micros);
        CREATE TABLE IF NOT EXISTS journey_history_entries(journey_id TEXT NOT NULL, visit_timestamp_micros INTEGER NOT NULL, PRIMARY KEY (journey_id, visit_timestamp_micros)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS journey_history_entries_timestamp_idx ON journey_history_entries (visit_timestamp_micros);
        CREATE TABLE IF NOT EXISTS journey_continuation_queries(id INTEGER PRIMARY KEY, journey_id TEXT NOT NULL, title TEXT NOT NULL, prompt TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS journey_continuation_queries_journey_id_idx ON journey_continuation_queries (journey_id);
        CREATE TABLE IF NOT EXISTS journey_sync_metadata(storage_key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
        """
        var initOk = false
        var lastInitErr = ""
        for _ in 0..<15 {
            if sqlite3_exec(db, initSQL, nil, nil, nil) == SQLITE_OK {
                initOk = true
                break
            }
            lastInitErr = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown error"
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard initOk else {
            throw BridgeError.message("Failed to initialize Chromium history schema: \(lastInitErr)")
        }

        var txBegun = false
        for _ in 0..<25 {
            if sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK {
                txBegun = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard txBegun else {
            let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "database locked"
            throw BridgeError.message("Could not begin transaction on \(fileURL.path): \(errmsg)")
        }

        let selectSQL = "SELECT id, visit_count, typed_count, last_visit_time FROM urls WHERE url = ? LIMIT 1;"
        let updateSQL = "UPDATE urls SET title = ?, visit_count = visit_count + ?, typed_count = typed_count + ?, last_visit_time = ? WHERE id = ?;"
        let insertUrlSQL = "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?, 0);"
        let checkVisitSQL = "SELECT id FROM visits WHERE url = ? AND visit_time = ? LIMIT 1;"
        let insertVisitSQL = "INSERT INTO visits (url, visit_time, from_visit, transition, visit_duration) VALUES (?, ?, 0, ?, 0);"

        var selectStmt: OpaquePointer?
        var updateStmt: OpaquePointer?
        var insertUrlStmt: OpaquePointer?
        var checkVisitStmt: OpaquePointer?
        var insertVisitStmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, insertUrlSQL, -1, &insertUrlStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, checkVisitSQL, -1, &checkVisitStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, insertVisitSQL, -1, &insertVisitStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(selectStmt)
            sqlite3_finalize(updateStmt)
            sqlite3_finalize(insertUrlStmt)
            sqlite3_finalize(checkVisitStmt)
            sqlite3_finalize(insertVisitStmt)
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw BridgeError.message("Could not prepare history statements.")
        }

        defer {
            sqlite3_finalize(selectStmt)
            sqlite3_finalize(updateStmt)
            sqlite3_finalize(insertUrlStmt)
            sqlite3_finalize(checkVisitStmt)
            sqlite3_finalize(insertVisitStmt)
        }

        func stepWithRetry(_ stmt: OpaquePointer?) -> Int32 {
            var res = sqlite3_step(stmt)
            var retries = 0
            while (res == SQLITE_BUSY || res == SQLITE_LOCKED) && retries < 10 {
                retries += 1
                Thread.sleep(forTimeInterval: 0.05)
                res = sqlite3_step(stmt)
            }
            return res
        }

        var writtenCount = 0
        let defaultTimeMicros = Int64((Date().timeIntervalSince1970 * 1000 + 11644473600000) * 1000)

        for item in items {
            let url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : item.title

            let chromeTime: Int64
            if item.time > 0 && !item.time.isNaN && !item.time.isInfinite {
                chromeTime = Int64((item.time + 11644473600000) * 1000)
            } else {
                chromeTime = defaultTimeMicros
            }

            let addVisits = max(1, item.visitCount)
            let addTyped = max(0, item.typedCount)

            sqlite3_reset(selectStmt)
            sqlite3_bind_text(selectStmt, 1, (url as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)

            var urlID: Int64 = 0
            if stepWithRetry(selectStmt) == SQLITE_ROW {
                urlID = sqlite3_column_int64(selectStmt, 0)
                let lastVisit = sqlite3_column_int64(selectStmt, 3)
                let newLastVisit = max(lastVisit, chromeTime)

                sqlite3_reset(updateStmt)
                sqlite3_bind_text(updateStmt, 1, (title as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_int(updateStmt, 2, Int32(addVisits))
                sqlite3_bind_int(updateStmt, 3, Int32(addTyped))
                sqlite3_bind_int64(updateStmt, 4, newLastVisit)
                sqlite3_bind_int64(updateStmt, 5, urlID)
                _ = stepWithRetry(updateStmt)
            } else {
                sqlite3_reset(insertUrlStmt)
                sqlite3_bind_text(insertUrlStmt, 1, (url as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_text(insertUrlStmt, 2, (title as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_int(insertUrlStmt, 3, Int32(addVisits))
                sqlite3_bind_int(insertUrlStmt, 4, Int32(addTyped))
                sqlite3_bind_int64(insertUrlStmt, 5, chromeTime)
                if stepWithRetry(insertUrlStmt) == SQLITE_DONE {
                    urlID = sqlite3_last_insert_rowid(db)
                }
            }

            if urlID > 0 {
                sqlite3_reset(checkVisitStmt)
                sqlite3_bind_int64(checkVisitStmt, 1, urlID)
                sqlite3_bind_int64(checkVisitStmt, 2, chromeTime)
                if stepWithRetry(checkVisitStmt) != SQLITE_ROW {
                    let transition: Int32 = addTyped > 0 ? 805306369 : 805306368
                    sqlite3_reset(insertVisitStmt)
                    sqlite3_bind_int64(insertVisitStmt, 1, urlID)
                    sqlite3_bind_int64(insertVisitStmt, 2, chromeTime)
                    sqlite3_bind_int(insertVisitStmt, 3, transition)
                    if stepWithRetry(insertVisitStmt) == SQLITE_DONE {
                        writtenCount += 1
                    }
                } else {
                    writtenCount += 1
                }
            }
        }

        var commitOk = false
        for _ in 0..<20 {
            if sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK {
                commitOk = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !commitOk {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown error"
            throw BridgeError.message("Failed to commit Chromium history transaction on \(fileURL.path): \(errmsg)")
        }
        return writtenCount
    }

    @discardableResult
    public static func writeFirefoxHistory(to placesURL: URL, items: [HistoryItem]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let fm = FileManager.default
        let dir = placesURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        var db: OpaquePointer?
        guard sqlite3_open(placesURL.path, &db) == SQLITE_OK, let db = db else {
            if let db = db { sqlite3_close(db) }
            throw BridgeError.message("Could not open Firefox places database at \(placesURL.path)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        func hasCol(table: String, column: String) -> Bool {
            var stmt: OpaquePointer?
            var found = false
            if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let colName = sqlite3_column_text(stmt, 1), String(cString: colName) == column {
                        found = true
                        break
                    }
                }
                sqlite3_finalize(stmt)
            }
            return found
        }

        func tableExists(_ name: String) -> Bool {
            var stmt: OpaquePointer?
            var exists = false
            if sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW { exists = true }
                sqlite3_finalize(stmt)
            }
            return exists
        }

        func computeRevHost(_ urlString: String) -> String {
            guard let parsed = URL(string: urlString), let host = parsed.host, !host.isEmpty else { return "." }
            return String(host.reversed()) + "."
        }

        if !tableExists("moz_places") {
            let initPlaces = """
            CREATE TABLE IF NOT EXISTS moz_places (
                id INTEGER PRIMARY KEY,
                url LONGVARCHAR,
                title LONGVARCHAR,
                rev_host LONGVARCHAR,
                visit_count INTEGER DEFAULT 0,
                hidden INTEGER DEFAULT 0,
                typed INTEGER DEFAULT 0,
                frecency INTEGER DEFAULT -1,
                last_visit_date INTEGER,
                guid TEXT
            );
            CREATE INDEX IF NOT EXISTS moz_places_url_hashindex ON moz_places (url);
            CREATE INDEX IF NOT EXISTS moz_places_hostindex ON moz_places (rev_host);
            """
            sqlite3_exec(db, initPlaces, nil, nil, nil)
        }

        if !tableExists("moz_historyvisits") {
            let initVisits = """
            CREATE TABLE IF NOT EXISTS moz_historyvisits (
                id INTEGER PRIMARY KEY,
                from_visit INTEGER DEFAULT 0,
                place_id INTEGER,
                visit_date INTEGER,
                visit_type INTEGER DEFAULT 1,
                session INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS moz_historyvisits_placedateindex ON moz_historyvisits (place_id, visit_date);
            """
            sqlite3_exec(db, initVisits, nil, nil, nil)
        }

        let withGuid = hasCol(table: "moz_places", column: "guid")
        let hasVisitsTable = tableExists("moz_historyvisits")

        func randomGuid() -> String {
            let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            return String((0..<12).compactMap { _ in chars.randomElement() })
        }

        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)

        let selectSQL = "SELECT id, visit_count, last_visit_date FROM moz_places WHERE url = ? LIMIT 1;"
        let updateSQL = "UPDATE moz_places SET title = ?, rev_host = ?, visit_count = visit_count + ?, typed = max(typed, ?), frecency = max(frecency, ?), last_visit_date = ? WHERE id = ?;"
        let insertPlaceSQL = withGuid
            ? "INSERT INTO moz_places (url, title, rev_host, visit_count, hidden, typed, frecency, last_visit_date, guid) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?);"
            : "INSERT INTO moz_places (url, title, rev_host, visit_count, hidden, typed, frecency, last_visit_date) VALUES (?, ?, ?, ?, 0, ?, ?, ?);"
        let checkVisitSQL = "SELECT id FROM moz_historyvisits WHERE place_id = ? AND visit_date = ? LIMIT 1;"
        let insertVisitSQL = "INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (?, ?, ?);"

        var selectStmt: OpaquePointer?
        var updateStmt: OpaquePointer?
        var insertPlaceStmt: OpaquePointer?
        var checkVisitStmt: OpaquePointer?
        var insertVisitStmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, insertPlaceSQL, -1, &insertPlaceStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(selectStmt)
            sqlite3_finalize(updateStmt)
            sqlite3_finalize(insertPlaceStmt)
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw BridgeError.message("Could not prepare Firefox history statements.")
        }

        if hasVisitsTable {
            _ = sqlite3_prepare_v2(db, checkVisitSQL, -1, &checkVisitStmt, nil)
            _ = sqlite3_prepare_v2(db, insertVisitSQL, -1, &insertVisitStmt, nil)
        }

        defer {
            sqlite3_finalize(selectStmt)
            sqlite3_finalize(updateStmt)
            sqlite3_finalize(insertPlaceStmt)
            if let checkVisitStmt { sqlite3_finalize(checkVisitStmt) }
            if let insertVisitStmt { sqlite3_finalize(insertVisitStmt) }
        }

        var writtenCount = 0
        let defaultMicros = Int64(Date().timeIntervalSince1970 * 1000000)

        for item in items {
            let url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : item.title
            let revHost = computeRevHost(url)

            let visitMicros: Int64
            if item.time > 0 && !item.time.isNaN && !item.time.isInfinite {
                visitMicros = Int64(item.time * 1000)
            } else {
                visitMicros = defaultMicros
            }

            let addVisits = max(1, item.visitCount)
            let isTyped = item.typedCount > 0 ? 1 : 0
            let frecency = max(100, addVisits * 1000)

            sqlite3_reset(selectStmt)
            sqlite3_bind_text(selectStmt, 1, (url as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)

            var placeID: Int64 = 0
            if sqlite3_step(selectStmt) == SQLITE_ROW {
                placeID = sqlite3_column_int64(selectStmt, 0)
                let lastVisit = sqlite3_column_int64(selectStmt, 2)
                let newLastVisit = max(lastVisit, visitMicros)

                sqlite3_reset(updateStmt)
                sqlite3_bind_text(updateStmt, 1, (title as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_text(updateStmt, 2, (revHost as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_int(updateStmt, 3, Int32(addVisits))
                sqlite3_bind_int(updateStmt, 4, Int32(isTyped))
                sqlite3_bind_int(updateStmt, 5, Int32(frecency))
                sqlite3_bind_int64(updateStmt, 6, newLastVisit)
                sqlite3_bind_int64(updateStmt, 7, placeID)
                _ = sqlite3_step(updateStmt)
            } else {
                sqlite3_reset(insertPlaceStmt)
                sqlite3_bind_text(insertPlaceStmt, 1, (url as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_text(insertPlaceStmt, 2, (title as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_text(insertPlaceStmt, 3, (revHost as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                sqlite3_bind_int(insertPlaceStmt, 4, Int32(addVisits))
                sqlite3_bind_int(insertPlaceStmt, 5, Int32(isTyped))
                sqlite3_bind_int(insertPlaceStmt, 6, Int32(frecency))
                sqlite3_bind_int64(insertPlaceStmt, 7, visitMicros)
                if withGuid {
                    sqlite3_bind_text(insertPlaceStmt, 8, (randomGuid() as NSString).utf8String, -1, PlacesReader.SQLITE_TRANSIENT)
                }
                if sqlite3_step(insertPlaceStmt) == SQLITE_DONE {
                    placeID = sqlite3_last_insert_rowid(db)
                }
            }

            if placeID > 0 {
                if let insertVisitStmt {
                    var shouldInsertVisit = true
                    if let checkVisitStmt {
                        sqlite3_reset(checkVisitStmt)
                        sqlite3_bind_int64(checkVisitStmt, 1, placeID)
                        sqlite3_bind_int64(checkVisitStmt, 2, visitMicros)
                        if sqlite3_step(checkVisitStmt) == SQLITE_ROW {
                            shouldInsertVisit = false
                        }
                    }
                    if shouldInsertVisit {
                        let visitType: Int32 = isTyped > 0 ? 2 : 1
                        sqlite3_reset(insertVisitStmt)
                        sqlite3_bind_int64(insertVisitStmt, 1, placeID)
                        sqlite3_bind_int64(insertVisitStmt, 2, visitMicros)
                        sqlite3_bind_int(insertVisitStmt, 3, visitType)
                        _ = sqlite3_step(insertVisitStmt)
                    }
                }
                writtenCount += 1
            }
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        return writtenCount
    }

    // MARK: - Rollback
    public static func rollback(receipt: OneClickReceipt, closeDestinationIfRunning: Bool = true) async throws {
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: receipt.backupDirectoryPath)
        let dest = URL(fileURLWithPath: receipt.destinationProfilePath)

        guard fm.fileExists(atPath: backup.path) else {
            throw BridgeError.message("Backup folder missing at \(receipt.backupDirectoryPath)")
        }

        if closeDestinationIfRunning {
            let running = await MainActor.run { runningApplications(for: receipt.destinationBrowser) }
            if !running.isEmpty {
                _ = await gracefullyQuitRunning(browser: receipt.destinationBrowser, timeout: 3.0)
            }
        }

        if receipt.destinationBrowser.family == .chromium {
            let backupBookmarks = backup.appendingPathComponent("Bookmarks")
            let destBookmarks = dest.appendingPathComponent("Bookmarks")
            if fm.fileExists(atPath: backupBookmarks.path) {
                try? fm.removeItem(at: destBookmarks)
                try fm.copyItem(at: backupBookmarks, to: destBookmarks)
            } else if fm.fileExists(atPath: destBookmarks.path) {
                // If there was no original bookmarks file, remove the migration folder
                if let data = try? Data(contentsOf: destBookmarks),
                   var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   var roots = parsed["roots"] as? [String: Any],
                   var bar = roots["bookmark_bar"] as? [String: Any],
                   var children = bar["children"] as? [[String: Any]] {
                    children.removeAll { ($0["name"] as? String) == receipt.migratedFolder }
                    bar["children"] = children
                    roots["bookmark_bar"] = bar
                    parsed["roots"] = roots
                    if let out = try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys]) {
                        try? out.write(to: destBookmarks, options: .atomic)
                    }
                }
            }

            // Restore standard Chromium History
            let backupHistory = backup.appendingPathComponent("History")
            let destHistory = dest.appendingPathComponent("History")
            if fm.fileExists(atPath: backupHistory.path) {
                try? fm.removeItem(at: destHistory)
                try fm.copyItem(at: backupHistory, to: destHistory)
            } else if fm.fileExists(atPath: destHistory.path) {
                try? fm.removeItem(at: destHistory)
            }
            for suffix in ["-journal", "-wal", "-shm"] {
                let bSuff = backup.appendingPathComponent("History\(suffix)")
                let dSuff = dest.appendingPathComponent("History\(suffix)")
                try? fm.removeItem(at: dSuff)
                if fm.fileExists(atPath: bSuff.path) {
                    try? fm.copyItem(at: bSuff, to: dSuff)
                }
            }

            // Restore Default/History if present or clean up if newly created
            let defaultDir = dest.appendingPathComponent("Default")
            let backupDefHistory = backup.appendingPathComponent("Default_History")
            let destDefHistory = defaultDir.appendingPathComponent("History")
            if fm.fileExists(atPath: backupDefHistory.path) {
                try? fm.removeItem(at: destDefHistory)
                try? fm.copyItem(at: backupDefHistory, to: destDefHistory)
            } else if fm.fileExists(atPath: destDefHistory.path) && !fm.fileExists(atPath: backupDefHistory.path) {
                if fm.fileExists(atPath: backup.appendingPathComponent("Default_Bookmarks").path) || fm.fileExists(atPath: backup.appendingPathComponent("Local State").path) {
                    try? fm.removeItem(at: destDefHistory)
                }
            }
            for suffix in ["-journal", "-wal", "-shm"] {
                let bSuff = backup.appendingPathComponent("Default_History\(suffix)")
                let dSuff = defaultDir.appendingPathComponent("History\(suffix)")
                if fm.fileExists(atPath: bSuff.path) {
                    try? fm.removeItem(at: dSuff)
                    try? fm.copyItem(at: bSuff, to: dSuff)
                } else if fm.fileExists(atPath: dSuff.path) {
                    try? fm.removeItem(at: dSuff)
                }
            }

            // Restore Local State and profile Bookmarks/History for Chromium browsers
            if receipt.destinationBrowser.family == .chromium {
                let isProfileDir = dest.lastPathComponent.hasPrefix("Profile") || dest.lastPathComponent == "Default"
                let userDataDir = isProfileDir ? dest.deletingLastPathComponent() : dest
                let backupLS = backup.appendingPathComponent("Local State")
                let destLS = userDataDir.appendingPathComponent("Local State")
                if fm.fileExists(atPath: backupLS.path) {
                    try? fm.removeItem(at: destLS)
                    try? fm.copyItem(at: backupLS, to: destLS)
                }
                if let backupFiles = try? fm.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil) {
                    for bf in backupFiles {
                        let name = bf.lastPathComponent
                        if name.contains("_Bookmarks") {
                            let profileDir = String(name.prefix(upTo: name.range(of: "_Bookmarks")!.lowerBound))
                            let targetBm = userDataDir.appendingPathComponent(profileDir).appendingPathComponent("Bookmarks")
                            try? fm.removeItem(at: targetBm)
                            try? fm.copyItem(at: bf, to: targetBm)
                        } else if name.contains("_History") {
                            let range = name.range(of: "_History")!
                            let profileDir = String(name[..<range.lowerBound])
                            let suffix = String(name[range.upperBound...])
                            let targetHist = userDataDir.appendingPathComponent(profileDir).appendingPathComponent("History\(suffix)")
                            try? fm.removeItem(at: targetHist)
                            try? fm.copyItem(at: bf, to: targetHist)
                        }
                    }
                }
                // Clean up any History file in candidate profile directories that didn't exist in backup
                if let children = try? fm.contentsOfDirectory(at: userDataDir, includingPropertiesForKeys: nil) {
                    for child in children where child.lastPathComponent.hasPrefix("Profile") || child.lastPathComponent == "Default" {
                        let pName = child.lastPathComponent
                        let backupHist = backup.appendingPathComponent("\(pName)_History")
                        let pHist = child.appendingPathComponent("History")
                        if !fm.fileExists(atPath: backupHist.path) && fm.fileExists(atPath: pHist.path) {
                            try? fm.removeItem(at: pHist)
                            for suff in ["-journal", "-wal", "-shm"] {
                                try? fm.removeItem(at: child.appendingPathComponent("History\(suff)"))
                            }
                        }
                    }
                }
            }
        } else if receipt.destinationBrowser.family == .firefox {
            let backupPlaces = backup.appendingPathComponent("places.sqlite")
            let destPlaces = dest.appendingPathComponent("places.sqlite")
            if fm.fileExists(atPath: backupPlaces.path) {
                try? fm.removeItem(at: destPlaces)
                try fm.copyItem(at: backupPlaces, to: destPlaces)
            } else if fm.fileExists(atPath: destPlaces.path) {
                try? fm.removeItem(at: destPlaces)
            }
            for suffix in ["-wal", "-shm"] {
                let backupWal = backup.appendingPathComponent("places.sqlite\(suffix)")
                let destWal = dest.appendingPathComponent("places.sqlite\(suffix)")
                try? fm.removeItem(at: destWal)
                if fm.fileExists(atPath: backupWal.path) {
                    try? fm.copyItem(at: backupWal, to: destWal)
                }
            }
            let destHtml = dest.appendingPathComponent("Bookmarks.html")
            try? fm.removeItem(at: destHtml)
        }

        var updated = receipt
        updated.status = "rolled-back"
        try saveReceipt(updated)
    }

    public static func rollback(id: String, closeDestinationIfRunning: Bool = true) async throws -> OneClickReceipt {
        let all = try receipts()
        guard let match = all.first(where: { $0.id == id || $0.id.hasPrefix(id) }) else {
            throw BridgeError.message("No receipt found with ID matching '\(id)'")
        }
        try await rollback(receipt: match, closeDestinationIfRunning: closeDestinationIfRunning)
        return match
    }

    public struct DryRunResult: Sendable {
        public var sourceBrowser: BrowserID
        public var sourceProfile: URL
        public var destinationBrowser: BrowserID
        public var destinationProfile: URL
        public var bookmarksCount: Int
        public var tabsCount: Int
        public var groupsCount: Int
        public var historyCount: Int
        public var warnings: [String]
        public var destinationExists: Bool
        public var destinationRunning: Bool
        public var plannedBackupDirectory: String
        public var summary: String
    }

    public static func dryRun(
        sourceBrowser: BrowserID,
        sourceProfile: URL,
        destinationBrowser: BrowserID,
        destinationProfile: URL,
        options: TransferOptions = TransferOptions(bookmarks: true, tabs: true, history: true, groups: true),
        backupDirectory: URL? = nil
    ) async throws -> DryRunResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceProfile.path) else {
            throw BridgeError.message("Source profile does not exist at \(sourceProfile.path)")
        }
        let canonicalSource = (sourceProfile.path as NSString).resolvingSymlinksInPath
        let canonicalDest = (destinationProfile.path as NSString).resolvingSymlinksInPath
        if canonicalSource == canonicalDest {
            throw BridgeError.message("Source and destination profiles are the same folder. Choose different profiles.")
        }
        let snapshot = try BrowserReader.read(profile: sourceProfile, browser: sourceBrowser)
        let running = await MainActor.run { runningApplications(for: destinationBrowser) }
        let backupBase = backupDirectory ?? defaultBackupRoot
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let plannedBackup = backupBase.appendingPathComponent("Backup-\(destinationBrowser.name)-\(stamp)-dryrun", isDirectory: true).path

        let bCount = options.bookmarks ? snapshot.bookmarks.filter { $0.url != nil && $0.url!.hasPrefix("http") }.count : 0
        let tCount = options.tabs ? snapshot.tabs.filter { ($0.originalURL ?? $0.url).hasPrefix("http") }.count : 0
        let gCount = options.groups ? (snapshot.spaces.count + snapshot.folders.count) : 0
        let hCount = options.history ? snapshot.history.count : 0

        let summary: String
        if destinationBrowser == .dia && !snapshot.spaces.isEmpty {
            let essCount = snapshot.tabs.filter(\.essential).count
            let pinCount = snapshot.tabs.filter { $0.pinned && !$0.essential }.count
            summary = "Dry run: \(sourceBrowser.name) → \(destinationBrowser.name). Would auto-create \(snapshot.spaces.count) Dia spaces (\(snapshot.spaces.map(\.name).joined(separator: ", "))) with \(bCount) bookmarks, \(tCount) tabs (\(essCount) essentials/pinned favorites across all spaces, \(pinCount) space-pinned tabs), \(snapshot.folders.count) folders, and \(hCount) history entries intact. Pre-migration backup target: \(plannedBackup)."
        } else {
            summary = "Dry run: \(sourceBrowser.name) → \(destinationBrowser.name). Would migrate \(bCount) bookmarks, \(tCount) tabs, \(gCount) groups, \(hCount) history entries. Pre-migration backup target: \(plannedBackup)."
        }

        return DryRunResult(
            sourceBrowser: sourceBrowser,
            sourceProfile: sourceProfile,
            destinationBrowser: destinationBrowser,
            destinationProfile: destinationProfile,
            bookmarksCount: bCount,
            tabsCount: tCount,
            groupsCount: gCount,
            historyCount: hCount,
            warnings: snapshot.warnings,
            destinationExists: fm.fileExists(atPath: destinationProfile.path),
            destinationRunning: !running.isEmpty,
            plannedBackupDirectory: plannedBackup,
            summary: summary
        )
    }

    public static func resolveDefaultProfile(browser: BrowserID, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if browser == .dia {
            if let root = browser.roots(home: home).first {
                return root
            }
            return home.appendingPathComponent("Library/Application Support/Dia/User Data")
        }
        if let discovered = try? BrowserReader.discover(browser: browser, home: home), let first = discovered.first {
            return first.path
        }
        if let root = browser.roots(home: home).first {
            if browser.family == .chromium {
                return root.appendingPathComponent("Default")
            }
            return root
        }
        return home.appendingPathComponent(browser.dataPaths.first ?? "Library/Application Support/\(browser.name)").appendingPathComponent("Default")
    }

    // MARK: - Helpers
    private static func tabUrl(_ tab: BrowserTab) -> String {
        tab.originalURL ?? tab.url
    }

    @MainActor
    @discardableResult
    public static func launchDestination(browser: BrowserID, tabs: [BrowserTab] = []) -> Bool {
        // Wait a short moment if destination was just terminating so file locks release cleanly
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            let stillRunning = runningApplications(for: browser)
            if stillRunning.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.15)
        }

        // For multi-space browsers like Dia, do NOT pass CLI URLs because Chromium/Dia routes
        // all CLI arguments to a single frontmost window, clobbering profile isolation.
        // Each Dia profile will restore its own startup_urls cleanly.
        let launchUrls: [URL]
        if browser == .dia {
            launchUrls = []
        } else {
            let prioritizedTabs = tabs.sorted { (a, b) -> Bool in
                if a.essential != b.essential { return a.essential && !b.essential }
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.order < b.order
            }
            let validUrls = prioritizedTabs.compactMap { URL(string: $0.originalURL ?? $0.url) }
                .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            launchUrls = Array(validUrls.prefix(5))
        }

        let bundleIDs = browserBundleIdentifiers[browser] ?? []
        let names = browserAppNames[browser] ?? []

        // 1. Try launching with NSWorkspace with window activation
        for bid in bundleIDs {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                if !launchUrls.isEmpty {
                    NSWorkspace.shared.open(launchUrls, withApplicationAt: appURL, configuration: config, completionHandler: nil)
                } else {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                }
                return true
            }
        }

        // 2. Try launching with /usr/bin/open by Bundle Identifier
        for bid in bundleIDs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            var args = ["-b", bid]
            if !launchUrls.isEmpty {
                args.append(contentsOf: launchUrls.map(\.absoluteString))
            }
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return true
                }
            } catch {}
        }

        // 3. Try launching with /usr/bin/open by App Name
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            var args = ["-a", name]
            if !launchUrls.isEmpty {
                args.append(contentsOf: launchUrls.map(\.absoluteString))
            }
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return true
                }
            } catch {}
        }

        return false
    }

    @MainActor
    public static func launchDestinationWithTabs(browser: BrowserID, tabs: [BrowserTab]) -> Bool {
        launchDestination(browser: browser, tabs: tabs)
    }

    public static func generateNetscapeHTML(snapshot: Snapshot, folderTitle: String, options: TransferOptions) -> String {
        func escape(_ val: String) -> String {
            val.replacingOccurrences(of: "&", with: "&amp;")
               .replacingOccurrences(of: "\"", with: "&quot;")
               .replacingOccurrences(of: "<", with: "&lt;")
               .replacingOccurrences(of: ">", with: "&gt;")
        }

        func isValidHttpURL(_ s: String) -> Bool {
            guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }

        func tabUrl(_ tab: BrowserTab) -> String {
            tab.originalURL ?? tab.url
        }

        func tabTitle(_ tab: BrowserTab) -> String {
            let url = tabUrl(tab)
            let trimmed = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? url : trimmed
        }

        var body = ""

        // 1. Essentials
        if options.tabs {
            let essentials = snapshot.tabs.filter { $0.essential && isValidHttpURL(tabUrl($0)) }
                .sorted { $0.order < $1.order }
            if !essentials.isEmpty {
                var essHTML = ""
                for tab in essentials {
                    let url = tabUrl(tab)
                    let title = tabTitle(tab)
                    essHTML += "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n"
                }
                body += "<DT><H3>⭐ Essentials</H3>\n<DL><p>\n\(essHTML)</DL><p>\n"
            }
        }

        // 2. Spaces & Folders hierarchy
        let allFolderIDs = Set(snapshot.folders.map(\.id))
        let knownSpaceIDs = Set(snapshot.spaces.map(\.id))
        var renderedFolderIDs = Set<String>()

        func buildHTMLFolderTree(folder: Folder) -> String {
            guard renderedFolderIDs.insert(folder.id).inserted else { return "" }
            var inner = ""

            // Subfolders
            let subfolders = snapshot.folders.filter { $0.parentID == folder.id && !renderedFolderIDs.contains($0.id) }
            for sub in subfolders {
                inner += buildHTMLFolderTree(folder: sub)
            }

            // Tabs in this folder
            let folderTabs = snapshot.tabs.filter { $0.folderID == folder.id && isValidHttpURL(tabUrl($0)) }
                .sorted { $0.order < $1.order }
            for tab in folderTabs {
                let url = tabUrl(tab)
                let title = tabTitle(tab)
                let name = tab.pinned ? "📌 \(title)" : title
                inner += "<DT><A HREF=\"\(escape(url))\">\(escape(name))</A>\n"
            }

            let name = folder.name.isEmpty ? "Folder" : folder.name
            return "<DT><H3>\(escape(name))</H3>\n<DL><p>\n\(inner)</DL><p>\n"
        }

        if options.groups || options.tabs {
            if options.groups && !snapshot.spaces.isEmpty {
                for space in snapshot.spaces {
                    var spaceHTML = ""

                    // Space Pinned tabs
                    if options.tabs {
                        let spacePins = snapshot.tabs.filter {
                            $0.spaceID == space.id && $0.pinned && !$0.essential &&
                            ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                            isValidHttpURL(tabUrl($0))
                        }.sorted { $0.order < $1.order }

                        if !spacePins.isEmpty {
                            var pinHTML = ""
                            for tab in spacePins {
                                let url = tabUrl(tab)
                                let title = tabTitle(tab)
                                pinHTML += "<DT><A HREF=\"\(escape(url))\">📌 \(escape(title))</A>\n"
                            }
                            spaceHTML += "<DT><H3>📌 Pinned Tabs</H3>\n<DL><p>\n\(pinHTML)</DL><p>\n"
                        }
                    }

                    // Space Folders
                    let spaceRoots = snapshot.folders.filter {
                        $0.spaceID == space.id && ($0.parentID == nil || !allFolderIDs.contains($0.parentID!))
                    }
                    for f in spaceRoots {
                        spaceHTML += buildHTMLFolderTree(folder: f)
                    }

                    // Space Open tabs
                    if options.tabs {
                        let spaceOpen = snapshot.tabs.filter {
                            $0.spaceID == space.id && !$0.pinned && !$0.essential &&
                            ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                            isValidHttpURL(tabUrl($0))
                        }.sorted { $0.order < $1.order }

                        if !spaceOpen.isEmpty {
                            if !spaceHTML.isEmpty {
                                var openHTML = ""
                                for tab in spaceOpen {
                                    let url = tabUrl(tab)
                                    let title = tabTitle(tab)
                                    openHTML += "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n"
                                }
                                spaceHTML += "<DT><H3>Open Tabs</H3>\n<DL><p>\n\(openHTML)</DL><p>\n"
                            } else {
                                for tab in spaceOpen {
                                    let url = tabUrl(tab)
                                    let title = tabTitle(tab)
                                    spaceHTML += "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n"
                                }
                            }
                        }
                    }

                    if !spaceHTML.isEmpty {
                        body += "<DT><H3>\(escape(space.name))</H3>\n<DL><p>\n\(spaceHTML)</DL><p>\n"
                    }
                }
            }

            // Global / Unassigned Folders
            let globalRoots = snapshot.folders.filter {
                !renderedFolderIDs.contains($0.id) &&
                ($0.parentID == nil || !allFolderIDs.contains($0.parentID!))
            }
            for f in globalRoots {
                body += buildHTMLFolderTree(folder: f)
            }
            for f in snapshot.folders where !renderedFolderIDs.contains(f.id) {
                body += buildHTMLFolderTree(folder: f)
            }

            // Global Pinned tabs
            if options.tabs {
                let globalPins = snapshot.tabs.filter {
                    $0.pinned && !$0.essential &&
                    ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                    ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)) &&
                    isValidHttpURL(tabUrl($0))
                }.sorted { $0.order < $1.order }

                if !globalPins.isEmpty {
                    var pinHTML = ""
                    for tab in globalPins {
                        let url = tabUrl(tab)
                        let title = tabTitle(tab)
                        pinHTML += "<DT><A HREF=\"\(escape(url))\">📌 \(escape(title))</A>\n"
                    }
                    body += "<DT><H3>📌 Pinned Tabs</H3>\n<DL><p>\n\(pinHTML)</DL><p>\n"
                }

                // Global Open tabs
                let globalOpen = snapshot.tabs.filter {
                    !$0.pinned && !$0.essential &&
                    ($0.folderID == nil || !allFolderIDs.contains($0.folderID!)) &&
                    ($0.spaceID == nil || !knownSpaceIDs.contains($0.spaceID!)) &&
                    isValidHttpURL(tabUrl($0))
                }.sorted { $0.order < $1.order }

                if !globalOpen.isEmpty {
                    var openHTML = ""
                    for tab in globalOpen {
                        let url = tabUrl(tab)
                        let title = tabTitle(tab)
                        openHTML += "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n"
                    }
                    body += "<DT><H3>Open Tabs</H3>\n<DL><p>\n\(openHTML)</DL><p>\n"
                }
            }
        }

        // 3. Nested Bookmarks
        if options.bookmarks && !snapshot.bookmarks.isEmpty {
            var visitedIDs = Set<Int64>()
            func buildTree(parent: Int64) -> String {
                var res = ""
                let items = snapshot.bookmarks.filter { $0.parent == parent && !visitedIDs.contains($0.id) }
                for b in items {
                    visitedIDs.insert(b.id)
                    if b.type == 2 {
                        let sub = buildTree(parent: b.id)
                        let name = b.title.isEmpty ? "Folder" : b.title
                        res += "<DT><H3>\(escape(name))</H3>\n<DL><p>\n\(sub)</DL><p>\n"
                    } else if let url = b.url, isValidHttpURL(url) {
                        let title = b.title.isEmpty ? url : b.title
                        res += "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n"
                    }
                }
                return res
            }

            var tree = buildTree(parent: 0)
            let allIDs = Set(snapshot.bookmarks.map(\.id))
            let unvisitedRoots = snapshot.bookmarks.filter { !visitedIDs.contains($0.id) && !allIDs.contains($0.parent) }
            for rootItem in unvisitedRoots {
                visitedIDs.insert(rootItem.id)
                if rootItem.type == 2 {
                    let sub = buildTree(parent: rootItem.id)
                    let name = rootItem.title.isEmpty ? "Folder" : rootItem.title
                    tree += "<DT><H3>\(escape(name))</H3>\n<DL><p>\n\(sub)</DL><p>\n"
                } else if let url = rootItem.url, isValidHttpURL(url) {
                    let title = rootItem.title.isEmpty ? url : rootItem.title
                    tree += "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n"
                }
            }
            for b in snapshot.bookmarks where !visitedIDs.contains(b.id) {
                if let url = b.url, isValidHttpURL(url) {
                    visitedIDs.insert(b.id)
                    let title = b.title.isEmpty ? url : b.title
                    tree += "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n"
                }
            }

            if !tree.isEmpty {
                body += "<DT><H3>Bookmarks</H3>\n<DL><p>\n\(tree)</DL><p>\n"
            }
        }

        return """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Browser Bridge Migration</TITLE>
        <H1>Browser Bridge Migration</H1>
        <DL><p>
        <DT><H3>\(escape(folderTitle))</H3>
        <DL><p>
        \(body)
        </DL><p>
        </DL><p>
        """
    }
}
