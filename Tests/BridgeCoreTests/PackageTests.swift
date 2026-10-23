import Foundation
import Testing
@testable import BridgeCore

struct PackageTests {
    @Test func portableBookmarksRetainOrphanedFoldersAndUnassignedTabs() throws {
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), helper = root.appendingPathComponent("helper")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: helper, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: helper.appendingPathComponent("manifest.json"))
        let json = #"{"spaces":[{"uuid":"w","name":"Work"}],"folders":[{"id":"orphan","name":"Orphan","parentId":"missing","workspaceId":"w"}],"tabs":[{"zenSyncId":"a","groupId":"orphan","zenWorkspace":"w","entries":[{"url":"https://example.com/orphan","title":"A <title>"}]},{"zenSyncId":"b","zenWorkspace":"unknown","entries":[{"url":"https://example.com/unassigned"}]}]}"#
        try Data(json.utf8).write(to: source.appendingPathComponent("zen-sessions.jsonlz4"))
        let package = try PackageBuilder(importerResources: helper).create(source: source, diaRoot: nil, destination: root.appendingPathComponent("package"), runningBrowsers: { [] })
        let html = try String(contentsOf: package.url.appendingPathComponent("Bookmarks.html"), encoding: .utf8)
        #expect(html.contains("https://example.com/orphan"))
        #expect(html.contains("https://example.com/unassigned"))
        #expect(html.contains("A &lt;title&gt;"))
    }
    @Test func testPackagePreservesOriginalAndBlocksLiveBrowser() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let profile = root.appendingPathComponent("source"), resources = root.appendingPathComponent("helper")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let bytes = Data(#"{"tabs":[],"spaces":[],"folders":[]}"#.utf8)
        try bytes.write(to: profile.appendingPathComponent("zen-sessions.jsonlz4"))
        try Data("private original".utf8).write(to: profile.appendingPathComponent("key4.db"))
        try Data("{}".utf8).write(to: resources.appendingPathComponent("manifest.json"))
        let service = PackageBuilder(importerResources: resources)
        #expect(throws: (any Error).self) { try service.create(source: profile, diaRoot: nil, destination: root.appendingPathComponent("blocked"), runningBrowsers: { ["Zen"] }) }
        #expect(!(fm.fileExists(atPath: root.appendingPathComponent("blocked").path)))
        let package = try service.create(source: profile, diaRoot: nil, destination: root.appendingPathComponent("package"), runningBrowsers: { [] })
        #expect(try Data(contentsOf: profile.appendingPathComponent("key4.db")) == Data("private original".utf8))
        #expect(try Data(contentsOf: package.url.appendingPathComponent("Backups/Zen/key4.db")) == Data("private original".utf8))
        #expect(fm.fileExists(atPath: package.url.appendingPathComponent("Importer/data.json").path))
        #expect(throws: (any Error).self) { try service.create(source: profile, diaRoot: nil, destination: package.url, runningBrowsers: { [] }) }
        #expect(throws: (any Error).self) { try service.create(source: profile, diaRoot: nil, destination: profile.appendingPathComponent("inside"), runningBrowsers: { [] }) }
        #expect(!fm.fileExists(atPath: profile.appendingPathComponent("inside").path))
        let link = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: link, withDestinationURL: profile)
        #expect(throws: (any Error).self) { try service.create(source: profile, diaRoot: nil, destination: link.appendingPathComponent("unsafe"), runningBrowsers: { [] }) }
        #expect(!fm.fileExists(atPath: profile.appendingPathComponent("unsafe").path))
    }
}
