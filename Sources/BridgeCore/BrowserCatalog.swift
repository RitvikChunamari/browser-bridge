import Foundation

public enum BrowserFamily: String, Codable, Sendable { case chromium, firefox, safari }

public enum BrowserID: String, CaseIterable, Codable, Identifiable, Sendable {
    case helium, arc, zen, dia, chrome, firefox, brave, safari, edge, opera, vivaldi
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .helium: "Helium"; case .arc: "Arc"; case .zen: "Zen"; case .dia: "Dia"
        case .chrome: "Chrome"; case .firefox: "Firefox"; case .brave: "Brave"; case .safari: "Safari"
        case .edge: "Edge"; case .opera: "Opera"; case .vivaldi: "Vivaldi"
        }
    }
    public var family: BrowserFamily {
        switch self { case .zen, .firefox: .firefox; case .safari: .safari; default: .chromium }
    }
    public var dataPaths: [String] {
        switch self {
        case .helium: ["Library/Application Support/net.imput.helium", "Library/Application Support/Helium"]
        case .arc: ["Library/Application Support/Arc/User Data", "Library/Application Support/Arc"]
        case .zen: ["Library/Application Support/zen"]
        case .dia: ["Library/Application Support/Dia/User Data"]
        case .chrome: ["Library/Application Support/Google/Chrome"]
        case .firefox: ["Library/Application Support/Firefox"]
        case .brave: ["Library/Application Support/BraveSoftware/Brave-Browser"]
        case .safari: ["Library/Safari", "Library/Containers/com.apple.Safari/Data/Library/Safari"]
        case .edge: ["Library/Application Support/Microsoft Edge"]
        case .opera: ["Library/Application Support/com.operasoftware.Opera", "Library/Application Support/com.operasoftware.OperaGX"]
        case .vivaldi: ["Library/Application Support/Vivaldi"]
        }
    }
    public func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        dataPaths.map { home.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    public var extensionsPage: String {
        switch family { case .firefox: "about:debugging#/runtime/this-firefox"; case .safari: "Safari Settings → Extensions"; case .chromium: "chrome://extensions" }
    }
}
