import Foundation

public struct SupportRow: Identifiable, Sendable {
    public var id: String { category }
    public let category: String
    public let status: String
    public let detail: String
}

public enum BrowserSupport {
    public static func rows(source: BrowserID, target: BrowserID) -> [SupportRow] {
        let safari = target.family == .safari
        let sourceTabs: String
        switch source.family {
        case .chromium: sourceTabs = "Attach a live capture for Chromium tabs and pin state. Offline sessions are not decoded. Safari destinations receive tab links as bookmarks."
        case .firefox: sourceTabs = "Readable Firefox/Zen sessions retain order and pins. Live capture is used only if no local tabs are readable. Safari destinations receive bookmarks."
        case .safari: sourceTabs = "Safari source tabs, pins and Tab Groups are not extracted by this adapter. HTML carries bookmark links/folders only, not live pin/group state. Native session files remain archived where readable."
        }
        return [
            .init(category: "Bookmarks & folders", status: safari ? "Manual HTML import" : "Browser API", detail: "Nested bookmark trees are preserved under a new Browser Bridge folder. Existing bookmarks stay intact."),
            .init(category: "Open tabs & pins", status: source.family == .safari ? "Source archive only" : safari ? "Bookmark fallback" : "Capture / browser API", detail: sourceTabs),
            .init(category: "Groups & nested folders", status: "Approximation", detail: "Nested bookmark trees are exact where the source exposes them. Live groups use full paths and require destination API support; pinned tabs cannot also belong to Chromium groups."),
            .init(category: "Spaces, Essentials & Favorites", status: "Approximation / archive", detail: "Zen metadata is read from its session. Essentials become pins; spaces become bookmark trees. Native destination spaces/Favorites are not created. Arc sidebar and Vivaldi workspaces remain archive-only; live capture sees only exposed windows/groups."),
            .init(category: "History", status: safari ? "Archive only" : "Partial URL import", detail: "Original history and timestamps are exported where readable. Helpers add URLs with import-time timestamps only when no destination visits exist. Rollback retains history for review."),
            .init(category: "Passwords & passkeys", status: "Manual / archive", detail: "Credential files remain encrypted in the profile backup. Use the browsers’ own password export/import flows where offered. Passkeys require their provider; Keychain data is not exported."),
            .init(category: "Cookies & signed-in sessions", status: "Archive only", detail: "Profile files are backed up; authenticated sessions and container isolation are not activated in another browser."),
            .init(category: "Extensions & settings", status: "Archive only", detail: "Original data is retained. Install compatible extensions and configure settings through the destination browser."),
            .init(category: "Verification", status: "Per browser / category", detail: "Fixture-tested profile adapters are separate from vendor-build verification. Chromium and Firefox extension APIs have isolated-profile coverage. Other named browsers are not all end-to-end tested. Safari uses file flows and may need macOS privacy access.")
        ]
    }

    public static func importInstructions(target: BrowserID) -> String {
        switch target.family {
        case .chromium:
            return "Open \(target.name) in the intended profile. Visit chrome://extensions (the browser may rewrite this URL), enable Developer mode, choose Load unpacked, and select this package’s Importer folder. Click the helper’s toolbar icon to review categories and import. Keep its page open until finished."
        case .firefox:
            return "Open \(target.name) in the intended profile and allow a new profile to finish initialization. Visit about:debugging#/runtime/this-firefox, choose Load Temporary Add-on, and select Importer/manifest.json. Click the helper’s toolbar icon. If bookmark folders are not ready, open the bookmark manager and retry. Temporary add-ons are removed on restart: export the journal and complete rollback first. This helper targets Firefox-compatible WebExtensions 128+; groups depend on newer APIs."
        case .safari:
            return "Safari has no equivalent unpacked helper in this app. Use Safari’s File → Import From / Import Browsing Data menu to import Bookmarks.html where that version offers HTML bookmarks. Tabs and workspace trees arrive as bookmark folders. History is archive-only. Use Safari’s own password import flow for a separately exported password file. Safari menu names vary by release."
        }
    }
}
