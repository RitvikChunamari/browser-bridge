import Foundation
#if os(macOS)
import OSAKit
#endif

/// Archival vendor observations. Apply engines must not treat these as a native write API.
public struct NativeOrganization: Codable, Sendable, Equatable {
    public let schema: Int
    public let adapter: String
    public let browserVersion: String
    public let rawJSON: String
}

public enum NativeBrowserCapture {
    private struct Observation: Decodable {
        let schema: Int
        let browser: String
        let version: String
        let windows: [Window]
        struct Window: Decodable { let id: String; let tabs: [Tab]?; let spaces: [Area]? }
        struct Area: Decodable { let id: String; let name: String; let tabs: [Tab] }
        struct Tab: Decodable { let id: String; let url: String; let title: String; let location: String? }
    }

    /// Captures the running application's exposed windows, not a selected profile.
    /// Requires user-approved macOS Automation access; never starts or quits a browser.
    @MainActor public static func capture(browser: BrowserID) async throws -> Snapshot {
        try Task.checkCancellation()
        let source = try script(browser: browser)
        #if os(macOS)
        guard let language = OSALanguage(forName: "JavaScript") else { throw BridgeError.message("JavaScript for Automation is unavailable on this Mac.") }
        let osa = OSAScript(source: source, language: language)
        var error: NSDictionary?
        let result = osa.executeAndReturnError(&error)
        if let error {
            let code = (error["OSAScriptErrorNumber"] as? NSNumber)?.intValue
            if code == -1743 { throw BridgeError.message("Allow Browser Bridge to control \(browser.name) in System Settings → Privacy & Security → Automation, then retry. No browser data was changed.") }
            if code == -128 { throw BridgeError.message("Native capture was cancelled. Reopen the source browser and retry when ready.") }
            throw BridgeError.message("Could not capture \(browser.name). Keep it running, resolve its Automation prompt and retry. Its scripting dictionary may differ from this adapter. No browser data was changed.")
        }
        try Task.checkCancellation()
        guard let json = result?.stringValue else { throw BridgeError.message("The browser returned no native capture. Keep a source window open and retry.") }
        return try decode(Data(json.utf8), browser: browser)
        #else
        throw BridgeError.message("Native scripting capture is available only on macOS. Use the browser connector on this platform.")
        #endif
    }

    /// Builds a document that the app can save and attach through the existing portable-capture flow.
    @MainActor public static func portableCapture(browser: BrowserID) async throws -> PortableCapture {
        PortableCapture(schema: 1, format: "browser-bridge-capture", browser: browser,
            capturedAt: ISO8601DateFormatter().string(from: Date()), snapshot: try await capture(browser: browser))
    }

    /// Fixed code only: browser content is serialized as JSON by JXA, never interpolated into scripts.
    public static func script(browser: BrowserID) throws -> String {
        guard browser == .arc || browser == .safari else { throw BridgeError.message("\(browser.name) has no native scripting adapter. Use its connector or supported profile capture.") }
        let appID = browser == .arc ? "company.thebrowser.Browser" : "com.apple.Safari"
        let common = """
        const app = Application('\(appID)');
        if (!app.running()) throw Error('Open the source browser before capturing.');
        const result = {schema:1,browser:'\(browser.rawValue)',version:String(app.version()),windows:[]};
        """
        if browser == .arc {
            return common + """
            app.windows().forEach(w => {
                if (w.incognito()) return;
                const window = {id:String(w.id()),spaces:[]};
                w.spaces().forEach(s => {
                    const space = {id:String(s.id()),name:String(s.title()),tabs:[]};
                    s.tabs().forEach(t => space.tabs.push({id:String(t.id()),url:String(t.url()),title:String(t.title()),location:String(t.location())}));
                    window.spaces.push(space);
                });
                result.windows.push(window);
            });
            JSON.stringify(result);
            """
        }
        return common + """
        app.windows().forEach(w => {
            const window = {id:String(w.id()),tabs:[]};
            w.tabs().forEach((t,i) => window.tabs.push({id:String(i),url:String(t.url()),title:String(t.name())}));
            result.windows.push(window);
        });
        JSON.stringify(result);
        """
    }

    public static func decode(_ data: Data, browser: BrowserID) throws -> Snapshot {
        guard browser == .arc || browser == .safari, data.count <= 64 * 1024 * 1024 else { throw BridgeError.message("Unsupported or oversized native capture.") }
        let value = try JSONDecoder().decode(Observation.self, from: data)
        guard value.schema == 1, value.browser == browser.rawValue, !value.version.isEmpty else { throw BridgeError.message("Native capture adapter/schema mismatch. Update Browser Bridge and recapture.") }
        var snapshot = Snapshot()
        snapshot.sourceFile = "\(browser.rawValue)-scripting-v1"
        snapshot.nativeOrganization = NativeOrganization(schema: 1, adapter: snapshot.sourceFile, browserVersion: value.version, rawJSON: String(decoding: data, as: UTF8.self))
        var seenSpaces = Set<String>(), seenTabs = Set<String>()
        func append(_ tabs: [Observation.Tab], window: String, space: String?) {
            for tab in tabs {
                // Arc mirrors Favorites in multiple spaces/windows. Native raw data keeps all observations.
                let id = browser == .arc ? "arc:\(tab.id)" : "safari:\(window):\(tab.id)"
                guard seenTabs.insert(id).inserted else { continue }
                snapshot.tabs.append(BrowserTab(id: id, url: tab.url, title: tab.title,
                    pinned: tab.location == "pinned" || tab.location == "topApp", essential: tab.location == "topApp",
                    spaceID: space, folderID: nil, order: snapshot.tabs.count, originalURL: nil, container: 0))
            }
        }
        for window in value.windows {
            for space in window.spaces ?? [] {
                let id = "arc:\(space.id)"
                if seenSpaces.insert(id).inserted { snapshot.spaces.append(Space(id: id, name: space.name)) }
                append(space.tabs, window: window.id, space: id)
            }
            append(window.tabs ?? [], window: window.id, space: nil)
        }
        snapshot.warnings = [
            "Native capture observes the running application, potentially across profiles. Confirm its windows belong to the intended source before attaching it.",
            "Vendor version \(value.version) was recorded, not certified. Native observations are retained for archival fidelity; destination native organization is not created."
        ]
        if browser == .arc {
            snapshot.warnings.append("Arc scripting exposes Spaces and tab locations, not nested sidebar folders. Favorites are represented as Essentials/pins; mirrored tab IDs are deduplicated. Private Arc windows are excluded.")
        } else {
            snapshot.warnings.append("Safari scripting captures exposed ordinary tabs only. Pins, private-window classification and Tab Groups are not exposed by this adapter. Close private windows before capturing; review the capture before export.")
        }
        return snapshot
    }
}
