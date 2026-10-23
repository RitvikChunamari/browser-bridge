import Foundation
import CryptoKit

public struct PackageBuilder: Sendable {
    public let importerResources: URL
    public init(importerResources: URL) { self.importerResources = importerResources }

    public static func runningBrowsers() throws -> [String] { try activeBrowsers([.zen, .dia]) }
    public static func activeBrowsers(_ browsers: [BrowserID]) throws -> [String] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = ["-A", "-o", "comm="]; process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BridgeError.message("Cannot check running browsers. Close the selected browsers and retry.") }
        let lines = String(decoding: data, as: UTF8.self).lowercased().components(separatedBy: .newlines)
        let apps: [BrowserID: [String]] = [.chrome:["google chrome"], .brave:["brave browser"], .edge:["microsoft edge"], .opera:["opera", "opera gx"]]
        return Array(Set(browsers)).filter { browser in
            let names = apps[browser] ?? [browser.rawValue]
            return lines.contains { line in names.contains { line.contains("/\($0).app/contents/") || line.hasSuffix("/\($0)") } }
        }.map(\.name).sorted()
    }

    // Backward-compatible entry point for original Zen → Dia packages and fixtures.
    public func create(source: URL, diaRoot: URL?, destination: URL,
                       runningBrowsers: @escaping () throws -> [String] = PackageBuilder.runningBrowsers) throws -> PackageResult {
        try create(source: source, sourceBrowser: .zen, targetBrowser: .dia, targetProfile: diaRoot, destination: destination, runningBrowsers: runningBrowsers)
    }

    public func create(source: URL, sourceBrowser: BrowserID, targetBrowser: BrowserID, targetProfile: URL?, destination: URL,
                       captureURL: URL? = nil, portableOnly: Bool = false, runningBrowsers: (() throws -> [String])? = nil) throws -> PackageResult {
        let fm = FileManager.default
        let check = runningBrowsers ?? { try Self.activeBrowsers(portableOnly ? [targetBrowser] : [sourceBrowser, targetBrowser]) }
        let active = try check()
        guard active.isEmpty else { throw BridgeError.message("Quit \(active.joined(separator: " and ")) with ⌘Q before creating a consistent backup.") }
        let source = URL(fileURLWithPath: (source.path as NSString).resolvingSymlinksInPath)
        let destination = canonicalDestination(destination)
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { throw BridgeError.message("The source is missing or the destination already exists. Choose a new package location.") }
        let target = targetProfile.map { URL(fileURLWithPath: ($0.path as NSString).resolvingSymlinksInPath) }
        guard target?.path != source.path else { throw BridgeError.message("Choose different source and destination profiles. Self-import would duplicate data.") }
        _ = try captureURL.map { try PortableCapture.load($0, expectedBrowser: sourceBrowser) }
        for root in [source] + (target.map { [$0] } ?? []) {
            guard destination.path != root.path, !destination.path.hasPrefix(root.path + "/") else { throw BridgeError.message("Save the package outside both browser profile directories.") }
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let total = try ([source] + (target.map { [$0] } ?? [])).reduce(Int64(0)) { try $0 + byteCount($1) }
        if let free = (try fm.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? NSNumber)?.int64Value,
           free < total + 128 * 1024 * 1024 { throw BridgeError.message("Not enough free space for the backups (about \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))).") }
        let staging = parent.appendingPathComponent(".browserbridge-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var manifest: [[String: String]] = [], omissions: [String] = []
        var stagedCapture: URL?
        if let captureURL {
            let name = ["html", "htm"].contains(captureURL.pathExtension.lowercased()) ? "Portable Input.html" : "Live Capture.json"
            let file = staging.appendingPathComponent(name)
            try copyVerified(captureURL, to: file, manifestPath: name, manifest: &manifest)
            stagedCapture = file
        }
        let capture = try stagedCapture.map { try PortableCapture.load($0, expectedBrowser: sourceBrowser) }
        let sourceLabel = sourceBrowser.name, targetLabel = "Destination-" + targetBrowser.name
        let sourceBackup = staging.appendingPathComponent("Backups/" + sourceLabel)
        try backup(source, to: sourceBackup, label: sourceLabel, manifest: &manifest, omissions: &omissions)
        if !portableOnly { try backupContext(profile: source, browser: sourceBrowser, staging: staging, label: sourceLabel + "-Global", manifest: &manifest) }
        if let target {
            guard fm.fileExists(atPath: target.path) else { throw BridgeError.message("Destination profile disappeared. Rescan and retry.") }
            try backup(target, to: staging.appendingPathComponent("Backups/" + targetLabel), label: targetLabel, manifest: &manifest, omissions: &omissions)
            try backupContext(profile: target, browser: targetBrowser, staging: staging, label: targetLabel + "-Global", manifest: &manifest)
        }
        guard try check().isEmpty else { throw BridgeError.message("A selected browser started during backup. Quit both and try again.") }
        var snapshot = portableOnly ? Snapshot() : try BrowserReader.read(profile: sourceBackup, browser: sourceBrowser)
        if let capture { snapshot = capture.supplement(snapshot) }
        snapshot.warnings += omissions
        if portableOnly { snapshot.warnings.append("Portable-file-only package: the original source profile was not read or backed up. Only the selected input file and portable data are preserved.") }
        if target == nil { snapshot.warnings.append("No destination profile was selected. No destination backup was made. Import only into a new or separately backed-up profile.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let packageID = UUID().uuidString, createdAt = ISO8601DateFormatter().string(from: Date())
        let snapshotData = try encoder.encode(snapshot)
        try snapshotData.write(to: staging.appendingPathComponent("snapshot.json"))
        let payload: [String: Any] = ["schema":1, "packageID":packageID, "createdAt":createdAt,
            "sourceBrowser":sourceBrowser.rawValue, "sourceName":sourceBrowser.name,
            "targetBrowser":targetBrowser.rawValue, "targetName":targetBrowser.name,
            "snapshot":try JSONSerialization.jsonObject(with: snapshotData)]
        if targetBrowser.family != .safari {
            let helper = staging.appendingPathComponent("Importer")
            try HelperBundle.write(from: importerResources, to: helper, browser: targetBrowser)
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: helper.appendingPathComponent("data.json"))
        }
        let rows = BrowserSupport.rows(source: sourceBrowser, target: targetBrowser)
        let report: [String:Any] = ["schema":2,"packageID":packageID,"createdAt":createdAt,"sourceBrowser":sourceBrowser.rawValue,
            "targetBrowser":targetBrowser.rawValue,"state":"export-ready-import-not-run","sourceProfile":portableOnly ? "portable-file-only" : source.path,"destinationProfile":target?.path ?? "not-selected",
            "capabilities":rows.map { ["category":$0.category,"status":$0.status,"detail":$0.detail] },"warnings":snapshot.warnings]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent("transfer-report.json"))
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent("backup-manifest.json"))
        try bookmarksHTML(snapshot).write(to: staging.appendingPathComponent("Bookmarks.html"), atomically: true, encoding: .utf8)
        let limitations = rows.map { "- \($0.category): \($0.status). \($0.detail)" }.joined(separator: "\n")
        let guide = """
        # Browser Bridge: \(sourceBrowser.name) → \(targetBrowser.name)

        Package ID: \(packageID)
        Export ready. IMPORT HAS NOT RUN.
        Source snapshot: \(snapshot.sourceFile). \(snapshot.tabs.count) tabs, \(snapshot.spaces.count) spaces/windows, \(snapshot.folders.count) folders/groups.

        ## Import into \(targetBrowser.name)
        \(BrowserSupport.importInstructions(target: targetBrowser))

        Workspace selections open in the CURRENT profile. Native destination spaces and Favorites are not created. Preserve the Importer folder until finished. Save the journal before removing or reloading the helper. Safari packages have no Importer folder.

        Bookmarks.html is an alternative portable bookmark import; avoid also importing helper bookmarks unless you want another copy.

        ## Credentials
        Original credential files remain in the profile backup. Use the browsers' own password export/import flows where supported. This app does not decrypt credentials, activate cookies, transfer passkeys or export macOS Keychain data.

        ## Compatibility
        \(limitations)

        ## Backup and recovery
        Backups/\(sourceLabel) contains \(portableOnly ? "only the portable input file; the source profile was NOT backed up" : "the selected source profile"). Backups/\(targetLabel) is the selected destination profile when supplied. Known external metadata (Local State, profile registries and Arc/Dia Storable sidebar files) is retained in a corresponding -Global folder when found under recognized browser roots. Other profiles, unknown external settings and Keychain data are not copied.
        Backups contain sensitive browser data including credential files and session/form state. Owner-only file permissions are not encryption; use an encrypted disk. Caches, live locks and symlinks are omitted. SHA-256 checksums are in backup-manifest.json.
        Helpers merge additions. Explicit rollback removes helper-owned bookmark trees (including edits inside them) and unchanged imported tabs only in the same browser session. History URLs remain for manual review. Firefox temporary add-ons lose their session/journal availability on restart, so export the journal and finish rollback before restarting.
        For raw profile recovery, quit the browser and preserve its CURRENT profile elsewhere before restoring reviewed backup files. This reverts later activity and can require the original Mac/Keychain. No automatic raw-database replacement is performed.

        ## Warnings
        \(snapshot.warnings.isEmpty ? "None." : snapshot.warnings.map { "- " + $0 }.joined(separator: "\n"))
        """
        try guide.write(to: staging.appendingPathComponent("READ ME.md"), atomically: true, encoding: .utf8)
        try privatePermissions(staging)
        try fm.moveItem(at: staging, to: destination)
        return PackageResult(url: destination, snapshot: snapshot)
    }

    public func createPortable(input: URL, sourceBrowser: BrowserID, targetBrowser: BrowserID, targetProfile: URL?, destination: URL,
                               runningBrowsers: (() throws -> [String])? = nil) throws -> PackageResult {
        _ = try PortableCapture.load(input, expectedBrowser: sourceBrowser)
        let fm = FileManager.default, temporary = fm.temporaryDirectory.appendingPathComponent("browserbridge-input-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("Portable Input." + input.pathExtension)
        try fm.copyItem(at: input, to: copy)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        return try create(source: temporary, sourceBrowser: sourceBrowser, targetBrowser: targetBrowser, targetProfile: targetProfile,
                          destination: destination, captureURL: copy, portableOnly: true, runningBrowsers: runningBrowsers)
    }

    private let skipped = Set(["Cache", "cache2", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "Crashpad", "Crash Reports", "startupCache", "parent.lock", ".parentlock", "lock", "SingletonLock", "SingletonSocket", "SingletonCookie"])

    // Resolving the whole path does not reliably resolve symlink ancestors when its final component is absent.
    private func canonicalDestination(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            tail.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        return tail.reduce(URL(fileURLWithPath: (ancestor.path as NSString).resolvingSymlinksInPath)) { $0.appendingPathComponent($1) }
    }

    private func files(_ root: URL) throws -> [URL] {
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw BridgeError.message("Cannot enumerate \(root.lastPathComponent). Check folder permissions.") }
        var result: [URL] = []
        for case let item as URL in iterator {
            if skipped.contains(item.lastPathComponent) { iterator.skipDescendants(); continue }
            result.append(item)
        }
        if let enumerationError { throw enumerationError }
        return result
    }
    private func byteCount(_ root: URL) throws -> Int64 {
        try files(root).reduce(0) { sum, file in let v = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]); return sum + (v.isSymbolicLink == true ? 0 : Int64(v.fileSize ?? 0)) }
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func backupContext(profile: URL, browser: BrowserID, staging: URL, label: String, manifest: inout [[String: String]]) throws {
        let fm = FileManager.default
        let canonicalProfile = (profile.path as NSString).resolvingSymlinksInPath
        var seen = Set<String>()
        for root in browser.roots() {
            let base = (root.path as NSString).resolvingSymlinksInPath
            guard canonicalProfile == base || canonicalProfile.hasPrefix(base + "/") else { continue }
            for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let name = file.lastPathComponent
                guard ["Local State", "profiles.ini", "installs.ini"].contains(name) || (name.hasPrefix("Storable") && name.hasSuffix(".json")) else { continue }
                let path = (file.path as NSString).resolvingSymlinksInPath
                guard !path.hasPrefix(canonicalProfile + "/"), seen.insert(path).inserted else { continue }
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                let relative = root.lastPathComponent + "/" + name
                try copyVerified(file, to: staging.appendingPathComponent("Backups/\(label)/\(relative)"), manifestPath: "Backups/\(label)/\(relative)", manifest: &manifest)
            }
        }
    }
    private func copyVerified(_ file: URL, to destination: URL, manifestPath: String, manifest: inout [[String:String]]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: file, to: destination)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let checksum = try digest(destination)
        guard try digest(file) == checksum else { throw BridgeError.message("A source file changed during backup. Close both browsers and retry.") }
        manifest.append(["path": manifestPath, "sha256": checksum])
    }
    private func backup(_ root: URL, to target: URL, label: String, manifest: inout [[String: String]], omissions: inout [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in try files(root) {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { omissions.append("Skipped symlink in \(label): \(file.lastPathComponent)"); continue }
            let base = (root.path as NSString).resolvingSymlinksInPath
            let canonical = (file.path as NSString).resolvingSymlinksInPath
            guard canonical.hasPrefix(base + "/") else { throw BridgeError.message("A backup path escaped the selected profile.") }
            let relative = String(canonical.dropFirst(base.count + 1))
            let dest = target.appendingPathComponent(relative)
            if values.isDirectory == true { try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); continue }
            try copyVerified(file, to: dest, manifestPath: "Backups/\(label)/\(relative)", manifest: &manifest)
        }
    }
    private func privatePermissions(_ root: URL) throws {
        for file in try files(root) {
            let v = try file.resourceValues(forKeys: [.isDirectoryKey])
            try FileManager.default.setAttributes([.posixPermissions: v.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: file.path)
        }
    }
    private func bookmarksHTML(_ snapshot: Snapshot) -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        func leaf(_ title: String, _ url: String) -> String { "<DT><A HREF=\"\(escape(url))\">\(escape(title))</A>\n" }
        func folder(_ name: String, _ contents: String) -> String { "<DT><H3>\(escape(name))</H3>\n<DL><p>\n\(contents)</DL><p>\n" }
        func safe(_ url: String) -> Bool { ["https", "http"].contains(URL(string: url)?.scheme?.lowercased() ?? "") }
        func bookmarkTree(_ parent: Int64, _ visited: Set<Int64>) -> String {
            snapshot.bookmarks.filter { $0.parent == parent && !visited.contains($0.id) }.map { b in
                if let url = b.url, safe(url) { return leaf(b.title, url) }
                if b.type == 2 { return folder(b.title.isEmpty ? "Bookmarks" : b.title, bookmarkTree(b.id, visited.union([b.id]))) }
                return ""
            }.joined()
        }
        var body = folder("Saved bookmarks", bookmarkTree(0, []))
        let knownSpaces = Set(snapshot.spaces.map(\.id)), folderIDs = Set(snapshot.folders.map(\.id))
        var renderedFolders = Set<String>()
        func links(_ tabs: [BrowserTab]) -> String {
            tabs.filter { safe($0.originalURL ?? $0.url) }.map { leaf($0.title, $0.originalURL ?? $0.url) }.joined()
        }
        func folderTree(_ item: Folder) -> String {
            guard renderedFolders.insert(item.id).inserted else { return "" }
            let contents = snapshot.folders.filter { $0.parentID == item.id }.map(folderTree).joined()
                + links(snapshot.tabs.filter { !$0.essential && $0.folderID == item.id })
            return folder(item.name, contents)
        }
        for space in snapshot.spaces + [Space(id: "", name: "Unassigned tabs")] {
            func belongs(_ id: String?) -> Bool { space.id == (knownSpaces.contains(id ?? "") ? id ?? "" : "") }
            let roots = snapshot.folders.filter { belongs($0.spaceID) && !folderIDs.contains($0.parentID ?? "") }
            let loose = snapshot.tabs.filter { !$0.essential && belongs($0.spaceID) && !folderIDs.contains($0.folderID ?? "") }
            body += folder(space.name, roots.map(folderTree).joined() + links(loose))
        }
        // Malformed cyclic/orphan metadata must not silently discard URLs from the portable export.
        let recovered = snapshot.folders.filter { !renderedFolders.contains($0.id) }.map(folderTree).joined()
        if !recovered.isEmpty { body += folder("Recovered folders", recovered) }
        body += folder("Essentials", links(snapshot.tabs.filter(\.essential)))
        return "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Browser Bridge</TITLE>\n<H1>Browser Bridge</H1>\n<DL><p>\n" + folder("Browser Bridge", body) + "</DL><p>\n"
    }
}
