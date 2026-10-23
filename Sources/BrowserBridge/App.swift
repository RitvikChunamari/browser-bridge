import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BridgeCore

@main struct BrowserBridgeApp: App {
    private let store = MigrationStore()
    var body: some Scene {
        WindowGroup("Browser Bridge") { ManagerView(store: store).frame(minWidth: 900, minHeight: 680) }
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
    var transferring = false
    var transferReceipt: TransferReceipt?
    var transferReceipts: [TransferReceipt] = []
    var transferHistory = false
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
            Task {
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
            Task {
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
struct ManagerView: View {
    @Bindable var store: MigrationStore
    private let accent = Color(red: 0.18, green: 0.38, blue: 0.26)
    private var transfer: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Bring your browser with you").font(.largeTitle.weight(.semibold))
            Text("After connecting both profiles, a verified route captures live data, closes the browsers normally, saves a checksummed backup, reopens the exact destination and checks both the imported result and your existing destination tabs and bookmarks.").foregroundStyle(.secondary)
            GroupBox("Selected route") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("\(store.sourceBrowser.name) → \(store.targetBrowser.name)", systemImage: "arrow.right").font(.title2.weight(.semibold))
                    Text("Source: \(store.connectedSource?.label ?? "Connect the selected profile")")
                    Text("Destination: \(store.connectedDestination?.label ?? "Connect the selected profile")")
                    if let a = store.connectedSource, let b = store.connectedDestination, AutomaticRoutes.allows(a, b) {
                        Label("This exact browser-version route has lifecycle verification", systemImage: "checkmark.seal").foregroundStyle(.green)
                    } else {
                        Text("Automatic transfer is unavailable for this route. Connection and browser-family similarity do not establish lifecycle acceptance. Create a guided migration package below.").foregroundStyle(.secondary)
                    }
                    Toggle("Include history (requires permission in both profiles)", isOn: $store.transferHistory)
                    Toggle("Preserve portable tab groups (requires permission in both profiles)", isOn: $store.transferGroups)
                    Text("Tabs, pin states, nested bookmark folders and portable window/group approximations are included. Native spaces, credentials and active sessions have guided or archive-only limits.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Backup folder").font(.headline)
                            Text(store.backupDirectory?.path ?? "Choose once. Each transfer creates its own retained backup.").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(store.backupDirectory == nil ? "Choose folder…" : "Change…", action: store.chooseBackupDirectory)
                    }
                    if store.connectedSource == nil || store.connectedDestination == nil {
                        Button("Set up browser connections") { store.page = .connections }
                    }
                    Toggle("I understand that Transfer requests a normal quit of all windows in the selected browser apps, and may pause for unsaved-work prompts.", isOn: $store.gracefulQuitAcknowledged)
                    Button("Transfer", action: store.startTransfer).buttonStyle(.borderedProminent).tint(accent).controlSize(.large).disabled(!store.automaticTransferReady)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(store.transferring)
            if let receipt = store.transferReceipt {
                GroupBox("Current transfer") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { if store.transferring { ProgressView().controlSize(.small) }; Text(receipt.phase.rawValue).font(.headline) }
                        if let error = receipt.error { Text(error).foregroundStyle(.secondary) }
                        Text(receipt.packagePath).font(.caption).textSelection(.enabled)
                        Text("The receipt records each phase. A paused or mismatched transfer is not reported as complete.").font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack { Text("Transfer receipts").font(.title2.weight(.semibold)); Spacer(); Button("Refresh", action: store.refreshTransfers) }
            if store.transferReceipts.isEmpty { Text("No coordinated transfers yet. Guided exports remain available in Saved packages.").foregroundStyle(.secondary) }
            ForEach(store.transferReceipts) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(receipt.source.browser.name) → \(receipt.destination.browser.name) · \(receipt.phase.rawValue)").font(.headline)
                    Text(receipt.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    if let error = receipt.error { Text(error).font(.callout) }
                    Text("\(receipt.source.label) → \(receipt.destination.label)").font(.caption)
                    Text(receipt.destination.profilePath).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Reveal receipt") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.receiptPath)]) }
                        if [.paused, .capturing, .capturingDestination, .closing, .backingUp, .reopening, .importing, .verifying, .checkingDestination, .rollingBack].contains(receipt.phase) {
                            Button("Resume") { store.recoverTransfer(receipt) }.disabled(store.transferring)
                        }
                        if receipt.packageID != nil && [.complete, .paused, .rollbackPartial].contains(receipt.phase) {
                            Button("Roll back…") { store.recoverTransfer(receipt, rollback: true) }.disabled(store.transferring)
                        }
                        if receipt.phase == .paused {
                            Button("Cancel undelivered operation") { store.cancelUndelivered(receipt) }.disabled(store.transferring)
                        }
                    }
                    if receipt.phase == .rollbackPartial { Text("Some items were retained. Read the receipt before making further changes.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
            }
        }.onAppear(perform: store.refreshTransfers)
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect a browser profile").font(.largeTitle.weight(.semibold))
            Text("Install once in each profile. The local connector receives only operations you start in this Mac app.").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Confirm the selected source profile").font(.headline)
                    Text(store.selected?.path.path ?? "Choose a source profile above.").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Toggle("I checked this folder against the profile path shown in this browser’s version/support page.", isOn: $store.profileAssociationConfirmed)
                    Text("Extensions cannot report their filesystem profile path. This confirmation associates the chosen folder with the connector you install.").font(.caption).foregroundStyle(.secondary)
                    Button("Install local host and create pairing code", action: store.connectProfile).disabled(store.demo || store.selected == nil || !store.profileAssociationConfirmed || store.sourceBrowser == .safari)
                    if !store.pairingCode.isEmpty {
                        Text("2. Load the Connector folder in \(store.sourceBrowser.name)").font(.headline)
                        Text(store.sourceBrowser.family == .firefox ? "Open about:debugging → This Firefox → Load Temporary Add-on, then choose manifest.json. Temporary installation disappears when Firefox/Zen exits; reconnect it after restart." : "Open chrome://extensions, enable Developer mode, choose Load unpacked and select the revealed folder.")
                        Text("3. Open the connector toolbar button and paste this code (expires in ten minutes)").font(.headline)
                        HStack { Text(store.pairingCode).font(.system(.callout, design: .monospaced)).textSelection(.enabled); Button("Copy code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.pairingCode, forType: .string) } }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Text("Connected profiles").font(.title2.weight(.semibold)); Spacer(); Button("Refresh", action: store.refreshConnections) }
            if store.connectorConnections.isEmpty { Text("No profiles connected yet. Safari uses the guided file transfer.").foregroundStyle(.secondary) }
            ForEach(store.connectorConnections) { connection in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("\(connection.browser.name) · \(connection.label)").font(.headline); Spacer(); Text(connection.connected ? "Connected" : "Waiting for browser").foregroundStyle(connection.connected ? .green : .secondary) }
                    Text(connection.profilePath).font(.caption).textSelection(.enabled)
                    if let version = connection.browserVersion { Text("Observed browser version: \(version)").font(.caption).foregroundStyle(.secondary) }
                    if let executable = connection.browserExecutable { Text(executable).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
                    Text("Connection is separate from automatic transfer verification. Unverified browser pairs use the guided flow.").font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect") { do { try ConnectorStore().disconnect(connection.id); store.refreshConnections() } catch { store.error = error.localizedDescription } }
                }.padding(.vertical, 8)
            }
        }.onAppear(perform: store.refreshConnections)
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 9) { Image(nsImage: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("app-icon.png")) ?? NSImage()).resizable().frame(width: 28, height: 28); Text("Browser Bridge").font(.headline) }.padding(.top, 22)
                List(Page.allCases, selection: $store.page) { page in Label(page.rawValue, systemImage: page.symbol).tag(page) }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Stays on this Mac", systemImage: "lock.shield").font(.callout.weight(.medium))
                    Text("Free and open source · MIT").font(.caption).foregroundStyle(.secondary)
                    Text("No uploads or paid services.").font(.caption).foregroundStyle(.secondary)
                    if store.demo { Text("Demo data · export disabled").font(.caption).foregroundStyle(.orange) }
                }.padding(.bottom, 22)
            }.padding(.horizontal, 16).navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
        } detail: {
            VStack(spacing: 0) {
                routeControls.padding(20).disabled(store.transferring)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        switch store.page { case .transfer: transfer; case .connections: connections; case .overview: overview; case .plan: plan; case .support: support; case .packages: packages }
                    }.padding(32).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 12) {
                    if store.creating { ProgressView().controlSize(.small); Text("Verifying backups… Keep both browsers closed.").font(.callout) }
                    else { Label(store.portableOnly ? "Portable input; source profile not backed up." : "Originals stay intact. Import adds to the destination.", systemImage: "checkmark.shield").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Create migration package…", action: store.createPackage)
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                        .disabled(!store.canCreate)
                        .keyboardShortcut("e", modifiers: [.command])
                }.padding(20)
            }.navigationTitle(store.page.rawValue)
                .toolbar { Button { store.discover() } label: { Label("Rescan profiles", systemImage: "arrow.clockwise") }.disabled(store.loading || store.creating) }
        }.tint(accent).task { store.discover() }
        .onChange(of: store.selectedID) { _, _ in store.scan() }
        .onChange(of: store.sourceBrowser) { _, _ in store.changeSource() }
        .onChange(of: store.targetBrowser) { _, _ in store.discoverTargets() }
        .onChange(of: store.portableOnly) { _, _ in store.scan() }
        .alert("Couldn’t complete that step", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("From", selection: $store.sourceBrowser) { ForEach(BrowserID.allCases) { Text($0.name).tag($0) } }
                    Picker("Profile", selection: $store.selectedID) {
                        if store.profiles.isEmpty { Text("No detected profile").tag("") }
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }
                    Button("Choose source folder…") { store.chooseProfile() }
                }
                Image(systemName: "arrow.right").padding(.top, 14).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Picker("To", selection: $store.targetBrowser) { ForEach(BrowserID.allCases) { Text($0.name).tag($0) } }
                    Picker("Profile", selection: $store.targetID) {
                        Text("New / separately backed up").tag("")
                        ForEach(store.targetProfiles) { Text($0.name).tag($0.id) }
                    }
                    Button("Choose destination folder…") { store.chooseProfile(destination: true) }
                }
            }.disabled(store.creating || store.transferring || store.demo)
            if store.target == nil { Toggle("Destination is a new or separately backed-up profile", isOn: $store.destinationBackedUp).font(.callout).disabled(store.creating || store.transferring || store.demo) }
        }
    }
    private var support: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Eleven browsers.\nClear boundaries.").font(.largeTitle.weight(.semibold))
            Text("Choose either end of a migration. Support is shown by format and data category; a shared engine does not prove a vendor build was tested.").foregroundStyle(.secondary)
            ForEach(BrowserID.allCases) { browser in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(browser.name).font(.headline); Spacer(); Text(browser.family.rawValue.capitalized).font(.callout).foregroundStyle(.secondary) }
                    Text(browser.family == .safari ? "Source: readable bookmarks/history files or exported HTML. Destination: manual bookmark HTML import. Native tabs/groups and authenticated sessions stay archived." : "Source: profile bookmarks/history plus optional live capture for exposed tabs, pins and groups. Destination: public WebExtension helper; native spaces/Favorites may remain archived.").font(.callout).foregroundStyle(.secondary)
                    Divider().padding(.top, 6)
                }
            }
            note(title: "Verification, separately stated", text: "Discovery fixtures cover all eleven names. Source-decoder fixtures cover the Chromium, Firefox/Zen and Safari families. Chromium and Firefox extension APIs have isolated-profile integration coverage. Other vendor builds are not all end-to-end verified; family similarity is not acceptance testing. Firefox fresh profiles may need bookmark initialization before import. Arc sidebar and Vivaldi workspaces are archive-only. Safari lists data folders, not named profiles, and may require macOS privacy access; portable HTML avoids reading the source profile.", symbol: "checkmark.seal")
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your browsers.\nOne bridge.").font(.system(size: 36, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Keep your browsing setup portable, with verified backups and a clear map of what transfers.").font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Label(store.sourceBrowser.name, systemImage: "square.stack.3d.up").font(.title2.weight(.medium))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Label(store.targetBrowser.name, systemImage: "circle.hexagongrid").font(.title2.weight(.medium))
                Spacer(); Text("Backup → Preview → Import").font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if store.sourceBrowser.family != .safari { Button("Save capture helper…", action: store.saveCaptureHelper) }
                    Button("Attach capture / bookmarks HTML…", action: store.attachPortable)
                }.disabled(store.creating || store.transferring || store.demo)
                Text(store.sourceBrowser.family == .safari ? "Safari: attach a bookmarks HTML export to use the portable-file fallback." : "For live tabs and pins, capture in the source browser, attach its JSON here, then quit browsers before backup.").font(.callout).foregroundStyle(.secondary)
                if let capture = store.captureURL {
                    Text("Attached: \(capture.lastPathComponent)").font(.callout).textSelection(.enabled)
                    Toggle("Portable file only — source profile is not read or backed up", isOn: $store.portableOnly).font(.callout).disabled(store.creating)
                }
                if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Divider()
            if store.loading { HStack { ProgressView(); Text("Reading source data…") }.padding(.vertical, 24) }
            else if let s = store.snapshot {
                Text(store.portableOnly ? "Found in your portable input" : "Found in your source").font(.title2.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 24) {
                    count("Tabs", s.tabs.count); count("Essentials", s.tabs.filter(\.essential).count); count("Pinned tabs", s.tabs.filter { $0.pinned && !$0.essential }.count)
                    count("Spaces / windows", s.spaces.count); count("Folders / groups", s.folders.count); count("History entries", s.history.count)
                }
                Text("Snapshot: \(s.sourceFile.isEmpty ? "Demo session" : s.sourceFile). Bookmarks and additional profile data are included in the package.").font(.callout).foregroundStyle(.secondary)
                note(title: "A complete archive. An honest transfer.", text: "Profile packages preserve originals; portable-only packages preserve just the input file. Spaces and native browser features may need approximations. Credentials and cookies have explicit limits in the transfer plan.", symbol: "info.circle")
                if !s.warnings.isEmpty { note(title: "Profile notes", text: s.warnings.joined(separator: "\n"), symbol: "exclamationmark.triangle") }
                Button("Review transfer plan", action: { store.page = .plan }).buttonStyle(.bordered).controlSize(.large)
            } else { ContentUnavailableView("Choose a source", systemImage: "folder", description: Text("Select a detected profile, choose its folder, or attach a portable JSON/bookmarks HTML file.")) }
        }
    }
    private func count(_ name: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value.formatted()).font(.system(size: 28, weight: .medium)).monospacedDigit(); Text(name).foregroundStyle(.secondary) }.accessibilityElement(children: .combine)
    }
    private var plan: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Know what arrives,\nand in what shape.").font(.largeTitle.weight(.semibold))
            Text("Review this route before packaging. Chromium/Firefox destinations use a local helper; Safari uses a manual bookmark-file import.").foregroundStyle(.secondary)
            ForEach(BrowserSupport.rows(source: store.sourceBrowser, target: store.targetBrowser)) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) { Text(row.category).font(.headline); Spacer(); Text(row.status).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
                    Text(row.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.top, 8)
                }
            }
            note(title: "Before creating a package", text: "Quit the selected browsers with ⌘Q. The app verifies copies of the selected profiles. Packages contain sensitive data; owner-only permissions are not encryption. Keep them on an encrypted disk. Caches and live locks are omitted. In portable-only mode, the original source profile is not read or backed up.", symbol: "externaldrive.badge.checkmark")
            if store.target == nil { note(title: "No destination backup selected", text: "Choose an existing destination profile above, or confirm that you will import into a new or separately backed-up profile.", symbol: "exclamationmark.triangle") }

        }
    }
    private var packages: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Saved packages").font(.largeTitle.weight(.semibold))
            Text("Keep a history of your exports. A saved package means the export is ready; import status and rollback live in its destination helper.").foregroundStyle(.secondary)
            if store.packageURLs.isEmpty { ContentUnavailableView("No packages yet", systemImage: "archivebox", description: Text("Create a package after reviewing the plan. Selected profile browsers must be closed.")) }
            ForEach(store.packageURLs, id: \.path) { url in
                VStack(alignment: .leading, spacing: 12) {
                    Label(url.lastPathComponent, systemImage: "shippingbox").font(.headline)
                    Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Read import steps") { NSWorkspace.shared.open(url.appendingPathComponent("READ ME.md")) }
                        Button("Copy package path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
                    }; Divider().padding(.top, 8)
                }
            }
            Button("Locate existing package…", action: store.addPackage).disabled(store.creating)
            note(title: "Continue in the destination", text: "Read each package’s instructions for its target. Chromium loads the Importer folder; Firefox/Zen load its manifest as a temporary add-on; Safari imports Bookmarks.html manually. Package creation is an export, not a completed import.", symbol: "puzzlepiece.extension")
            note(title: "Undo an import", text: "Open the same helper in the same destination profile and choose Roll back this package. It uses its saved journal to remove its own bookmark trees and unchanged tabs from this browser session. History URLs are retained for review. Review retained items in the journal. Export the journal before restarting a Firefox temporary add-on. Safari manual imports have no helper rollback.", symbol: "arrow.uturn.backward")
        }
    }
    private func note(title: String, text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}
