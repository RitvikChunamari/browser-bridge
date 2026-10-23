import Foundation
import Testing
@testable import BridgeCore

struct NativeOrganizationTests {
    @Test func arcCapturePreservesNativeLocationsAndWindowSpaceIdentityThroughExport() throws {
        let data = Data(#"{"schema":1,"browser":"arc","version":"1.0","windows":[{"id":"w","spaces":[{"id":"work","name":"Work","tabs":[{"id":"a","url":"https://example.com/?q=\"hi\"","title":"A\nB","location":"topApp"},{"id":"b","url":"https://example.com/p","title":"Pinned","location":"pinned"}]}]}]}"#.utf8)
        let snapshot = try NativeBrowserCapture.decode(data, browser: .arc)
        #expect(snapshot.spaces.first?.name == "Work")
        #expect(snapshot.tabs.count == 2)
        #expect(snapshot.tabs[0].essential)
        #expect(snapshot.tabs[1].pinned)
        #expect(snapshot.tabs[0].spaceID == snapshot.spaces[0].id)
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.nativeOrganization?.rawJSON.contains("topApp") == true)
        #expect(restored.nativeOrganization?.browserVersion == "1.0")
        let capture = PortableCapture(schema: 1, format: "browser-bridge-capture", browser: .arc, capturedAt: "test", snapshot: snapshot)
        #expect(capture.supplement(Snapshot()).nativeOrganization == snapshot.nativeOrganization)
    }
    @Test func safariCaptureDoesNotInventPinOrGroupState() throws {
        let data = Data(#"{"schema":1,"browser":"safari","version":"26","windows":[{"id":"1","tabs":[{"id":"0","url":"https://example.com","title":"Example"}]}]}"#.utf8)
        let snapshot = try NativeBrowserCapture.decode(data, browser: .safari)
        #expect(snapshot.tabs.count == 1)
        #expect(!snapshot.tabs[0].pinned)
        #expect(snapshot.warnings.contains { $0.contains("Tab Groups") })
    }
    @Test func captureRejectsWrongAdapterAndUnknownSchema() throws {
        for json in [#"{"schema":2,"browser":"arc","version":"1","windows":[]}"#, #"{"schema":1,"browser":"dia","version":"1","windows":[]}"#] {
            #expect(throws: (any Error).self) { try NativeBrowserCapture.decode(Data(json.utf8), browser: .arc) }
        }
        #expect(throws: (any Error).self) { try NativeBrowserCapture.script(browser: .dia) }
    }
    @Test func oldSnapshotStillDecodesWithoutNativeMetadata() throws {
        let original = Snapshot()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Snapshot.self, from: data).nativeOrganization == nil)
    }
}

struct ZenOrganizationRecoveryTests {
    @Test func explicitEmptyLiveSessionDoesNotResurrectOlderTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"tabs":[{"entries":[{"url":"https://example.com/old"}]}]}"#.utf8).write(to: root.appendingPathComponent("sessionstore-backup.js"))
        // Use a recognized older candidate, then make the empty live session newest.
        try FileManager.default.moveItem(at: root.appendingPathComponent("sessionstore-backup.js"), to: root.appendingPathComponent("sessionstore.js"))
        let live = root.appendingPathComponent("sessionstore.jsonlz4")
        try Data(#"{"windows":[{"tabs":[]}]}"#.utf8).write(to: live)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(5)], ofItemAtPath: live.path)
        #expect(try ZenReader.read(profile: root).tabs.isEmpty)
    }

    @Test func metadataOnlyZenFileDoesNotHideLiveTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"tabs":[{"zenPinnedId":"legacy","entries":[{"url":"https://example.com/live"}]}]}"#.utf8).write(to: root.appendingPathComponent("sessionstore.jsonlz4"))
        let zen = root.appendingPathComponent("zen-sessions.jsonlz4")
        try Data(#"{"spaces":[{"uuid":"work","name":"Work"}]}"#.utf8).write(to: zen)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(5)], ofItemAtPath: zen.path)
        let result = try ZenReader.read(profile: root)
        #expect(result.tabs.first?.id == "legacy")
        #expect(result.spaces.first?.name == "Work")
    }

    @Test func newerLiveSessionKeepsZenOrganizationWithoutDuplicatingStableTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let organization = Data(#"{"spaces":[{"uuid":"work","name":"Work"}],"folders":[{"id":"folder","name":"Research","workspaceId":"work"}],"tabs":[{"zenSyncId":"same","zenWorkspace":"work","groupId":"folder","zenEssential":true,"pinned":true,"entries":[{"url":"https://example.com/old"}]}]}"#.utf8)
        try organization.write(to: root.appendingPathComponent("zen-sessions.jsonlz4"))
        let live = root.appendingPathComponent("sessionstore.jsonlz4")
        try Data(#"{"windows":[{"tabs":[{"zenSyncId":"same","entries":[{"url":"https://example.com/new"}]}]}]}"#.utf8).write(to: live)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(5)], ofItemAtPath: live.path)
        let result = try ZenReader.read(profile: root)
        #expect(result.tabs.count == 1)
        #expect(result.tabs[0].url == "https://example.com/new")
        #expect(result.tabs[0].essential)
        #expect(result.tabs[0].spaceID == "work")
        #expect(result.folders.first?.id == "folder")
    }
}

#if os(macOS)
import OSAKit
struct NativeScriptCompilationTests {
    @MainActor @Test func vendorScriptsCompileWithoutExecutingOrReadingBrowserData() throws {
        let language = try #require(OSALanguage(forName: "JavaScript"))
        for browser in [BrowserID.arc, .safari] {
            let source = try NativeBrowserCapture.script(browser: browser)
            let script = OSAScript(source: source, language: language)
            var error: NSDictionary?
            #expect(script.compileAndReturnError(&error))
            #expect(error == nil)
        }
    }
}
#endif
