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

    public init(id: String, url: String, title: String, pinned: Bool = false, essential: Bool = false, spaceID: String? = nil, folderID: String? = nil, order: Int = 0, originalURL: String? = nil, container: Int = 0) {
        self.id = id; self.url = url; self.title = title; self.pinned = pinned; self.essential = essential; self.spaceID = spaceID; self.folderID = folderID; self.order = order; self.originalURL = originalURL; self.container = container
    }
}
public struct Bookmark: Codable, Sendable {
    public let id: Int64
    public let parent: Int64
    public let title: String
    public let url: String?
    public let type: Int

    public init(id: Int64, parent: Int64, title: String, url: String? = nil, type: Int = 1) {
        self.id = id; self.parent = parent; self.title = title; self.url = url; self.type = type
    }
}
public struct HistoryItem: Codable, Sendable {
    public let url: String
    public let title: String
    public let time: Double
    public var visitCount: Int
    public var typedCount: Int

    public init(url: String, title: String, time: Double, visitCount: Int = 1, typedCount: Int = 0) {
        self.url = url
        self.title = title
        self.time = time
        self.visitCount = visitCount
        self.typedCount = typedCount
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, time, visitCount, typedCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? url
        self.time = try container.decodeIfPresent(Double.self, forKey: .time) ?? 0
        self.visitCount = try container.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
        self.typedCount = try container.decodeIfPresent(Int.self, forKey: .typedCount) ?? 0
    }
}
public struct Snapshot: Codable, Sendable {
    public var nativeOrganization: NativeOrganization? = nil
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

