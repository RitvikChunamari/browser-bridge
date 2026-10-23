import Foundation
import Testing
@testable import BridgeCore

struct CrossBrowserPackageTests {
    @Test func portableOnlyPackagePreservesOnlyInputInsteadOfReadingSourceProfile() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("bookmarks.html")
        try Data("<DL><p><DT><A HREF=\"https://example.com\">Example</A></DL><p>".utf8).write(to: input)
        let result = try PackageBuilder(importerResources: root.appendingPathComponent("unused-helper")).createPortable(input: input, sourceBrowser: .safari, targetBrowser: .safari, targetProfile: nil, destination: root.appendingPathComponent("package"), runningBrowsers: { [] })
        #expect(result.snapshot.bookmarks.first?.title == "Example")
        #expect(result.snapshot.warnings.contains { $0.contains("source profile was not read or backed up") })
        #expect(try fm.contentsOfDirectory(atPath: result.url.appendingPathComponent("Backups/Safari").path) == ["Portable Input.html"])
        #expect(fm.fileExists(atPath: result.url.appendingPathComponent("Portable Input.html").path))
    }
    @Test func safariHTMLPreservesFolderTreeWithoutReadingProfile() throws {
        let html = Data("""
        <!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p>
        <DT><H3>Work &amp; life</H3><DL><p><DT><A HREF="https://example.com?a=1&amp;b=2">Example &lt;one&gt;</A></DL><p></DL><p>
        """.utf8)
        let snapshot = try BookmarkHTML.read(html)
        #expect(snapshot.bookmarks.count == 2)
        #expect(snapshot.bookmarks[0].title == "Work & life")
        #expect(snapshot.bookmarks[1].parent == snapshot.bookmarks[0].id)
        #expect(snapshot.bookmarks[1].url == "https://example.com?a=1&b=2")
    }
    @Test func chromiumToFirefoxSelectsFirefoxManifestAndKeepsOriginal() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("chrome"), helper = root.appendingPathComponent("helper")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: helper, withIntermediateDirectories: true)
        let original = Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[{"type":"url","name":"Example","url":"https://example.com"}]}}}"#.utf8)
        try original.write(to: source.appendingPathComponent("Bookmarks"))
        try Data(#"{"background":{"service_worker":"background.js"}}"#.utf8).write(to: helper.appendingPathComponent("manifest.json"))
        try Data(#"{"background":{"scripts":["background.js"]}}"#.utf8).write(to: helper.appendingPathComponent("manifest-firefox.json"))
        let builder = PackageBuilder(importerResources: helper)
        let result = try builder.create(source: source, sourceBrowser: .chrome, targetBrowser: .firefox, targetProfile: nil, destination: root.appendingPathComponent("package"), runningBrowsers: { [] })
        let manifest = try String(contentsOf: result.url.appendingPathComponent("Importer/manifest.json"), encoding: .utf8)
        #expect(manifest.contains("scripts"))
        #expect(!manifest.contains("service_worker"))
        #expect(try Data(contentsOf: source.appendingPathComponent("Bookmarks")) == original)
        #expect(result.snapshot.bookmarks.contains { $0.url == "https://example.com" })
        let safari = try builder.create(source: source, sourceBrowser: .chrome, targetBrowser: .safari, targetProfile: nil, destination: root.appendingPathComponent("safari-package"), runningBrowsers: { [] })
        #expect(!fm.fileExists(atPath: safari.url.appendingPathComponent("Importer").path))
        #expect(fm.fileExists(atPath: safari.url.appendingPathComponent("Bookmarks.html").path))
    }

    @Test func portableCaptureRetainsPinsButRejectsWrongBrowser() throws {
        let fm = FileManager.default, file = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? fm.removeItem(at: file) }
        let json = #"{"schema":1,"format":"browser-bridge-capture","browser":"helium","capturedAt":"2026-10-22T00:00:00Z","snapshot":{"spaces":[{"id":"w","name":"Window 1"}],"folders":[],"tabs":[{"id":"t","url":"https://example.com","title":"Example","pinned":true,"essential":false,"spaceID":"w","folderID":null,"order":0,"originalURL":null,"container":0}],"bookmarks":[],"history":[],"passwordCount":0,"cookieCount":0,"sourceFile":"live capture","warnings":[]}}"#
        try Data(json.utf8).write(to: file)
        let capture = try PortableCapture.load(file, expectedBrowser: .helium)
        #expect(capture.supplement(Snapshot()).tabs[0].pinned)
        #expect(throws: (any Error).self) { try PortableCapture.load(file, expectedBrowser: .chrome) }
    }
}
