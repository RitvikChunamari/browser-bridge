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
    case overview = "Overview", plan = "Transfer plan", support = "Browser support", packages = "Saved packages"
    var id: String { rawValue }
    var symbol: String { switch self { case .overview: "square.grid.2x2"; case .plan: "arrow.triangle.branch"; case .support: "globe"; case .packages: "archivebox" } }
}
@MainActor @Observable final class MigrationStore {
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
    var page: Page = .overview
    let demo = CommandLine.arguments.contains("--demo")
    var selected: BrowserProfile? { profiles.first { $0.id == selectedID } }
    var target: BrowserProfile? { targetProfiles.first { $0.id == targetID } }
    var packageURLs: [URL] { savedPaths.map { URL(fileURLWithPath: $0) } }
    var canCreate: Bool { !demo && !loading && !creating && snapshot != nil && (portableOnly ? captureURL != nil : selected != nil) && (target != nil || destinationBackedUp) }

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
    func changeSource() { scanGeneration += 1; profiles = []; selectedID = ""; snapshot = nil; captureURL = nil; portableOnly = false; notice = nil; discover() }
    func scan() {
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
                routeControls.padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        switch store.page { case .overview: overview; case .plan: plan; case .support: support; case .packages: packages }
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
            }.disabled(store.creating || store.demo)
            if store.target == nil { Toggle("Destination is a new or separately backed-up profile", isOn: $store.destinationBackedUp).font(.callout).disabled(store.creating || store.demo) }
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
                }.disabled(store.creating || store.demo)
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
