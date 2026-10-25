import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BridgeCore

@main struct BrowserBridgeApp: App {
    @NSApplicationDelegateAdaptor(CredentialExitDelegate.self) private var credentialExitDelegate
    private let store = MigrationStore()
    var body: some Scene {
        WindowGroup("Browser Bridge") {
            ManagerView(store: store)
                .frame(minWidth: 920, minHeight: 680)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1120, height: 860)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
enum Page: String, CaseIterable, Identifiable {
    case transfer = "Transfer", connections = "Connections", overview = "Overview", plan = "Transfer plan", support = "Browser support", packages = "Saved packages"
    var id: String { rawValue }
    var symbol: String { switch self { case .transfer: "arrow.left.arrow.right"; case .connections: "link"; case .overview: "square.grid.2x2"; case .plan: "arrow.triangle.branch"; case .support: "globe"; case .packages: "archivebox" } }
}
@MainActor @Observable final class MigrationStore {
    var showsCredentials = false
    var transferring = false
    var transferReceipt: TransferReceipt?
    var transferReceipts: [TransferReceipt] = []
    var transferHistory = true
    var transferGroups = false
    var gracefulQuitAcknowledged = false
    var connectorConnections: [ConnectorConnection] = []
    var pairingCode = ""
    var connectorLocation: URL?
    var profileAssociationConfirmed = false
    var profiles: [BrowserProfile] = []
    var targetProfiles: [BrowserProfile] = []
    var sourceBrowser: BrowserID = .zen
    var targetBrowser: BrowserID = .dia
    var selectedID = ""
    var targetID = ""
    var captureURL: URL?
    var portableOnly = false
    var destinationBackedUp = false
    var snapshot: Snapshot?
    var loading = false
    var creating = false
    private var scanGeneration = 0
    var error: String?
    var notice: String?
    var savedPaths: [String] = UserDefaults.standard.stringArray(forKey: "packages") ?? UserDefaults(suiteName: "local.zenbridge.manager")?.stringArray(forKey: "packages") ?? []
    var backupDirectory: URL? = UserDefaults.standard.url(forKey: "transferBackupDirectory")
    var page: Page = .transfer
    let demo = CommandLine.arguments.contains("--demo")

    // One-Click Migration
    var isMigratingOneClick = false
    var oneClickPhaseText = ""
    var oneClickProgress: Double = 0.0
    var oneClickPhaseStep: Int = 0
    var oneClickReceipt: OneClickReceipt?
    var oneClickReceipts: [OneClickReceipt] = []
    var openDestinationAfterMigration = true
    var closeDestinationBeforeMigrating = true
    var oneClickTransferBookmarks = true
    var oneClickTransferTabs = true
    var oneClickTransferGroups = true
    var oneClickTransferHistory = true

    var selected: BrowserProfile? { profiles.first { $0.id == selectedID } }
    var target: BrowserProfile? { targetProfiles.first { $0.id == targetID } }
    var packageURLs: [URL] { savedPaths.map { URL(fileURLWithPath: $0) } }
    var canCreate: Bool { !demo && !loading && !creating && !transferring && snapshot != nil && (portableOnly ? captureURL != nil : selected != nil) && (target != nil || destinationBackedUp) }

    var connectedSource: ConnectorConnection? { connectorConnections.first { $0.browser == sourceBrowser && $0.profilePath == selected?.path.standardizedFileURL.path } }
    var connectedDestination: ConnectorConnection? { connectorConnections.first { $0.browser == targetBrowser && $0.profilePath == target?.path.standardizedFileURL.path } }
    var automaticTransferReady: Bool {
        guard !demo, !transferring, backupDirectory != nil, gracefulQuitAcknowledged, let source = connectedSource, let destination = connectedDestination else { return false }
        return source.connected && destination.connected && AutomaticRoutes.allows(source, destination)
    }

    func refreshOneClickReceipts() {
        guard !demo else { return }
        Task { do {
            _ = try? OneClickMigrator.cleanTestReceipts()
            oneClickReceipts = try OneClickMigrator.receipts()
        } catch { print("OneClick receipts: \(error)") } }
    }

    func startOneClickMigration() {
        guard !isMigratingOneClick, !transferring else { return }

        if demo {
            isMigratingOneClick = true
            oneClickPhaseStep = 1
            oneClickProgress = 0.25
            oneClickPhaseText = "Inspecting demo \(sourceBrowser.name) profile data…"
            error = nil
            _ = Task {
                try await Task.sleep(for: .milliseconds(350))
                oneClickPhaseStep = 2
                oneClickProgress = 0.60
                oneClickPhaseText = "Simulating safe pre-migration backup of \(targetBrowser.name)…"
                try await Task.sleep(for: .milliseconds(400))
                oneClickPhaseStep = 3
                oneClickProgress = 0.90
                oneClickPhaseText = "Injecting bookmarks, tabs & groups into \(targetBrowser.name)…"
                try await Task.sleep(for: .milliseconds(350))
                oneClickPhaseStep = 4
                oneClickProgress = 1.0
                oneClickPhaseText = "Migration complete!"
                let receipt = OneClickReceipt(
                    sourceBrowser: sourceBrowser,
                    sourceProfilePath: "/demo/source",
                    destinationBrowser: targetBrowser,
                    destinationProfilePath: "/demo/target",
                    backupDirectoryPath: "/demo/backups",
                    migratedFolder: "Migrated from \(sourceBrowser.name)",
                    bookmarksCount: snapshot?.bookmarks.count ?? 8,
                    tabsCount: snapshot?.tabs.count ?? 2,
                    groupsCount: snapshot?.spaces.count ?? 2,
                    historyCount: oneClickTransferHistory ? (snapshot?.history.count ?? 150) : 0,
                    status: "complete"
                )
                oneClickReceipt = receipt
                oneClickReceipts.insert(receipt, at: 0)
                notice = "Successfully migrated from \(sourceBrowser.name) to \(targetBrowser.name) in 1 click! 🎉"
                isMigratingOneClick = false
            }
            return
        }

        guard let source = selected?.path else {
            error = "Select an existing source browser profile."
            return
        }
        var targetPath: URL
        if targetBrowser == .dia {
            if let root = targetBrowser.roots().first {
                targetPath = root
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser
                targetPath = home.appendingPathComponent("Library/Application Support/Dia/User Data")
            }
        } else if let chosen = target?.path {
            targetPath = chosen
        } else if let discovered = targetProfiles.first?.path {
            targetPath = discovered
        } else {
            if let root = targetBrowser.roots().first {
                targetPath = root.appendingPathComponent("Default")
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser
                targetPath = home.appendingPathComponent(targetBrowser.dataPaths.first ?? "Library/Application Support/\(targetBrowser.name)").appendingPathComponent("Default")
            }
        }

        isMigratingOneClick = true
        oneClickPhaseStep = 1
        oneClickProgress = 0.25
        oneClickPhaseText = "Reading \(sourceBrowser.name) profile data…"
        error = nil

        Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                oneClickPhaseStep = 2
                oneClickProgress = 0.60
                oneClickPhaseText = "Preserving \(targetBrowser.name) pre-migration backup safely…"
                try await Task.sleep(for: .milliseconds(350))
                oneClickPhaseStep = 3
                oneClickProgress = 0.90
                oneClickPhaseText = "Writing bookmarks, tabs, groups & history to \(targetBrowser.name)…"

                let opts = TransferOptions(
                    bookmarks: oneClickTransferBookmarks,
                    tabs: oneClickTransferTabs,
                    history: oneClickTransferHistory,
                    groups: oneClickTransferGroups
                )

                let receipt = try await OneClickMigrator.migrate(
                    sourceBrowser: sourceBrowser,
                    sourceProfile: source,
                    destinationBrowser: targetBrowser,
                    destinationProfile: targetPath,
                    options: opts,
                    backupDirectory: backupDirectory,
                    closeDestinationIfRunning: closeDestinationBeforeMigrating,
                    openDestination: openDestinationAfterMigration
                )

                oneClickPhaseStep = 4
                oneClickProgress = 1.0
                oneClickPhaseText = "Migration complete!"
                try await Task.sleep(for: .milliseconds(200))
                oneClickReceipt = receipt
                notice = "Successfully migrated from \(sourceBrowser.name) to \(targetBrowser.name) in 1 click! 🎉"
                refreshOneClickReceipts()
                isMigratingOneClick = false
            } catch {
                isMigratingOneClick = false
                oneClickProgress = 0.0
                oneClickPhaseStep = 0
                self.error = error.localizedDescription
            }
        }
    }

    func rollbackOneClick(_ receipt: OneClickReceipt) {
        let alert = NSAlert()
        alert.messageText = "Undo this migration?"
        alert.informativeText = "This will restore the \(receipt.destinationBrowser.name) profile from the pre-migration backup, removing migrated items while keeping any original destination bookmarks and tabs intact."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Roll back migration")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        Task {
            if demo {
                if let idx = oneClickReceipts.firstIndex(where: { $0.id == receipt.id }) {
                    oneClickReceipts[idx].status = "rolled-back"
                }
                if oneClickReceipt?.id == receipt.id {
                    oneClickReceipt?.status = "rolled-back"
                }
                notice = "Rollback complete. Restored \(receipt.destinationBrowser.name) pre-migration state."
                return
            }
            do {
                try await OneClickMigrator.rollback(receipt: receipt, closeDestinationIfRunning: closeDestinationBeforeMigrating)
                notice = "Rollback complete. Restored \(receipt.destinationBrowser.name) to its pre-migration backup."
                refreshOneClickReceipts()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func transferCoordinator() throws -> TransferCoordinator {
        guard let resources = Bundle.main.resourceURL else { throw ConnectorError.rejected("Open the packaged Mac app to transfer.") }
        return TransferCoordinator(store: try ConnectorStore(), lifecycle: MacBrowserLifecycle(), importerResources: resources.appendingPathComponent("Importer"))
    }
    func refreshTransfers() {
        refreshConnections()
        guard !demo else { return }
        Task { do { transferReceipts = try await transferCoordinator().receipts() } catch { self.error = error.localizedDescription } }
    }
    func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose where transfer backups are saved"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = backupDirectory
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        backupDirectory = folder
        UserDefaults.standard.set(folder, forKey: "transferBackupDirectory")
    }
    func startTransfer() {
        guard automaticTransferReady, let source = connectedSource, let destination = connectedDestination else { return }
        guard let backupDirectory else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let package = backupDirectory.appendingPathComponent("Browser Bridge \(stamp) \(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            let coordinator = try transferCoordinator()
            let options = TransferOptions(history: transferHistory, groups: transferGroups)
            transferring = true; error = nil
            _ = Task {
                let monitor = Task { while !Task.isCancelled { self.transferReceipt = await coordinator.currentReceipt; try? await Task.sleep(for: .milliseconds(400)) } }
                defer { monitor.cancel(); transferring = false; refreshTransfers() }
                do { transferReceipt = try await coordinator.transfer(source: source, destination: destination, package: package, options: options); notice = "Transfer verified. Review its receipt and retained backup." }
                catch { transferReceipt = await coordinator.currentReceipt; self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func recoverTransfer(_ receipt: TransferReceipt, rollback: Bool = false) {
        guard !demo, !transferring else { return }
        if rollback {
            let alert = NSAlert(); alert.messageText = "Roll back helper changes?"
            alert.informativeText = "This removes Browser Bridge’s bookmark trees, including any edits you made inside them. Only unchanged tabs in the same browser session can close. History, navigated tabs and tabs from earlier browser sessions are retained. Your original backup stays intact."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Roll back helper changes")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            let coordinator = try transferCoordinator(); transferring = true; error = nil
            _ = Task {
                let monitor = Task { while !Task.isCancelled { self.transferReceipt = await coordinator.currentReceipt; try? await Task.sleep(for: .milliseconds(400)) } }
                defer { monitor.cancel(); transferring = false; refreshTransfers() }
                do {
                    let url = URL(fileURLWithPath: receipt.receiptPath)
                    transferReceipt = rollback ? try await coordinator.rollback(receiptURL: url, confirmedOwnedBookmarkEditsRemoval: true) : try await coordinator.resume(receiptURL: url)
                    notice = "Recovery finished. Review its observed result and any retained items."
                } catch { transferReceipt = await coordinator.currentReceipt; self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancelUndelivered(_ receipt: TransferReceipt) {
        guard !demo, !transferring else { return }
        Task { do { transferReceipt = try await transferCoordinator().cancelUnclaimed(receiptURL: URL(fileURLWithPath: receipt.receiptPath)); refreshTransfers() } catch { self.error = error.localizedDescription } }
    }
    func refreshConnections() {
        guard !demo else { return }
        do { connectorConnections = try ConnectorStore().connections() } catch { self.error = error.localizedDescription }
    }
    func connectProfile() {
        guard !demo, let selected, profileAssociationConfirmed else { return }
        do {
            guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else { throw ConnectorError.rejected("Open the packaged Mac app to install the local connector.") }
            connectorLocation = try ConnectorInstallation.install(browser: sourceBrowser, executable: executable.deletingLastPathComponent().appendingPathComponent("browser-bridge-host"), resources: resources.appendingPathComponent("Connector"))
            pairingCode = try ConnectorStore().beginPairing(browser: sourceBrowser, profile: selected.path)
            notice = "Local host installed for \(sourceBrowser.name). Load the Connector folder in this exact browser profile, then paste the pairing code."
            NSWorkspace.shared.activateFileViewerSelecting([connectorLocation!])
            refreshConnections()
        } catch { self.error = error.localizedDescription }
    }
    func discover() {
        if demo {
            profiles = [.init(name: "Personal · demo", path: URL(fileURLWithPath: "/demo/source"))]; selectedID = profiles[0].id
            targetProfiles = [.init(name: "Main · demo", path: URL(fileURLWithPath: "/demo/target"))]; targetID = targetProfiles[0].id
            let json = #"{"spaces":[{"uuid":"work","name":"Work"},{"uuid":"home","name":"Personal"}],"folders":[{"id":"projects","name":"Projects","workspaceId":"work"},{"id":"research","name":"Research","parentId":"projects","workspaceId":"work"}],"tabs":[{"zenSyncId":"1","zenEssential":true,"pinned":true,"zenWorkspace":"home","entries":[{"url":"https://example.com","title":"Example"}]},{"zenSyncId":"2","zenWorkspace":"work","groupId":"research","entries":[{"url":"https://example.org","title":"Research"}]}]}"#
            snapshot = try? ZenReader.readSession(Data(json.utf8)); return
        }
        do {
            profiles = try BrowserReader.discover(browser: sourceBrowser)
            if !profiles.contains(where: { $0.id == selectedID }) { selectedID = profiles.first?.id ?? "" }
            discoverTargets(); scan()
        } catch { scanGeneration += 1; profiles = []; selectedID = ""; snapshot = nil; self.error = "\(sourceBrowser.name) discovery: \(error.localizedDescription). Choose a profile folder manually or use a portable file."; loading = false }
    }
    func discoverTargets() {
        guard !demo else { return }
        do {
            targetProfiles = try BrowserReader.discover(browser: targetBrowser)
            if !targetProfiles.contains(where: { $0.id == targetID }) { targetID = targetProfiles.first?.id ?? "" }
        } catch { targetProfiles = []; targetID = ""; self.error = "Could not discover destination profiles. Choose its folder manually, or confirm a new/separately backed-up profile." }
        destinationBackedUp = false
    }
    func changeSource() { profileAssociationConfirmed = false; pairingCode = ""; scanGeneration += 1; profiles = []; selectedID = ""; snapshot = nil; captureURL = nil; portableOnly = false; notice = nil; discover() }
    func scan() {
        profileAssociationConfirmed = false; pairingCode = ""
        guard !demo, !creating else { return }
        scanGeneration += 1; let generation = scanGeneration
        let source = selected?.path, browser = sourceBrowser, captureFile = captureURL, portable = portableOnly
        guard (portable && captureFile != nil) || source != nil else { snapshot = nil; loading = false; return }
        loading = true; snapshot = nil; error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> Snapshot in
                    var value = portable ? Snapshot() : try BrowserReader.read(profile: source!, browser: browser)
                    if let captureFile { value = try PortableCapture.load(captureFile, expectedBrowser: browser).supplement(value) }
                    if portable { value.warnings.append("Portable-file-only mode: the source profile will not be read or backed up.") }
                    return value
                }
            }.value
            guard self.scanGeneration == generation else { return }
            loading = false
            switch result { case .success(let value): snapshot = value; case .failure(let e): error = e.localizedDescription }
        }
    }
    func chooseProfile(destination: Bool = false) {
        let panel = NSOpenPanel(); panel.title = "Choose \(destination ? targetBrowser.name : sourceBrowser.name) profile folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let profile = BrowserProfile(name: url.lastPathComponent, path: url)
        if destination { if !targetProfiles.contains(profile) { targetProfiles.append(profile) }; targetID = profile.id }
        else { if !profiles.contains(profile) { profiles.append(profile) }; selectedID = profile.id; scan() }
    }
    func attachPortable() {
        let panel = NSOpenPanel(); panel.title = "Attach live capture JSON or exported bookmarks HTML"
        panel.allowedContentTypes = [.json, .html]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try PortableCapture.load(url, expectedBrowser: sourceBrowser); captureURL = url; if selected == nil { portableOnly = true }; notice = "Attached \(url.lastPathComponent). Check its browser/profile and freshness before packaging."; scan() }
        catch { self.error = error.localizedDescription }
    }
    func captureNativeWindows() {
        guard !demo, !loading, !creating, !transferring, sourceBrowser == .arc || sourceBrowser == .safari else { return }
        let browser = sourceBrowser
        let alert = NSAlert()
        alert.messageText = "Read exposed \(browser.name) windows?"
        alert.informativeText = "This optional capture reads the running browser’s exposed windows, which may span profiles. It is not limited to the selected profile folder. Close private Safari windows first; its scripting interface cannot identify them. Review the saved capture and preview before packaging. macOS may ask for Automation permission. No browser data is changed."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Capture open windows")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let panel = NSSavePanel()
        panel.title = "Save read-only \(browser.name) native capture"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Browser Bridge \(browser.name) Native Capture.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do {
                let capture = try await NativeBrowserCapture.portableCapture(browser: browser)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(capture).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if sourceBrowser == browser {
                    captureURL = url
                    if selected == nil { portableOnly = true }
                    notice = "Native capture attached. Review exposed-window/profile coverage, freshness and the preview before creating a package. Native destination structures are not recreated automatically."
                    scan()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func saveCaptureHelper() {
        guard sourceBrowser.family != .safari else { return }
        let panel = NSSavePanel(); panel.title = "Save \(sourceBrowser.name) capture helper"; panel.nameFieldStringValue = "Browser Bridge Capture - \(sourceBrowser.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HelperBundle.write(from: Bundle.main.resourceURL!.appendingPathComponent("Exporter"), to: url, browser: sourceBrowser)
            notice = "Capture helper saved. Load it in \(sourceBrowser.name) via \(sourceBrowser.extensionsPage), then use its toolbar icon to save a capture JSON. Attach that file here. Native spaces/Favorites may remain archive-only."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { self.error = error.localizedDescription }
    }
    func createPackage() {
        guard canCreate else { return }
        do {
            let active = try PackageBuilder.activeBrowsers(portableOnly ? [targetBrowser] : [sourceBrowser, targetBrowser])
            guard active.isEmpty else { error = "Quit \(active.joined(separator: " and ")) with ⌘Q, then try again. Selected browsers must stay closed while profiles are backed up."; return }
        } catch { self.error = error.localizedDescription; return }
        let panel = NSSavePanel(); panel.title = "Save migration package"; panel.prompt = "Create package"; panel.canCreateDirectories = true
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "Browser Bridge \(sourceBrowser.name) to \(targetBrowser.name) \(formatter.string(from: Date()))"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let resources = Bundle.main.resourceURL!.appendingPathComponent("Importer")
        let source = selected?.path, target = target?.path, input = captureURL, portable = portableOnly, from = sourceBrowser, to = targetBrowser
        creating = true; error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> PackageResult in
                    let builder = PackageBuilder(importerResources: resources)
                    if portable, let input { return try builder.createPortable(input: input, sourceBrowser: from, targetBrowser: to, targetProfile: target, destination: destination) }
                    guard let source else { throw BridgeError.message("Select a source profile first.") }
                    return try builder.create(source: source, sourceBrowser: from, targetBrowser: to, targetProfile: target, destination: destination, captureURL: input)
                }
            }.value
            creating = false
            switch result {
            case .success(let package):
                snapshot = package.snapshot; savedPaths.removeAll { $0 == package.url.path }; savedPaths.insert(package.url.path, at: 0)
                UserDefaults.standard.set(savedPaths, forKey: "packages"); page = .packages
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
    func addPackage() {
        let panel = NSOpenPanel(); panel.title = "Locate a Browser Bridge package"; panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("snapshot.json").path), FileManager.default.fileExists(atPath: url.appendingPathComponent("READ ME.md").path) else { error = "Choose the package folder containing snapshot.json and READ ME.md."; return }
        savedPaths.removeAll { $0 == url.path }; savedPaths.insert(url.path, at: 0); UserDefaults.standard.set(savedPaths, forKey: "packages")
    }
}
enum AppleDesign {
    static let actionBlue = Color.accentColor
    static let skyBlue = Color(nsColor: .linkColor)
    static let systemGreen = Color(nsColor: .systemGreen)
    static let systemIndigo = Color(nsColor: .systemIndigo)
    static let systemOrange = Color(nsColor: .systemOrange)
    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.88)
}

struct NativeGroupSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
            )
    }
}

extension View {
    func nativeGroupSurface(cornerRadius: CGFloat = 10) -> some View {
        modifier(NativeGroupSurfaceModifier(cornerRadius: cornerRadius))
    }

    func liquidGlassCard(cornerRadius: CGFloat = 10, tint: Color = .clear, isElevated: Bool = false) -> some View {
        modifier(NativeGroupSurfaceModifier(cornerRadius: cornerRadius))
    }
}

struct ManagerView: View {
    @Bindable var store: MigrationStore
    private let accent = Color.accentColor

    private func browserBadgeIcon(for browser: BrowserID) -> (symbol: String, color: Color) {
        switch browser {
        case .safari: return ("safari.fill", .blue)
        case .zen: return ("circle.hexagongrid.fill", .primary)
        case .dia: return ("sparkles", .indigo)
        case .arc: return ("rays", .pink)
        case .brave: return ("shield.lefthalf.filled", .orange)
        case .firefox: return ("flame.fill", .orange)
        case .chrome: return ("globe", .blue)
        case .helium: return ("bolt.circle.fill", .cyan)
        case .edge: return ("wave.3.right.circle.fill", .teal)
        case .opera: return ("circle.circle.fill", .red)
        case .vivaldi: return ("v.circle.fill", .red)
        }
    }

    private func settingsIconBadge(symbol: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.gradient)
                .frame(width: 24, height: 24)
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var transfer: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Native macOS Settings Header
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Browser Migration")
                        .font(.title2.weight(.semibold))
                    Text("Transfer bookmarks, open tabs, spaces, and history directly between local browser profiles.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 2)

            // Section 1: Route (Source & Destination)
            VStack(alignment: .leading, spacing: 6) {
                Text("Migration Route")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    // Source Browser Row
                    HStack(spacing: 12) {
                        let badge = browserBadgeIcon(for: store.sourceBrowser)
                        settingsIconBadge(symbol: badge.symbol, color: badge.color)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Source Browser")
                                .font(.body.weight(.medium))
                            if store.loading {
                                Text("Scanning profile…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let s = store.snapshot {
                                Text("\(s.bookmarks.count.formatted()) bookmarks · \(s.tabs.count.formatted()) tabs · \(s.spaces.count.formatted()) spaces · \(s.history.count.formatted()) history items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            } else {
                                Text("No profile data loaded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Picker("Source Browser", selection: $store.sourceBrowser) {
                            ForEach(BrowserID.allCases) { browser in
                                Text(browser.name).tag(browser)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        Picker("Source Profile", selection: $store.selectedID) {
                            if store.profiles.isEmpty {
                                Text("No profile").tag("")
                            }
                            ForEach(store.profiles) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 165)

                        Button("Choose…") { store.chooseProfile() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    Divider().padding(.leading, 50)

                    // Destination Browser Row
                    HStack(spacing: 12) {
                        let badge = browserBadgeIcon(for: store.targetBrowser)
                        settingsIconBadge(symbol: badge.symbol, color: badge.color)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Destination Browser")
                                .font(.body.weight(.medium))
                            if store.targetBrowser == .dia {
                                if let spaces = store.snapshot?.spaces, !spaces.isEmpty {
                                    Text("Automatically maps \(spaces.count) \(store.sourceBrowser.name) spaces, essentials, and history into Dia")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Automatically maps spaces, pinned tabs, and history into Dia")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Direct local profile injection with automatic pre-migration backup")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Picker("Destination Browser", selection: $store.targetBrowser) {
                            ForEach(BrowserID.allCases) { browser in
                                Text(browser.name).tag(browser)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)

                        if store.targetBrowser == .dia {
                            Text("All Spaces")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 165, alignment: .trailing)
                        } else {
                            Picker("Destination Profile", selection: $store.targetID) {
                                if store.targetProfiles.isEmpty {
                                    Text("Default").tag("")
                                }
                                ForEach(store.targetProfiles) { p in
                                    Text(p.name).tag(p.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 165)
                        }

                        Button("Choose…") { store.chooseProfile(destination: true) }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .nativeGroupSurface()
            }

            // Section 2: Data Categories & Options (Inset Grouped Form Rows)
            VStack(alignment: .leading, spacing: 6) {
                Text("Items to Transfer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    settingsToggleRow(
                        title: "Bookmarks & Folders",
                        subtitle: "Preserves bookmark bar, hierarchy, and nested folders",
                        symbol: "book.closed.fill",
                        color: .orange,
                        isOn: $store.oneClickTransferBookmarks
                    )
                    Divider().padding(.leading, 50)
                    settingsToggleRow(
                        title: "Open Tabs & Pinned Favorites",
                        subtitle: "Transfers Essentials, pinned sidebar tiles, and open tabs",
                        symbol: "macwindow.on.rectangle",
                        color: .blue,
                        isOn: $store.oneClickTransferTabs
                    )
                    Divider().padding(.leading, 50)
                    settingsToggleRow(
                        title: "Spaces & Tab Groups",
                        subtitle: "Maps workspaces and tab groups to destination profiles",
                        symbol: "square.grid.2x2.fill",
                        color: .indigo,
                        isOn: $store.oneClickTransferGroups
                    )
                    Divider().padding(.leading, 50)
                    settingsToggleRow(
                        title: "Browsing History",
                        subtitle: "Copies visited URLs, page titles, and timestamps for autocomplete",
                        symbol: "clock.fill",
                        color: .green,
                        isOn: $store.oneClickTransferHistory
                    )
                }
                .nativeGroupSurface()
            }

            // Section 3: Behavior & Action Bar
            VStack(alignment: .leading, spacing: 6) {
                Text("Options")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    HStack {
                        settingsIconBadge(symbol: "power.circle.fill", color: .gray)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Quit \(store.targetBrowser.name) before migrating")
                                .font(.body)
                            Text("Safely closes \(store.targetBrowser.name) so profile databases are unlocked during backup and write")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.closeDestinationBeforeMigrating)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 50)

                    HStack {
                        settingsIconBadge(symbol: "arrow.up.forward.app.fill", color: .blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Reopen \(store.targetBrowser.name) when finished")
                                .font(.body)
                            Text("Launches \(store.targetBrowser.name) and restores your spaces and pinned tabs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $store.openDestinationAfterMigration)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider()

                    // Action Footer Bar inside the Group
                    if store.isMigratingOneClick {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(store.oneClickPhaseText)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Int(store.oneClickProgress * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: store.oneClickProgress, total: 1.0)
                                .progressViewStyle(.linear)
                            HStack(spacing: 16) {
                                StepIndicator(step: 1, current: store.oneClickPhaseStep, title: "Inspect")
                                StepIndicator(step: 2, current: store.oneClickPhaseStep, title: "Backup")
                                StepIndicator(step: 3, current: store.oneClickPhaseStep, title: "Transfer")
                                StepIndicator(step: 4, current: store.oneClickPhaseStep, title: "Complete")
                            }
                        }
                        .padding(14)
                    } else {
                        HStack {
                            Label("Pre-migration backup is created automatically before any changes.", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                store.startOneClickMigration()
                            } label: {
                                Text("Migrate to \(store.targetBrowser.name)")
                                    .padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(store.selected == nil && !store.demo)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
                    }
                }
                .nativeGroupSurface()
            }

            // Latest Receipt Banner (if just completed)
            if let receipt = store.oneClickReceipt {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Migration to \(receipt.destinationBrowser.name) Complete")
                                .font(.headline)
                            Text("\(receipt.bookmarksCount.formatted()) bookmarks · \(receipt.tabsCount.formatted()) tabs · \(receipt.groupsCount.formatted()) spaces · \(receipt.historyCount.formatted()) history items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("Show Backup in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.backupDirectoryPath)])
                        }
                        .controlSize(.small)

                        Button("Undo Migration…") {
                            store.rollbackOneClick(receipt)
                        }
                        .controlSize(.small)

                        Button("Open \(receipt.destinationBrowser.name)") {
                            _ = OneClickMigrator.launchDestinationWithTabs(browser: receipt.destinationBrowser, tabs: store.snapshot?.tabs ?? [])
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .nativeGroupSurface()
            }

            // Section 4: Migration History & Backups
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Previous Migrations")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { store.refreshOneClickReceipts() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    if store.oneClickReceipts.isEmpty {
                        HStack {
                            Text("No previous migrations recorded on this Mac.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(14)
                    } else {
                        ForEach(Array(store.oneClickReceipts.enumerated()), id: \.element.id) { index, receipt in
                            if index > 0 {
                                Divider().padding(.leading, 14)
                            }
                            HStack(spacing: 12) {
                                let isRolledBack = receipt.status == "rolled-back"
                                Circle()
                                    .fill(isRolledBack ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("\(receipt.sourceBrowser.name) → \(receipt.destinationBrowser.name)")
                                            .font(.body.weight(.medium))
                                        Text(isRolledBack ? "Rolled Back" : "Completed")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(isRolledBack ? .orange : .secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Color.primary.opacity(0.06), in: Capsule())
                                    }
                                    Text("\(receipt.bookmarksCount.formatted()) bookmarks · \(receipt.tabsCount.formatted()) tabs · \(receipt.groupsCount.formatted()) spaces · \(receipt.historyCount.formatted()) history · \(receipt.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer()
                                if receipt.status != "rolled-back" {
                                    Button("Revert…") {
                                        store.rollbackOneClick(receipt)
                                    }
                                    .controlSize(.small)
                                }
                                Button("Show Backup") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.backupDirectoryPath)])
                                }
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .nativeGroupSurface()
            }
        }
        .onAppear {
            store.refreshTransfers()
            store.refreshOneClickReceipts()
        }
    }

    private func settingsToggleRow(title: String, subtitle: String, symbol: String, color: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            settingsIconBadge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect a Browser Profile")
                    .font(.title2.weight(.semibold))
                Text("Install once in each profile. The local connector receives only operations you start in this Mac app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("1. Confirm the selected source profile").font(.headline)
                Text(store.selected?.path.path ?? "Choose a source profile above.")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Toggle("I checked this folder against the profile path shown in this browser’s version/support page.", isOn: $store.profileAssociationConfirmed)
                Text("Extensions cannot report their filesystem profile path. This confirmation associates the chosen folder with the connector you install.").font(.caption).foregroundStyle(.secondary)
                Button("Install Local Host & Create Pairing Code", action: store.connectProfile)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.demo || store.selected == nil || !store.profileAssociationConfirmed || store.sourceBrowser == .safari)
                if !store.pairingCode.isEmpty {
                    Divider()
                    Text("2. Load the Connector folder in \(store.sourceBrowser.name)").font(.headline)
                    Text(store.sourceBrowser.family == .firefox ? "Open about:debugging → This Firefox → Load Temporary Add-on, then choose manifest.json. Temporary installation disappears when Firefox/Zen exits; reconnect it after restart." : "Open chrome://extensions, enable Developer mode, choose Load unpacked and select the revealed folder.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("3. Open the connector toolbar button and paste this code (expires in ten minutes)").font(.headline)
                    HStack(spacing: 12) {
                        Text(store.pairingCode)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button("Copy Code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.pairingCode, forType: .string)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativeGroupSurface()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Connected Profiles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh", action: store.refreshConnections)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    if store.connectorConnections.isEmpty {
                        Text("No profiles connected yet. Safari uses the guided file transfer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(store.connectorConnections.enumerated()), id: \.element.id) { index, connection in
                            if index > 0 { Divider().padding(.leading, 14) }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(connection.browser.name) · \(connection.label)").font(.body.weight(.medium))
                                    Spacer()
                                    Text(connection.connected ? "Connected" : "Waiting for browser")
                                        .font(.caption)
                                        .foregroundStyle(connection.connected ? .green : .secondary)
                                }
                                Text(connection.profilePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let version = connection.browserVersion { Text("Observed browser version: \(version)").font(.caption).foregroundStyle(.secondary) }
                                if let executable = connection.browserExecutable { Text(executable).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
                                HStack {
                                    Text("Connection is separate from automatic transfer verification.").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Disconnect") { do { try ConnectorStore().disconnect(connection.id); store.refreshConnections() } catch { store.error = error.localizedDescription } }
                                        .controlSize(.small)
                                }
                            }
                            .padding(14)
                        }
                    }
                }
                .nativeGroupSurface()
            }
        }.onAppear(perform: store.refreshConnections)
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $store.page) { page in
                Label(page.rawValue, systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("100% Local on This Mac")
                            .font(.caption.weight(.medium))
                    }
                    Text("Zero cloud uploads · MIT License")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if store.demo {
                        Text("Demo data · export disabled")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 250)
        } detail: {
            VStack(spacing: 0) {
                if store.page != .transfer {
                    routeControls
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.bar)
                        .disabled(store.transferring)
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch store.page {
                        case .transfer: transfer
                        case .connections: connections
                        case .overview: overview
                        case .plan: plan
                        case .support: support
                        case .packages: packages
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                if store.page != .transfer {
                    Divider()
                    HStack(spacing: 12) {
                        if store.creating {
                            ProgressView().controlSize(.small)
                            Text("Verifying backups… Keep both browsers closed.").font(.callout)
                        } else {
                            Label(store.portableOnly ? "Portable input; source profile not backed up." : "Originals stay intact. Import adds to the destination.", systemImage: "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Create Migration Package…", action: store.createPackage)
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canCreate)
                            .keyboardShortcut("e", modifiers: [.command])
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.bar)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(store.page.rawValue)
            .toolbar {
                Button { store.showsCredentials = true } label: { Label("Passwords", systemImage: "key.horizontal") }.disabled(store.demo)
                Button { store.discover() } label: { Label("Rescan Profiles", systemImage: "arrow.clockwise") }.disabled(store.loading || store.creating)
            }
        }
        .tint(accent)
        .task { store.discover() }
        .sheet(isPresented: $store.showsCredentials) { CredentialView() }
        .onChange(of: store.selectedID) { _, _ in store.scan() }
        .onChange(of: store.sourceBrowser) { _, _ in store.changeSource() }
        .onChange(of: store.targetBrowser) { _, _ in store.discoverTargets() }
        .onChange(of: store.portableOnly) { _, _ in store.scan() }
        .alert("Couldn’t complete that step", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }

    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 8) {
                    Picker("From", selection: $store.sourceBrowser) { ForEach(BrowserID.allCases) { Text($0.name).tag($0) } }
                        .frame(width: 150)
                    Picker("Profile", selection: $store.selectedID) {
                        if store.profiles.isEmpty { Text("No detected profile").tag("") }
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Button("Choose…") { store.chooseProfile() }
                        .controlSize(.small)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("To", selection: $store.targetBrowser) { ForEach(BrowserID.allCases) { Text($0.name).tag($0) } }
                        .frame(width: 140)
                    if store.targetBrowser == .dia {
                        Text("Spaces auto-mapped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Profile", selection: $store.targetID) {
                            Text("New / backed up").tag("")
                            ForEach(store.targetProfiles) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        Button("Choose…") { store.chooseProfile(destination: true) }
                            .controlSize(.small)
                    }
                }
                Spacer()
            }.disabled(store.creating || store.transferring || store.demo)
            if store.target == nil && store.targetBrowser != .dia {
                Toggle("Destination is a new or separately backed-up profile", isOn: $store.destinationBackedUp)
                    .font(.caption)
                    .disabled(store.creating || store.transferring || store.demo)
            }
        }
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Supported Browsers")
                    .font(.title2.weight(.semibold))
                Text("Support is shown by format and data category; a shared engine does not prove a vendor build was tested.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(BrowserID.allCases.enumerated()), id: \.element.id) { index, browser in
                    if index > 0 { Divider().padding(.leading, 50) }
                    HStack(alignment: .top, spacing: 12) {
                        let badge = browserBadgeIcon(for: browser)
                        settingsIconBadge(symbol: badge.symbol, color: badge.color)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(browser.name).font(.body.weight(.medium))
                                Spacer()
                                Text(browser.family.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(browser.family == .safari ? "Source: readable bookmarks/history files or exported HTML. Destination: manual bookmark HTML import. Native tabs/groups and authenticated sessions stay archived." : "Source: profile bookmarks/history plus optional live capture for exposed tabs, pins and groups. Destination: direct local profile injection or WebExtension helper.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .nativeGroupSurface()

            note(title: "Verification Boundaries", text: "Discovery fixtures cover all eleven names. Source-decoder fixtures cover the Chromium, Firefox/Zen and Safari families. Safari lists data folders, not named profiles, and may require macOS privacy access; portable HTML avoids reading the source profile.", symbol: "checkmark.seal")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profile Overview")
                    .font(.title2.weight(.semibold))
                Text("Inspect discovered items in your selected source profile before migrating or creating an archive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if store.sourceBrowser == .arc || store.sourceBrowser == .safari {
                        Button("Capture Open Windows…", action: store.captureNativeWindows)
                            .controlSize(.small)
                            .disabled(store.loading)
                    }
                    if store.sourceBrowser.family != .safari {
                        Button("Save Capture Helper…", action: store.saveCaptureHelper)
                            .controlSize(.small)
                    }
                    Button("Attach Capture / Bookmarks HTML…", action: store.attachPortable)
                        .controlSize(.small)
                    Spacer()
                }.disabled(store.creating || store.transferring || store.demo)

                Text(store.sourceBrowser.family == .safari ? "Safari: optionally capture exposed ordinary windows, or attach a bookmarks HTML export." : "Optional: attach a live session capture JSON or portable bookmarks HTML file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let capture = store.captureURL {
                    Text("Attached: \(capture.lastPathComponent)").font(.caption).textSelection(.enabled)
                    Toggle("Portable file only — source profile is not read or backed up", isOn: $store.portableOnly).font(.caption).disabled(store.creating)
                }
                if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .padding(14)
            .nativeGroupSurface()

            if store.loading {
                HStack { ProgressView().controlSize(.small); Text("Reading source data…").font(.subheadline).foregroundStyle(.secondary) }.padding(.vertical, 16)
            } else if let s = store.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.portableOnly ? "Portable Input Summary" : "Source Profile Summary")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        count("Open Tabs", s.tabs.count)
                        count("Essentials", s.tabs.filter(\.essential).count)
                        count("Pinned Tabs", s.tabs.filter { $0.pinned && !$0.essential }.count)
                        count("Spaces", s.spaces.count)
                        count("Folders & Groups", s.folders.count)
                        count("History Entries", s.history.count)
                    }
                }

                Text("Source: \(s.sourceFile.isEmpty ? "Demo session" : s.sourceFile)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !s.warnings.isEmpty {
                    note(title: "Profile Notes", text: s.warnings.joined(separator: "\n"), symbol: "exclamationmark.triangle")
                }

                HStack {
                    Button("Review Transfer Plan") { store.page = .plan }
                    Button("Go to 1-Click Migration") { store.page = .transfer }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Choose a Source Profile", systemImage: "folder", description: Text("Select a detected profile, choose its folder, or attach a portable JSON/bookmarks HTML file."))
            }
        }
    }

    private func count(_ name: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeGroupSurface(cornerRadius: 8)
        .accessibilityElement(children: .combine)
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transfer Plan")
                    .font(.title2.weight(.semibold))
                Text("Capability map for migrating from \(store.sourceBrowser.name) to \(store.targetBrowser.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                let rows = BrowserSupport.rows(source: store.sourceBrowser, target: store.targetBrowser)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 14) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.category).font(.body.weight(.medium))
                            Spacer()
                            Text(row.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .nativeGroupSurface()
            note(title: "Before Creating a Package", text: "Quit the selected browsers with ⌘Q. The app verifies copies of the selected profiles. Packages contain sensitive data; keep them on an encrypted disk.", symbol: "externaldrive.badge.checkmark")
        }
    }

    private var packages: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved Packages")
                        .font(.title2.weight(.semibold))
                    Text("Portable migration archives exported on this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Existing Package…", action: store.addPackage)
                    .disabled(store.creating)
            }

            if store.packageURLs.isEmpty {
                ContentUnavailableView("No Saved Packages", systemImage: "archivebox", description: Text("Create a portable package from the Transfer Plan tab, or use Transfer for direct 1-click profile migration."))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.packageURLs.enumerated()), id: \.element.path) { index, url in
                        if index > 0 { Divider().padding(.leading, 14) }
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.body.weight(.medium))
                                Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .controlSize(.small)
                            Button("Read Steps") { NSWorkspace.shared.open(url.appendingPathComponent("READ ME.md")) }
                                .controlSize(.small)
                            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
                                .controlSize(.small)
                        }
                        .padding(14)
                    }
                }
                .nativeGroupSurface()
            }
        }
    }

    private func note(title: String, text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeGroupSurface()
    }
}

struct StepIndicator: View {
    let step: Int
    let current: Int
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            if current > step {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if current == step {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    .frame(width: 9, height: 9)
            }
            Text(title)
                .font(.caption)
                .fontWeight(current == step ? .medium : .regular)
                .foregroundStyle(current >= step ? .primary : .secondary)
        }
    }
}
