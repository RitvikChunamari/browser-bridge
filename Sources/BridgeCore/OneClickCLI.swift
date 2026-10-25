import Foundation

public struct OneClickCLI: Sendable {
    public static let helpMessage = """
    Browser Bridge 1-Click Migration CLI (`bridge-migrate`)
    Seamless, instant browser-to-browser migration with zero extension setup.

    Usage:
      bridge-migrate <sourceBrowser> [sourceProfile] <destBrowser> [destProfile] [options]
      bridge-migrate --list-receipts
      bridge-migrate --rollback <receipt-id>
      bridge-migrate --dry-run <sourceBrowser> [sourceProfile] <destBrowser> [destProfile]

    Options:
      --list-receipts, -l          List all 1-click migration receipts
      --rollback, -r <id>          Undo a past migration by receipt ID
      --dry-run, -n                Simulate migration without modifying any files
      --source-profile <path>      Explicit filesystem path to source profile
      --dest-profile <path>        Explicit filesystem path to destination profile
      --backup-dir <path>          Custom directory for pre-migration backups
      --open                       Open destination browser with migrated tabs after migration
      --no-open                    Do not launch destination browser (default in CLI)
      --no-close                   Do not close running destination browser
      --no-bookmarks               Skip migrating bookmarks
      --no-tabs                    Skip migrating open tabs and pins
      --no-groups                  Skip migrating tab groups and spaces
      --history                    Include browsing history (default: true)
      --no-history                 Skip migrating browsing history
      --help, -h                   Show this help message

    Browsers:
      chrome, brave, arc, zen, dia, helium, firefox, safari, edge, opera, vivaldi

    Examples:
      swift run bridge-migrate chrome brave
      swift run bridge-migrate chrome ~/Library/Application\\ Support/Google/Chrome/Default brave
      swift run bridge-migrate --dry-run zen dia
      swift run bridge-migrate --list-receipts
      swift run bridge-migrate --rollback 8C1D0294
    """

    public static func run(arguments: [String]) async throws -> String {
        if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
            return helpMessage
        }

        if arguments.contains("-l") || arguments.contains("--list-receipts") {
            return try listReceipts()
        }

        if arguments.contains("--sync-dia") {
            let prof = OneClickMigrator.resolveDefaultProfile(browser: .zen)
            let snap = try BrowserReader.read(profile: prof, browser: .zen)
            let success = await MainActor.run {
                OneClickMigrator.syncDiaLiveSpaces(snapshot: snap)
            }
            return success ? "✓ Dia live spaces synchronized successfully!" : "Failed to sync Dia live spaces."
        }

        if let focusIdx = arguments.firstIndex(of: "--focus-profile"), focusIdx + 1 < arguments.count, let pIdx = Int(arguments[focusIdx + 1]) {
            return await MainActor.run {
                let script = """
                tell application "Dia"
                    activate
                    tell first window
                        focus (profile \(pIdx))
                    end tell
                end tell
                """
                var err: NSDictionary?
                let asObj = NSAppleScript(source: script)
                _ = asObj?.executeAndReturnError(&err)
                if let err = err { return "AppleScript Error: \(err)" }
                return "Focused profile \(pIdx) in Dia."
            }
        }


        if arguments.contains("--inspect-summary") {
            return await MainActor.run {
                let script = """
                tell application "Dia"
                    set out to ""
                    repeat with w in windows
                        set out to out & "Window: " & (name of w) & linefeed
                        set profs to every profile of w
                        repeat with p in profs
                            set out to out & "=== Profile " & (index of p) & ": " & (name of p) & " ===" & linefeed
                            set tList to every tab of p
                            set pCount to 0
                            set oCount to 0
                            repeat with t in tList
                                try
                                    if isPinned of t then
                                        set pCount to pCount + 1
                                        set out to out & "  [" & pCount & "] " & (title of t) & linefeed
                                    else
                                        set oCount to oCount + 1
                                    end if
                                end try
                            end repeat
                            set out to out & "Total Pinned: " & pCount & " | Open: " & oCount & linefeed & linefeed
                        end repeat
                    end repeat
                    return out
                end tell
                """
                var err: NSDictionary?
                let asObj = NSAppleScript(source: script)
                let desc = asObj?.executeAndReturnError(&err)
                if let err = err { return "AppleScript Error: \(err)" }
                return desc?.stringValue ?? "No output"
            }
        }

        if arguments.contains("--inspect-dia") {
            return await MainActor.run {
                let script = """
                tell application "Dia"
                    set out to "WINDOWS: " & (count of windows) & linefeed
                    repeat with w in windows
                        set out to out & "Window: " & (id of w) & " | name: " & (name of w) & linefeed
                        try
                            set ap to active profile of w
                            set out to out & "  Active Profile: " & (name of ap) & " (index " & (index of ap) & ")" & linefeed
                        on error err
                            set out to out & "  Active Profile Error: " & err & linefeed
                        end try
                        set profs to every profile of w
                        set out to out & "  Profiles count: " & (count of profs) & linefeed
                        repeat with p in profs
                            set out to out & "  - Profile " & (index of p) & ": " & (name of p) & linefeed
                            set tList to every tab of p
                            set pCount to 0
                            set oCount to 0
                            repeat with t in tList
                                try
                                    if isPinned of t then
                                        set pCount to pCount + 1
                                        set out to out & "      [PIN] " & (title of t) & " -> " & (URL of t) & linefeed
                                    else
                                        set oCount to oCount + 1
                                    end if
                                end try
                            end repeat
                            set out to out & "    Total pinned: " & pCount & " | Open: " & oCount & linefeed
                        end repeat
                    end repeat
                    return out
                end tell
                """
                var err: NSDictionary?
                let asObj = NSAppleScript(source: script)
                let desc = asObj?.executeAndReturnError(&err)
                if let err = err {
                    return "AppleScript Error: \(err)"
                }
                return desc?.stringValue ?? "No output"
            }
        }

        if arguments.contains("--dump-source") || arguments.contains("--inspect-source") {
            let browser = BrowserID(rawValue: arguments.first(where: { !["--dump-source", "--inspect-source"].contains($0) }) ?? "zen") ?? .zen
            let prof = OneClickMigrator.resolveDefaultProfile(browser: browser)
            let snap = try BrowserReader.read(profile: prof, browser: browser)
            var out = "=== \(browser.name) INSPECTION ===\n"
            out += "Profile: \(prof.path)\n"
            out += "Spaces: \(snap.spaces.count)\n"
            for s in snap.spaces { out += "  - '\(s.name)' (ID: \(s.id))\n" }
            let ess = snap.tabs.filter(\.essential)
            out += "\nEssentials: \(ess.count)\n"
            for e in ess { out += "  ⭐ \(e.title) -> \(e.url)\n" }
            let allFIDs = Set(snap.folders.map(\.id))
            for s in snap.spaces {
                let pins = snap.tabs.filter { $0.spaceID == s.id && $0.pinned && !$0.essential && ($0.folderID == nil || !allFIDs.contains($0.folderID!)) }
                let open = snap.tabs.filter { $0.spaceID == s.id && !$0.pinned && !$0.essential && ($0.folderID == nil || !allFIDs.contains($0.folderID!)) }
                let sFolders = snap.folders.filter { $0.spaceID == s.id && ($0.parentID == nil || !allFIDs.contains($0.parentID!)) }
                out += "\n--- Space: '\(s.name)' ---\n"
                out += "  Pinned tabs: \(pins.count)\n"
                for p in pins.prefix(8) { out += "    📌 \(p.title) -> \(p.url)\n" }
                out += "  Open tabs: \(open.count)\n"
                for o in open.prefix(8) { out += "    🌐 \(o.title) -> \(o.url)\n" }
                out += "  Folders: \(sFolders.count)\n"
                for f in sFolders {
                    let fTabs = snap.tabs.filter { $0.folderID == f.id }
                    out += "    📁 \(f.name) (\(fTabs.count) tabs)\n"
                    for ft in fTabs.prefix(5) { out += "       📄 \(ft.title) -> \(ft.url)\n" }
                }
            }
            return out
        }

        if let rollbackIdx = arguments.firstIndex(where: { $0 == "-r" || $0 == "--rollback" }) {
            guard rollbackIdx + 1 < arguments.count else {
                throw BridgeError.message("Missing receipt ID for --rollback. Usage: bridge-migrate --rollback <id>")
            }
            let id = arguments[rollbackIdx + 1]
            let noClose = arguments.contains("--no-close")
            let receipt = try await OneClickMigrator.rollback(id: id, closeDestinationIfRunning: !noClose)
            return """
            ✓ Rollback Successful
              Receipt ID:          \(receipt.id)
              Destination Browser: \(receipt.destinationBrowser.name)
              Destination Profile: \(receipt.destinationProfilePath)
              Restored from:       \(receipt.backupDirectoryPath)
              Status:              rolled-back
            """
        }

        // Parse Flags & Positional
        var sourceProfileFlag: String?
        var destProfileFlag: String?
        var backupDirFlag: String?
        var dryRun = false
        var openDestination = false
        var closeDestinationIfRunning = true
        var transferBookmarks = true
        var transferTabs = true
        var transferGroups = true
        var transferHistory = true

        var positional: [String] = []
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--dry-run", "-n":
                dryRun = true
            case "--open":
                openDestination = true
            case "--no-open":
                openDestination = false
            case "--no-close":
                closeDestinationIfRunning = false
            case "--no-bookmarks":
                transferBookmarks = false
            case "--bookmarks":
                transferBookmarks = true
            case "--no-tabs":
                transferTabs = false
            case "--tabs":
                transferTabs = true
            case "--no-groups":
                transferGroups = false
            case "--groups":
                transferGroups = true
            case "--history":
                transferHistory = true
            case "--no-history":
                transferHistory = false
            case "--source-profile":
                i += 1
                guard i < arguments.count else { throw BridgeError.message("Missing path for --source-profile") }
                sourceProfileFlag = arguments[i]
            case "--dest-profile":
                i += 1
                guard i < arguments.count else { throw BridgeError.message("Missing path for --dest-profile") }
                destProfileFlag = arguments[i]
            case "--backup-dir":
                i += 1
                guard i < arguments.count else { throw BridgeError.message("Missing path for --backup-dir") }
                backupDirFlag = arguments[i]
            default:
                if !arg.hasPrefix("-") {
                    positional.append(arg)
                } else {
                    throw BridgeError.message("Unknown option '\(arg)'. Run 'bridge-migrate --help' for usage.")
                }
            }
            i += 1
        }

        guard !positional.isEmpty else {
            throw BridgeError.message("Source and destination browsers required. Run 'bridge-migrate --help' for usage.")
        }

        var sourceBrowserString = ""
        var sourceProfileString: String? = sourceProfileFlag
        var destBrowserString = ""
        var destProfileString: String? = destProfileFlag

        if positional.count == 1 {
            throw BridgeError.message("Missing destination browser. Usage: bridge-migrate <sourceBrowser> <destBrowser>")
        } else if positional.count == 2 {
            sourceBrowserString = positional[0]
            destBrowserString = positional[1]
        } else if positional.count == 3 {
            sourceBrowserString = positional[0]
            if let _ = BrowserID(rawValue: positional[1].lowercased()) {
                // Positional: source, dest, destProfile
                destBrowserString = positional[1]
                destProfileString = destProfileString ?? positional[2]
            } else {
                // Positional: source, sourceProfile, dest
                sourceProfileString = sourceProfileString ?? positional[1]
                destBrowserString = positional[2]
            }
        } else {
            sourceBrowserString = positional[0]
            sourceProfileString = sourceProfileString ?? positional[1]
            destBrowserString = positional[2]
            destProfileString = destProfileString ?? positional[3]
        }

        guard let sourceBrowser = BrowserID(rawValue: sourceBrowserString.lowercased()) else {
            let available = BrowserID.allCases.map(\.rawValue).joined(separator: ", ")
            throw BridgeError.message("Unknown source browser '\(sourceBrowserString)'. Choose from: \(available)")
        }

        guard let destBrowser = BrowserID(rawValue: destBrowserString.lowercased()) else {
            let available = BrowserID.allCases.map(\.rawValue).joined(separator: ", ")
            throw BridgeError.message("Unknown destination browser '\(destBrowserString)'. Choose from: \(available)")
        }

        let sourceURL: URL
        if let s = sourceProfileString {
            sourceURL = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        } else {
            sourceURL = OneClickMigrator.resolveDefaultProfile(browser: sourceBrowser)
        }

        let destURL: URL
        if let d = destProfileString {
            destURL = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
        } else {
            destURL = OneClickMigrator.resolveDefaultProfile(browser: destBrowser)
        }

        let backupDirURL = backupDirFlag.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let options = TransferOptions(
            bookmarks: transferBookmarks,
            tabs: transferTabs,
            history: transferHistory,
            groups: transferGroups
        )

        if dryRun {
            let result = try await OneClickMigrator.dryRun(
                sourceBrowser: sourceBrowser,
                sourceProfile: sourceURL,
                destinationBrowser: destBrowser,
                destinationProfile: destURL,
                options: options,
                backupDirectory: backupDirURL
            )

            var out = """
            ============================================================
            🔍 [DRY RUN] 1-Click Migration Simulation
            ============================================================
            Source:               \(result.sourceBrowser.name)
            Source Profile:       \(result.sourceProfile.path)
            Destination:          \(result.destinationBrowser.name)
            Destination Profile:  \(result.destinationProfile.path)
            Destination Status:   \(result.destinationRunning ? "Running (will be closed gracefully before transfer)" : "Not running")
            Destination Exists:   \(result.destinationExists ? "Yes (baseline will be preserved)" : "Will be created")
            Backup Folder Target: \(result.plannedBackupDirectory)

            Items to Migrate:
              • Bookmarks:        \(result.bookmarksCount)
              • Open Tabs & Pins: \(result.tabsCount)
              • Groups / Spaces:  \(result.groupsCount)
              • History:          \(result.historyCount)
            """
            if !result.warnings.isEmpty {
                out += "\n\nWarnings:\n" + result.warnings.map { "  ⚠ \($0)" }.joined(separator: "\n")
            }
            out += "\n\nResult: Validation passed. Ready for 1-click migration. (No files were modified)"
            return out
        }

        // Execute 1-Click Migration
        let receipt = try await OneClickMigrator.migrate(
            sourceBrowser: sourceBrowser,
            sourceProfile: sourceURL,
            destinationBrowser: destBrowser,
            destinationProfile: destURL,
            options: options,
            backupDirectory: backupDirURL,
            closeDestinationIfRunning: closeDestinationIfRunning,
            openDestination: openDestination
        )

        var out = """
        ============================================================
        ⚡ 1-Click Browser Migration Complete!
        ============================================================
        Receipt ID:          \(receipt.id)
        Timestamp:           \(ISO8601DateFormatter().string(from: receipt.createdAt))
        Route:               \(receipt.sourceBrowser.name) → \(receipt.destinationBrowser.name)
        Source Profile:      \(receipt.sourceProfilePath)
        Destination Profile: \(receipt.destinationProfilePath)
        Backup Preserved:    \(receipt.backupDirectoryPath)
        Migrated Folder:     "\(receipt.migratedFolder)"

        Transferred Items:
          • Bookmarks:       \(receipt.bookmarksCount)
          • Tabs & Pins:     \(receipt.tabsCount)
          • Groups / Spaces: \(receipt.groupsCount)
          • History:         \(receipt.historyCount)
          • Status:          \(receipt.status)
        """
        if !receipt.warnings.isEmpty {
            out += "\n\nNotes:\n" + receipt.warnings.map { "  • \($0)" }.joined(separator: "\n")
        }
        out += """


        To undo this migration at any time, run:
          bridge-migrate --rollback \(receipt.id)
        """
        return out
    }

    private static func listReceipts() throws -> String {
        let receipts = try OneClickMigrator.receipts()
        if receipts.isEmpty {
            return "No migration receipts found. Run 'bridge-migrate' to perform your first 1-click migration."
        }

        var lines: [String] = [
            "============================================================",
            "📜 1-Click Migration Receipts (\(receipts.count))",
            "============================================================"
        ]
        for r in receipts {
            let statusBadge = r.status == "rolled-back" ? "ROLLED BACK" : "ACTIVE"
            lines.append("""
            ID:       \(r.id) [\(statusBadge)]
            Date:     \(r.createdAt.formatted(date: .abbreviated, time: .shortened))
            Route:    \(r.sourceBrowser.name) → \(r.destinationBrowser.name)
            Items:    \(r.bookmarksCount) bookmarks, \(r.tabsCount) tabs, \(r.groupsCount) groups, \(r.historyCount) history
            Backup:   \(r.backupDirectoryPath)
            Destination Folder: "\(r.migratedFolder)"
            ------------------------------------------------------------
            """)
        }
        return lines.joined(separator: "\n")
    }
}
