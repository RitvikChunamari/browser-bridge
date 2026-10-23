import Foundation

public struct BrowserProfile: Identifiable, Hashable, Sendable {
    public var id: String { path.path }
    public let name: String
    public let path: URL
    public init(name: String, path: URL) { self.name = name; self.path = path }
}
public struct Space: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
}
public struct Folder: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let parentID: String?
    public let spaceID: String?
}
public struct BrowserTab: Codable, Identifiable, Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let pinned: Bool
    public let essential: Bool
    public let spaceID: String?
    public let folderID: String?
    public let order: Int
    public let originalURL: String?
    public let container: Int
}
public struct Bookmark: Codable, Sendable {
    public let id: Int64
    public let parent: Int64
    public let title: String
    public let url: String?
    public let type: Int
}
public struct HistoryItem: Codable, Sendable {
    public let url: String
    public let title: String
    public let time: Double
}
public struct Snapshot: Codable, Sendable {
    public var spaces: [Space] = []
    public var folders: [Folder] = []
    public var tabs: [BrowserTab] = []
    public var bookmarks: [Bookmark] = []
    public var history: [HistoryItem] = []
    public var passwordCount = 0
    public var cookieCount = 0
    public var sourceFile = ""
    public var warnings: [String] = []
    public init() {}
}
public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}
public struct PackageResult: Sendable {
    public let url: URL
    public let snapshot: Snapshot
}

