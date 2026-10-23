import Foundation
import AppKit

@MainActor public final class MacBrowserLifecycle: TransferLifecycle {
    private let closeTimeout: TimeInterval
    public init(closeTimeout: TimeInterval = 20) { self.closeTimeout=closeTimeout }
    private func executable(_ connection: ConnectorConnection) throws -> URL {
        guard let path=connection.browserExecutable, let version=connection.browserVersion,version != "unknown" else { throw ConnectorError.rejected("Re-pair this profile to record its observed browser executable and version.") }
        let file=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath:file.path),let range=file.path.range(of:".app/") else { throw ConnectorError.rejected("The connected browser executable is missing. Re-pair this profile.") }
        let bundleURL=URL(fileURLWithPath:String(file.path[..<range.lowerBound])+".app")
        guard let bundle=Bundle(url:bundleURL),bundle.executableURL?.resolvingSymlinksInPath()==file,bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String == version else { throw ConnectorError.rejected("The observed browser executable or version changed. Re-pair before transferring.") }
        return file
    }
    private func running(_ connections:[ConnectorConnection]) throws -> [NSRunningApplication] {
        let paths=try Set(connections.map{try executable($0).path})
        return NSWorkspace.shared.runningApplications.filter { app in app.executableURL.map { paths.contains($0.resolvingSymlinksInPath().path) } ?? false }
    }
    public func areClosed(_ connections:[ConnectorConnection]) async -> Bool { (try? running(connections).isEmpty) ?? false }
    public func close(_ connections:[ConnectorConnection]) async throws {
        for app in try running(connections) { guard app.terminate() else { throw ConnectorError.rejected("\(app.localizedName ?? "The browser") did not accept a normal quit. Resolve any prompt and resume; Browser Bridge never force-quits.") } }
        let deadline=Date().addingTimeInterval(closeTimeout)
        while Date()<deadline {
            if try running(connections).isEmpty { return }
            try await Task.sleep(for:.milliseconds(250))
        }
        throw ConnectorError.rejected("The browser is waiting to close. Resolve unsaved-work prompts and resume. It has not been force-quit.")
    }
    public func reopen(_ connection:ConnectorConnection) async throws {
        let file=try executable(connection)
        let profile=URL(fileURLWithPath:connection.profilePath).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath:profile.path) else { throw ConnectorError.rejected("The connected destination profile folder is missing.") }
        let arguments:[String]
        switch connection.browser.family {
        case .chromium:
            guard profile.lastPathComponent=="Default" || profile.lastPathComponent.hasPrefix("Profile ") else { throw ConnectorError.rejected("Automatic Chromium reopening currently requires a Default or Profile folder. Use guided transfer for this layout.") }
            arguments=["--restore-last-session","--user-data-dir=\(profile.deletingLastPathComponent().path)","--profile-directory=\(profile.lastPathComponent)"]
        case .firefox: arguments=["-no-remote","-profile",profile.path]
        case .safari: throw ConnectorError.rejected("Safari uses guided file transfer.")
        }
        let process=Process();process.executableURL=file;process.arguments=arguments
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
    }
}

extension MacBrowserLifecycle {
    /// Synchronous consistency check used by PackageBuilder before and after copying.
    /// Match the observed executable, not a browser-family substring or an unrelated test binary.
    nonisolated public static func backupBlockers(_ connections:[ConnectorConnection]) throws -> [String] {
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/ps");process.arguments=["-A","-ww","-o","comm="];process.standardOutput=pipe
        try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus==0 else { throw ConnectorError.rejected("Cannot verify that connected browsers are closed.") }
        let running=Set(String(decoding:data,as:UTF8.self).components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)})
        var blockers:[String]=[]
        for connection in connections {
            guard let executable=connection.browserExecutable else { throw ConnectorError.rejected("Re-pair to record the observed browser executable.") }
            if running.contains(URL(fileURLWithPath:executable).resolvingSymlinksInPath().path) { blockers.append(connection.browser.name);continue }
            let profile=URL(fileURLWithPath:connection.profilePath)
            if connection.browser.family == .chromium {
                let lock=profile.deletingLastPathComponent().appendingPathComponent("SingletonLock")
                // lexists: a dangling singleton symlink is still a lock that needs browser recovery.
                if (try? FileManager.default.attributesOfItem(atPath:lock.path)) != nil { blockers.append("\(connection.browser.name) profile lock (reopen and quit normally to clear it)") }
            }
        }
        return Array(Set(blockers)).sorted()
    }
}
