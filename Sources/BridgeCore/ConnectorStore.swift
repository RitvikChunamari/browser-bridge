import Foundation
import Darwin

public struct ConnectorConnection: Codable, Identifiable, Sendable {
    public var id: String
    public var browser: BrowserID
    public var profilePath: String
    public var profileID: String
    public var label: String
    public var secret: String
    public var lastSeen: Date
    public var browserExecutable: String?
    public var browserVersion: String?
    public var capabilities: [String] = []
    public var connected: Bool { Date().timeIntervalSince(lastSeen) < 45 }
}
public struct ConnectorJob: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var connectionID: String
    public var operation: String
    public var payload: Data
    public var createdAt: Date
    public var result: Data?
    public var claimedAt: Date?
}
private struct Pairing: Codable { var code: String; var browser: BrowserID; var path: String; var expires: Date }
private struct ConnectorState: Codable { var connections: [ConnectorConnection] = []; var pairings: [Pairing] = []; var jobs: [ConnectorJob] = [] }
public enum ConnectorError: LocalizedError {
    case rejected(String)
    public var errorDescription: String? { switch self { case .rejected(let reason): reason } }
}
/// Private per-user durable connector state. Paths and pairing codes originate only in the Mac app.
/// Browser messages never select a path, execute code, or create a transfer job.
public final class ConnectorStore: @unchecked Sendable {
    public static var defaultRoot: URL {
        // Trusted app/host launch environment for disposable-profile QA; never read from messages.
        if let override=ProcessInfo.processInfo.environment["BROWSER_BRIDGE_STATE_ROOT"],!override.isEmpty { return URL(fileURLWithPath:override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Browser Bridge/Connector")
    }
    public let root: URL
    public init(root: URL = ConnectorStore.defaultRoot) throws {
        self.root = root
        let fm = FileManager.default
        // Refuse symlink roots/state rather than following redirected local storage.
        if fm.fileExists(atPath: root.path), try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ConnectorError.rejected("Connector state must not be a symbolic link.") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    private func access<T>(_ body: (inout ConnectorState) throws -> T) throws -> T {
        let lockURL = root.appendingPathComponent("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConnectorError.rejected("Cannot lock connector state.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ConnectorError.rejected("Cannot lock connector state.") }
        let path = root.appendingPathComponent("state.json")
        var state = ConnectorState()
        if FileManager.default.fileExists(atPath: path.path) {
            guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ConnectorError.rejected("Unsafe connector state link.") }
            let data = try Data(contentsOf: path)
            guard data.count <= 128 * 1024 * 1024 else { throw ConnectorError.rejected("Connector state is full. Archive completed transfers.") }
            state = try JSONDecoder().decode(ConnectorState.self, from: data)
        }
        let result = try body(&state)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 128 * 1024 * 1024 else { throw ConnectorError.rejected("Connector state is full. Archive completed receipts before continuing.") }
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return result
    }
    public func connections() throws -> [ConnectorConnection] { try access { $0.connections } }
    public func beginPairing(browser: BrowserID, profile: URL) throws -> String {
        guard browser.family != .safari, profile.isFileURL else { throw ConnectorError.rejected("This browser uses the guided file transfer.") }
        let code = UUID().uuidString
        return try access { state in
            state.pairings.removeAll { $0.expires < Date() || ($0.browser == browser && $0.path == profile.standardizedFileURL.path) }
            state.pairings.append(Pairing(code: code, browser: browser, path: profile.standardizedFileURL.path, expires: Date().addingTimeInterval(600)))
            return code
        }
    }
    public func pair(code: String, browser: BrowserID, profileID: String, label: String, browserExecutable: String? = nil, browserVersion: String? = nil) throws -> ConnectorConnection {
        guard UUID(uuidString: profileID) != nil, label.count <= 120 else { throw ConnectorError.rejected("Invalid connector profile identity.") }
        return try access { state in
            guard let index = state.pairings.firstIndex(where: { $0.code == code && $0.browser == browser && $0.expires > Date() }) else { throw ConnectorError.rejected("Pairing code expired, consumed, or belongs to another browser.") }
            let pair = state.pairings.remove(at: index)
            state.connections.removeAll { ($0.browser == browser && $0.profilePath == pair.path) || ($0.browser == browser && $0.profileID == profileID) }
            let connection = ConnectorConnection(id: UUID().uuidString, browser: browser, profilePath: pair.path, profileID: profileID, label: label, secret: UUID().uuidString + UUID().uuidString, lastSeen: Date(), browserExecutable: browserExecutable, browserVersion: browserVersion)
            state.connections.append(connection); return connection
        }
    }
    public func enqueue(connectionID: String, operation: String, payload: Data, jobID: String = UUID().uuidString) throws -> ConnectorJob {
        guard ["capture", "import", "verify", "rollback"].contains(operation), payload.count < 700_000 else { throw ConnectorError.rejected("Unsupported operation or transfer exceeds connector frame limit. Use a file package.") }
        guard UUID(uuidString: jobID) != nil else { throw ConnectorError.rejected("Invalid operation identity.") }
        return try access { state in
            if let existing = state.jobs.first(where: { $0.id == jobID }) {
                guard existing.connectionID == connectionID, existing.operation == operation, existing.payload == payload else { throw ConnectorError.rejected("Operation identity conflicts with existing work.") }
                return existing
            }
            guard state.connections.contains(where: { $0.id == connectionID }) else { throw ConnectorError.rejected("Connect the selected profile first.") }
            guard !state.jobs.contains(where: { $0.connectionID == connectionID && $0.result == nil }) else { throw ConnectorError.rejected("This profile already has an unfinished operation.") }
            let job = ConnectorJob(id: jobID, connectionID: connectionID, operation: operation, payload: payload, createdAt: Date(), result: nil)
            state.jobs.append(job); return job
        }
    }
    private func authorize(_ state: inout ConnectorState, id: String, secret: String, browser: BrowserID, profileID: String, capabilities: [String]) throws {
        guard let index = state.connections.firstIndex(where: { $0.id == id && $0.secret == secret && $0.browser == browser && $0.profileID == profileID }) else { throw ConnectorError.rejected("This profile is not paired. Connect it in the Mac app.") }
        state.connections[index].lastSeen = Date()
        if !capabilities.isEmpty { state.connections[index].capabilities = capabilities.filter { ["bookmarks", "tabs", "history", "groups"].contains($0) } }
    }
    public func poll(connectionID: String, secret: String, browser: BrowserID, profileID: String, capabilities: [String] = [], browserExecutable: String? = nil, browserVersion: String? = nil) throws -> ConnectorJob? {
        try access { state in
            try authorize(&state, id: connectionID, secret: secret, browser: browser, profileID: profileID, capabilities: capabilities)
            if let index = state.connections.firstIndex(where: { $0.id == connectionID }) {
                if let browserExecutable { state.connections[index].browserExecutable = browserExecutable }
                if let browserVersion { state.connections[index].browserVersion = browserVersion }
            }
            guard let index = state.jobs.firstIndex(where: { $0.connectionID == connectionID && $0.result == nil }) else { return nil }
            if state.jobs[index].claimedAt == nil { state.jobs[index].claimedAt = Date() }
            return state.jobs[index]
        }
    }
    public func complete(connectionID: String, secret: String, browser: BrowserID, profileID: String, jobID: String, result: Data) throws {
        guard result.count < 8 * 1024 * 1024 else { throw ConnectorError.rejected("Capture exceeds connector size limit. Use a file package.") }
        try access { state in
            try authorize(&state, id: connectionID, secret: secret, browser: browser, profileID: profileID, capabilities: [])
            guard let index = state.jobs.firstIndex(where: { $0.id == jobID && $0.connectionID == connectionID }) else { throw ConnectorError.rejected("Unknown operation.") }
            if let previous = state.jobs[index].result, previous != result { throw ConnectorError.rejected("Operation already completed with a different result.") }
            state.jobs[index].result = result
        }
    }
    public func forgetCompletedJobs(_ ids: [String]) throws {
        let selected=Set(ids)
        try access { $0.jobs.removeAll { selected.contains($0.id) && $0.result != nil } }
    }
    public func cancelQueuedJob(_ id: String) throws {
        try access { state in
            guard let index=state.jobs.firstIndex(where:{$0.id==id}) else { throw ConnectorError.rejected("The queued operation no longer exists. Refresh the receipt and review its result.") }
            guard state.jobs[index].result == nil else { throw ConnectorError.rejected("This operation already completed. Resume or review the receipt; cancellation cannot undo its effects.") }
            guard state.jobs[index].claimedAt == nil else { throw ConnectorError.rejected("The browser has already received this operation. Resolve its connector or wait for its result; queued cancellation cannot undo effects in progress.") }
            state.jobs[index].result=Data("{\"ok\":false,\"error\":\"Operation cancelled before the browser received it.\"}".utf8)
        }
    }
    public func job(_ id: String) throws -> ConnectorJob? { try access { $0.jobs.first { $0.id == id } } }
    public func result(jobID: String) throws -> Data? { try access { $0.jobs.first { $0.id == jobID }?.result } }
    public func disconnect(_ id: String) throws { try access { $0.connections.removeAll { $0.id == id } } }
}
