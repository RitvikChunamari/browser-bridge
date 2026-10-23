import Foundation
import Darwin
import AppKit
import BridgeCore

// Resolve the direct parent through macOS application identity. proc_pidpath can point at
// code-signing clones (.app.bundle), which are not the app’s stable installed executable.
// Browser messages and labels never select an app, identity, executable or version.
@MainActor func callerBrowser() throws -> (browser: BrowserID, executable: String, version: String) {
    guard let application=NSRunningApplication(processIdentifier:getppid()),
          let identifier=application.bundleIdentifier,
          let bundleURL=application.bundleURL?.resolvingSymlinksInPath(),
          let observedExecutable=application.executableURL?.resolvingSymlinksInPath(),
          let bundle=Bundle(url:bundleURL),bundle.bundleIdentifier==identifier,
          let executable=bundle.executableURL?.resolvingSymlinksInPath(),executable==observedExecutable else {
        throw ConnectorError.rejected("Cannot identify the native host’s calling browser application. Open the supported browser normally and reconnect its connector.")
    }
    let identifiers:[String:BrowserID]=[
        "com.google.Chrome":.chrome,"com.google.chrome.for.testing":.chrome,
        "org.mozilla.firefox":.firefox,"app.zen-browser.zen":.zen,
        "net.imput.helium":.helium,"company.thebrowser.Browser":.arc,
        "company.thebrowser.dia":.dia,"com.brave.Browser":.brave,
        "com.microsoft.edgemac":.edge,"com.operasoftware.Opera":.opera,
        "com.operasoftware.OperaGX":.opera,"com.vivaldi.Vivaldi":.vivaldi
    ]
    guard let browser=identifiers[identifier] else { throw ConnectorError.rejected("The native host was not launched by a supported browser application.") }
    let args=CommandLine.arguments.dropFirst()
    let allowed=browser.family == .firefox ? args.contains("connector@browser-bridge.local") : args.contains("chrome-extension://gagbnkkjaiikbencmbaiancdbigcjlhd/")
    guard allowed else { throw ConnectorError.rejected("The connector origin is not allowed.") }
    return (browser,executable.path,bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown")
}
func readExactly(_ count: Int) throws -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try FileHandle.standardInput.read(upToCount: count - data.count), !chunk.isEmpty else {
            if data.isEmpty { return nil }; throw ConnectorError.rejected("Truncated native frame.")
        }
        data.append(chunk)
    }
    return data
}
func writeFrame(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard data.count < 1_000_000 else { throw ConnectorError.rejected("Native response exceeds browser frame limit.") }
    var length = UInt32(data.count).littleEndian
    try FileHandle.standardOutput.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
    try FileHandle.standardOutput.write(contentsOf: data)
}
do {
    let caller = try callerBrowser()
    let browser = caller.browser
    // Trusted process environment only; extension messages never control filesystem roots.
    let root = ProcessInfo.processInfo.environment["BROWSER_BRIDGE_STATE_ROOT"].map { URL(fileURLWithPath: $0) } ?? ConnectorStore.defaultRoot
    let store = try ConnectorStore(root: root)
    while let prefix = try readExactly(4) {
        let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= 12 * 1024 * 1024, let bytes = try readExactly(Int(length)) else { throw ConnectorError.rejected("Native frame size rejected.") }
        do {
            guard let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ConnectorError.rejected("Expected a JSON message.") }
            func string(_ key: String) throws -> String { guard let value = request[key] as? String else { throw ConnectorError.rejected("Missing \(key).") }; return value }
            switch try string("action") {
            case "pair":
                let connection = try store.pair(code: string("code"), browser: browser, profileID: string("profileID"), label: string("label"), browserExecutable: caller.executable, browserVersion: caller.version)
                try writeFrame(["ok": true, "browser": browser.rawValue, "connectionID": connection.id, "secret": connection.secret])
            case "poll":
                let job = try store.poll(connectionID: string("connectionID"), secret: string("secret"), browser: browser, profileID: string("profileID"), capabilities: request["capabilities"] as? [String] ?? [], browserExecutable: caller.executable, browserVersion: caller.version)
                var response: [String: Any] = ["ok": true, "browser": browser.rawValue]
                if let job { response["job"] = ["id": job.id, "operation": job.operation, "payload": try JSONSerialization.jsonObject(with: job.payload)] }
                try writeFrame(response)
            case "complete":
                guard let result = request["result"] else { throw ConnectorError.rejected("Missing operation result.") }
                try store.complete(connectionID: string("connectionID"), secret: string("secret"), browser: browser, profileID: string("profileID"), jobID: string("jobID"), result: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
                try writeFrame(["ok": true])
            default: throw ConnectorError.rejected("Unknown connector request.")
            }
        } catch { try writeFrame(["ok": false, "error": error.localizedDescription]) }
    }
} catch {
    // Never log captured data or secrets to stdout/stderr.
    try? writeFrame(["ok": false, "error": error.localizedDescription])
    exit(1)
}
