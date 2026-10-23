import Foundation
import CryptoKit
import Darwin

public protocol TransferLifecycle: Sendable {
    func close(_ connections: [ConnectorConnection]) async throws
    func reopen(_ connection: ConnectorConnection) async throws
    func areClosed(_ connections: [ConnectorConnection]) async -> Bool
}
public struct TransferOptions: Codable, Sendable {
    public var bookmarks: Bool
    public var tabs: Bool
    public var history: Bool
    public var groups: Bool
    public init(bookmarks: Bool = true, tabs: Bool = true, history: Bool = false, groups: Bool = false) { self.bookmarks=bookmarks; self.tabs=tabs; self.history=history; self.groups=groups }
}
public enum TransferPhase: String, Codable, Sendable { case capturing, capturingDestination, closing, backingUp, reopening, importing, verifying, checkingDestination, complete, paused, rollingBack, rolledBack, rollbackPartial, cancelled }
public struct TransferReceipt: Codable, Identifiable, Sendable {
    public var id: String
    public var source: ConnectorConnection
    public var destination: ConnectorConnection
    public var options: TransferOptions
    public var phase: TransferPhase
    public var packagePath: String
    public var receiptPath: String
    public var capturePath: String
    public var createdAt: Date
    public var updatedAt: Date
    public var jobID: String?
    public var packageID: String?
    public var warnings: [String]
    public var error: String?
    public var verification: Data?
    public var interruptedPhase: TransferPhase?
    public var jobIDs: [String]?
    public var destinationCapturePath: String?
    public var destinationCaptureDigest: String?
    public var destinationBaselineVerification: Data?
}
/// Shipping evidence is a code-reviewed allowlist, never a setting or extension-provided claim.
public struct AutomaticRouteAcceptance: Sendable {
    public let source: BrowserID
    public let sourceVersion: String
    public let sourceExecutableName: String
    public let destination: BrowserID
    public let destinationVersion: String
    public let destinationExecutableName: String
    public let evidence: String
    public init(source:BrowserID,sourceVersion:String,sourceExecutableName:String,destination:BrowserID,destinationVersion:String,destinationExecutableName:String,evidence:String) {
        self.source=source;self.sourceVersion=sourceVersion;self.sourceExecutableName=sourceExecutableName;self.destination=destination;self.destinationVersion=destinationVersion;self.destinationExecutableName=destinationExecutableName;self.evidence=evidence
    }
}
public enum AutomaticRoutes {
    // Add an exact route only after committed full lifecycle evidence, not a family/API smoke check.
    public static let accepted: [AutomaticRouteAcceptance] = [
        AutomaticRouteAcceptance(source:.chrome,sourceVersion:"156.0.8078.48",sourceExecutableName:"Google Chrome",destination:.brave,destinationVersion:"156.1.98.60",destinationExecutableName:"Brave Browser",evidence:"docs/connected-verification.md — uninterrupted macOS lifecycle and destination baseline, 2026-10-23")
    ]
    public static func allows(_ source: ConnectorConnection, _ destination: ConnectorConnection) -> Bool {
        guard source.id != destination.id,source.profilePath != destination.profilePath,let a=source.browserExecutable,let b=destination.browserExecutable else { return false }
        return accepted.contains { $0.source==source.browser && $0.destination==destination.browser && $0.sourceVersion==source.browserVersion && $0.destinationVersion==destination.browserVersion && $0.sourceExecutableName==URL(fileURLWithPath:a).lastPathComponent && $0.destinationExecutableName==URL(fileURLWithPath:b).lastPathComponent }
    }
}
public actor TransferCoordinator {
    public static var defaultReceiptRoot: URL { ConnectorStore.defaultRoot.deletingLastPathComponent().appendingPathComponent("Transfers") }
    private let store: ConnectorStore
    private let lifecycle: any TransferLifecycle
    private let importerResources: URL
    private let receiptRoot: URL
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let backupCheck: @Sendable ([ConnectorConnection]) throws -> [String]
    public private(set) var currentReceipt: TransferReceipt?
    public init(store: ConnectorStore, lifecycle: any TransferLifecycle, importerResources: URL, receiptRoot: URL = TransferCoordinator.defaultReceiptRoot, timeout: TimeInterval = 45, pollInterval: TimeInterval = 0.5, backupCheck: @escaping @Sendable ([ConnectorConnection]) throws -> [String] = MacBrowserLifecycle.backupBlockers) {
        self.store=store; self.lifecycle=lifecycle; self.importerResources=importerResources; self.receiptRoot=receiptRoot; self.timeout=timeout; self.pollInterval=pollInterval; self.backupCheck=backupCheck
    }
    private func acquireRunLock() throws -> Int32 {
        try FileManager.default.createDirectory(at:receiptRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=open(receiptRoot.appendingPathComponent(".run.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd>=0 else { throw ConnectorError.rejected("Cannot lock transfer coordination.") }
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else { close(fd);throw ConnectorError.rejected("Another transfer or recovery is running. Wait for its result before continuing.") }
        return fd
    }
    private func releaseRunLock(_ fd:Int32) { flock(fd,LOCK_UN);close(fd) }
    public func receipts() throws -> [TransferReceipt] {
        guard FileManager.default.fileExists(atPath: receiptRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: receiptRoot, includingPropertiesForKeys: nil).compactMap { folder in
            try? JSONDecoder().decode(TransferReceipt.self, from: Data(contentsOf: folder.appendingPathComponent("receipt.json")))
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private func save(_ receipt: inout TransferReceipt, phase: TransferPhase? = nil) throws {
        if let phase { receipt.phase=phase }; receipt.updatedAt=Date()
        let file = URL(fileURLWithPath: receipt.receiptPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        // Receipts contain paths and data, but never connector authentication secrets.
        var redacted=receipt; redacted.source.secret=""; redacted.destination.secret=""
        try encoder.encode(redacted).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        currentReceipt=redacted
    }
    private func pause(_ seconds: TimeInterval) async throws { try await Task.sleep(for: .milliseconds(Int64(seconds*1000))) }
    private func command(_ connection: ConnectorConnection, operation: String, payload: Data, receipt: inout TransferReceipt, recovering: Bool = false, freshObservation: Bool = false) async throws -> [String:Any] {
        var prior: ConnectorJob?
        if recovering,let id=receipt.jobID,let job=try store.job(id),job.connectionID==connection.id,job.operation==operation,job.payload==payload {
            if (operation=="verify" || freshObservation),job.result != nil { prior=nil }
            else if let result=job.result,let object=(try? JSONSerialization.jsonObject(with:result)) as? [String:Any],object["ok"] as? Bool == false { prior=nil } else { prior=job }
        }
        let id=prior?.id ?? UUID().uuidString
        let previousID=receipt.jobID,previousIDs=receipt.jobIDs
        receipt.jobID=id;receipt.jobIDs = Array(Set((receipt.jobIDs ?? []) + [id]));try save(&receipt)
        let job:ConnectorJob
        do { job=try store.enqueue(connectionID:connection.id,operation:operation,payload:payload,jobID:id) }
        catch {
            // A queue conflict must not orphan the operation that the receipt already tracked.
            receipt.jobID=previousID;receipt.jobIDs=previousIDs;try save(&receipt);throw error
        }
        let deadline=Date().addingTimeInterval(timeout)
        while Date()<deadline {
            try Task.checkCancellation()
            if let result=try store.result(jobID:job.id) {
                guard let object=try JSONSerialization.jsonObject(with:result) as? [String:Any], object["ok"] as? Bool == true else {
                    let value=(try? JSONSerialization.jsonObject(with:result)) as? [String:Any]
                    throw ConnectorError.rejected(value?["error"] as? String ?? "The browser operation failed. The local package is retained.")
                }
                return object
            }
            try await pause(pollInterval)
        }
        throw ConnectorError.rejected("The browser did not finish \(operation). Open the exact connected profile and review its connector. This transfer is paused; do not start another import.")
    }
    private func ready(_ connection: ConnectorConnection, after: Date) async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while Date()<deadline {
            if let actual=try store.connections().first(where:{$0.id==connection.id && $0.profileID==connection.profileID && $0.lastSeen>after}) {
                guard actual.browserExecutable==connection.browserExecutable, actual.browserVersion==connection.browserVersion else { throw ConnectorError.rejected("The connected browser executable or version changed. Re-pair and revalidate this route.") }
                return
            }
            try await pause(pollInterval)
        }
        throw ConnectorError.rejected("Waiting for the exact destination profile’s connector after reopening. Reinstall temporary add-ons if needed; no import has been requested yet.")
    }
    public func transfer(source: ConnectorConnection, destination: ConnectorConnection, package: URL, options: TransferOptions, validationRoot: URL? = nil) async throws -> TransferReceipt {
        let lease=try acquireRunLock();defer{releaseRunLock(lease)}
        guard currentReceipt == nil || [.complete,.paused,.rolledBack,.rollbackPartial,.cancelled].contains(currentReceipt!.phase) else { throw ConnectorError.rejected("A transfer is already running.") }
        guard source.id != destination.id, source.profilePath != destination.profilePath else { throw ConnectorError.rejected("Choose different source and destination profiles.") }
        guard source.connected,destination.connected else { throw ConnectorError.rejected("Open and connect both exact profiles before starting.") }
        if let root=validationRoot?.resolvingSymlinksInPath() {
            for path in [source.profilePath,destination.profilePath] {
                guard URL(fileURLWithPath:path).resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else { throw ConnectorError.rejected("Validation may use only profiles inside the explicit disposable test root.") }
            }
        } else {
            guard AutomaticRoutes.allows(source,destination) else { throw ConnectorError.rejected("This browser pair has not passed full lifecycle validation. Use the guided package flow.") }
        }
        guard options.bookmarks || options.tabs || options.history else { throw ConnectorError.rejected("Select at least one transfer category.") }
        if options.history { guard source.capabilities.contains("history"),destination.capabilities.contains("history") else { throw ConnectorError.rejected("Grant optional history permission in both connectors first.") } }
        if options.groups { guard source.capabilities.contains("groups"),destination.capabilities.contains("groups") else { throw ConnectorError.rejected("Grant optional tab-group permission in both connectors first.") } }
        let id=UUID().uuidString, folder=receiptRoot.appendingPathComponent(UUID().uuidString)
        var receipt=TransferReceipt(id:id,source:source,destination:destination,options:options,phase:.capturing,packagePath:package.path,receiptPath:folder.appendingPathComponent("receipt.json").path,capturePath:folder.appendingPathComponent("source-capture.json").path,createdAt:Date(),updatedAt:Date(),warnings:["Connected transfer uses live browser APIs. Browser windows approximate spaces; native Essentials, Arc Favorites, native spaces, credentials and active sessions remain archive-only or guided."])
        receipt.source.secret="";receipt.destination.secret=""
        try save(&receipt)
        return try await execute(&receipt,source:source,destination:destination,recovering:false)
    }
    public func readReceipt(_ url:URL) throws -> TransferReceipt {
        let file=url.resolvingSymlinksInPath(),base=receiptRoot.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path+"/"),file.lastPathComponent=="receipt.json" else { throw ConnectorError.rejected("Choose a receipt from this connector’s private Transfers folder.") }
        let receipt=try JSONDecoder().decode(TransferReceipt.self,from:Data(contentsOf:file))
        guard URL(fileURLWithPath:receipt.receiptPath).resolvingSymlinksInPath()==file,URL(fileURLWithPath:receipt.capturePath).deletingLastPathComponent().resolvingSymlinksInPath()==file.deletingLastPathComponent() else { throw ConnectorError.rejected("The receipt paths do not match its private folder.") }
        return receipt
    }
    private func connections(for receipt:TransferReceipt,validationRoot:URL?) throws -> (ConnectorConnection,ConnectorConnection) {
        let current=try store.connections()
        func match(_ saved:ConnectorConnection) throws -> ConnectorConnection {
            guard let actual=current.first(where:{$0.id==saved.id && $0.profileID==saved.profileID && $0.browser==saved.browser && $0.profilePath==saved.profilePath && $0.browserExecutable==saved.browserExecutable && $0.browserVersion==saved.browserVersion}) else { throw ConnectorError.rejected("An original connection, profile, executable or version changed. Restore/reconnect the original profile before recovery.") }
            return actual
        }
        let source=try match(receipt.source),destination=try match(receipt.destination)
        if let root=validationRoot?.resolvingSymlinksInPath() {
            for path in [source.profilePath,destination.profilePath] { guard URL(fileURLWithPath:path).resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else { throw ConnectorError.rejected("Recovery validation requires disposable profiles inside its explicit root.") } }
        } else { guard AutomaticRoutes.allows(source,destination) else { throw ConnectorError.rejected("This recovery route is unverified. Keep the backup and use guided recovery.") } }
        return (source,destination)
    }
    private func verifyBackup(_ receipt:TransferReceipt) throws {
        let root=URL(fileURLWithPath:receipt.packagePath).resolvingSymlinksInPath()
        guard let report=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("transfer-report.json"))) as? [String:Any],report["sourceProfile"] as? String==URL(fileURLWithPath:receipt.source.profilePath).resolvingSymlinksInPath().path,report["destinationProfile"] as? String==URL(fileURLWithPath:receipt.destination.profilePath).resolvingSymlinksInPath().path else { throw ConnectorError.rejected("The backup package does not match this receipt’s exact profiles.") }
        if let id=receipt.packageID,report["packageID"] as? String != id { throw ConnectorError.rejected("The backup package identity changed.") }
        guard let entries=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("backup-manifest.json"))) as? [[String:String]],!entries.isEmpty else { throw ConnectorError.rejected("The backup manifest is empty or invalid.") }
        for entry in entries {
            guard let relative=entry["path"],!relative.hasPrefix("/"),!relative.components(separatedBy:"/").contains(".."),let hash=entry["sha256"] else { throw ConnectorError.rejected("The backup manifest contains unsafe paths.") }
            let file=root.appendingPathComponent(relative)
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.path+"/"),try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]).isRegularFile==true,try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw ConnectorError.rejected("The backup contains a missing or redirected file.") }
            let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()};var digest=SHA256()
            while let bytes=try handle.read(upToCount:1024*1024),!bytes.isEmpty { digest.update(data:bytes) }
            guard digest.finalize().map({String(format:"%02x",$0)}).joined()==hash else { throw ConnectorError.rejected("A backup checksum changed. No further import will be requested.") }
        }
    }
    private func input(_ receipt:TransferReceipt) throws -> Data {
        let root=URL(fileURLWithPath:receipt.packagePath)
        let capture=URL(fileURLWithPath:receipt.capturePath)
        guard try Data(contentsOf:capture)==Data(contentsOf:root.appendingPathComponent("Live Capture.json")) else { throw ConnectorError.rejected("The live capture differs from its checksummed backup copy.") }
        let live=try PortableCapture.load(capture,expectedBrowser:receipt.source.browser)
        guard let report=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("transfer-report.json"))) as? [String:Any],let id=report["packageID"] as? String else { throw ConnectorError.rejected("Backup package identity is missing.") }
        let payload:[String:Any]=["schema":1,"packageID":id,"createdAt":ISO8601DateFormatter().string(from:receipt.createdAt),"snapshot":try JSONSerialization.jsonObject(with:JSONEncoder().encode(live.snapshot))]
        let o=receipt.options,input:[String:Any]=["package":payload,"options":["bookmarks":o.bookmarks,"tabs":o.tabs,"history":o.history,"groups":o.groups,"space":"*","limit":50]]
        let data=try JSONSerialization.data(withJSONObject:input,options:[.sortedKeys])
        guard data.count<700_000 else { throw ConnectorError.rejected("The verified backup is ready, but this transfer exceeds the connector limit. Use its guided file package.") }
        return data
    }
    public func resume(receiptURL:URL,validationRoot:URL? = nil) async throws -> TransferReceipt {
        let lease=try acquireRunLock();defer{releaseRunLock(lease)}
        var receipt=try readReceipt(receiptURL)
        if receipt.phase == .complete { return receipt }
        let interrupted=receipt.phase == .paused ? receipt.interruptedPhase : receipt.phase
        guard let interrupted,[.capturing,.capturingDestination,.closing,.backingUp,.reopening,.importing,.verifying,.checkingDestination,.rollingBack].contains(interrupted) else { throw ConnectorError.rejected("This receipt cannot be resumed.") }
        if interrupted == .rollingBack {
            guard let destination=try store.connections().first(where:{$0.id==receipt.destination.id && $0.profileID==receipt.destination.profileID && $0.browser==receipt.destination.browser && $0.profilePath==receipt.destination.profilePath && $0.browserExecutable==receipt.destination.browserExecutable && $0.browserVersion==receipt.destination.browserVersion}) else { throw ConnectorError.rejected("Reconnect the original destination before resuming rollback.") }
            if let root=validationRoot?.resolvingSymlinksInPath() { guard URL(fileURLWithPath:destination.profilePath).resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else { throw ConnectorError.rejected("Rollback destination is outside the disposable root.") } }
            else { guard AutomaticRoutes.allows(receipt.source,destination) else { throw ConnectorError.rejected("This rollback route is unverified.") } }
            receipt.phase=interrupted;receipt.error=nil;try save(&receipt)
            return try await performRollback(&receipt,destination:destination,recovering:true)
        }
        let (source,destination)=try connections(for:receipt,validationRoot:validationRoot)
        receipt.phase=interrupted;receipt.error=nil;try save(&receipt)
        return try await execute(&receipt,source:source,destination:destination,recovering:true)
    }
    private func verifyDestinationBaseline(_ receipt:inout TransferReceipt,destination:ConnectorConnection) async throws {
        guard let path=receipt.destinationCapturePath,let digest=receipt.destinationCaptureDigest else {
            if !receipt.warnings.contains("This older receipt has no destination-session baseline; existing-state preservation was not independently verified.") { receipt.warnings.append("This older receipt has no destination-session baseline; existing-state preservation was not independently verified.");try save(&receipt) }
            return
        }
        let file=URL(fileURLWithPath:path)
        guard file.deletingLastPathComponent().resolvingSymlinksInPath()==URL(fileURLWithPath:receipt.receiptPath).deletingLastPathComponent().resolvingSymlinksInPath() else { throw ConnectorError.rejected("Destination baseline is outside the receipt folder.") }
        let data=try Data(contentsOf:file)
        guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==digest else { throw ConnectorError.rejected("Destination baseline checksum changed. Recovery is paused.") }
        let baseline=try PortableCapture.load(file,expectedBrowser:destination.browser)
        let result=try await command(destination,operation:"capture",payload:JSONSerialization.data(withJSONObject:["history":false]),receipt:&receipt,recovering:true,freshObservation:true)
        guard let object=result["capture"] else { throw ConnectorError.rejected("The destination returned no preservation check.") }
        let current=try JSONDecoder().decode(PortableCapture.self,from:JSONSerialization.data(withJSONObject:object))
        guard current.browser==destination.browser,current.schema==1,current.format=="browser-bridge-capture" else { throw ConnectorError.rejected("Destination preservation check has the wrong browser identity.") }
        func safe(_ url:String)->Bool { ["http","https"].contains(URL(string:url)?.scheme?.lowercased() ?? "") }
        func tabs(_ snapshot:Snapshot) throws -> [String] {
            try snapshot.tabs.compactMap { tab in
                let url=tab.originalURL ?? tab.url;guard safe(url) else {return nil}
                let group=tab.folderID.flatMap { id in snapshot.folders.first{$0.id==id}?.name } ?? ""
                return String(decoding:try JSONEncoder().encode([url,tab.pinned ? "pinned":"unpinned",group]),as:UTF8.self)
            }
        }
        func bookmarks(_ snapshot:Snapshot) throws -> [String] {
            func path(_ id:Int64,_ seen:Set<Int64>)->[String] {
                guard !seen.contains(id),let folder=snapshot.bookmarks.first(where:{$0.id==id && $0.type==2}) else {return []}
                return path(folder.parent,seen.union([id]))+[folder.title]
            }
            return try snapshot.bookmarks.compactMap { bookmark in
                guard let url=bookmark.url,safe(url) else {return nil}
                return String(decoding:try JSONEncoder().encode(path(bookmark.parent,[])+[bookmark.title,url]),as:UTF8.self)
            }
        }
        func missing(_ expected:[String],_ actual:[String])->Int {
            var counts:[String:Int]=[:];for key in actual{counts[key,default:0]+=1};var missing=0
            for key in expected {if counts[key,default:0]>0{counts[key,default:0]-=1}else{missing+=1}};return missing
        }
        let expectedTabs=try tabs(baseline.snapshot),expectedBookmarks=try bookmarks(baseline.snapshot)
        let missingTabs=try missing(expectedTabs,tabs(current.snapshot)),missingBookmarks=try missing(expectedBookmarks,bookmarks(current.snapshot))
        let report:[String:Any]=["expectedTabs":expectedTabs.count,"expectedBookmarks":expectedBookmarks.count,"missingTabs":missingTabs,"missingBookmarks":missingBookmarks,"checkedAt":ISO8601DateFormatter().string(from:Date())]
        receipt.destinationBaselineVerification=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]);try save(&receipt)
        guard missingTabs==0,missingBookmarks==0 else { throw ConnectorError.rejected("The destination’s previous session was not fully preserved (\(missingTabs) tabs/pins/groups and \(missingBookmarks) bookmarks differ). No further import is requested. Restore its previous session from the retained backup or browser History, then Resume.") }
    }
    private func execute(_ receipt:inout TransferReceipt,source:ConnectorConnection,destination:ConnectorConnection,recovering:Bool) async throws -> TransferReceipt {
        var recoverCommand=recovering
        let package=URL(fileURLWithPath:receipt.packagePath)
        do {
            while true {
                switch receipt.phase {
                case .capturing:
                    let result=try await command(source,operation:"capture",payload:JSONSerialization.data(withJSONObject:["history":receipt.options.history]),receipt:&receipt,recovering:recoverCommand);recoverCommand=false
                    guard let capture=result["capture"] else { throw ConnectorError.rejected("Source connector returned no capture.") }
                    try JSONSerialization.data(withJSONObject:capture,options:[.sortedKeys]).write(to:URL(fileURLWithPath:receipt.capturePath),options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.capturePath)
                    let live=try PortableCapture.load(URL(fileURLWithPath:receipt.capturePath),expectedBrowser:source.browser)
                    receipt.warnings += live.snapshot.warnings;try save(&receipt,phase:.capturingDestination)
                case .capturingDestination:
                    let result=try await command(destination,operation:"capture",payload:JSONSerialization.data(withJSONObject:["history":false]),receipt:&receipt,recovering:recoverCommand);recoverCommand=false
                    guard let capture=result["capture"] else { throw ConnectorError.rejected("The destination returned no pre-transfer baseline capture.") }
                    let data=try JSONSerialization.data(withJSONObject:capture,options:[.sortedKeys])
                    let path=URL(fileURLWithPath:receipt.receiptPath).deletingLastPathComponent().appendingPathComponent("destination-capture.json")
                    try data.write(to:path,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
                    _=try PortableCapture.load(path,expectedBrowser:destination.browser)
                    receipt.destinationCapturePath=path.path;receipt.destinationCaptureDigest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
                    receipt.warnings.append("Destination baseline checks cover HTTP(S) tabs, pins, exposed group names and bookmark paths. Browser-internal tabs, page content, active sessions and native workspace layout are not verified.")
                    try save(&receipt,phase:.closing)
                case .closing:
                    try await lifecycle.close([source,destination])
                    guard await lifecycle.areClosed([source,destination]) else { throw ConnectorError.rejected("A selected browser is still open. Resolve its unsaved-work prompt, then resume.") }
                    try save(&receipt,phase:.backingUp)
                case .backingUp:
                    guard await lifecycle.areClosed([source,destination]) else { throw ConnectorError.rejected("Close both selected browser apps normally before resuming backup.") }
                    if !FileManager.default.fileExists(atPath:package.path) {
                        _=try PackageBuilder(importerResources:importerResources).create(source:URL(fileURLWithPath:source.profilePath),sourceBrowser:source.browser,targetBrowser:destination.browser,targetProfile:URL(fileURLWithPath:destination.profilePath),destination:package,captureURL:URL(fileURLWithPath:receipt.capturePath),runningBrowsers:{try self.backupCheck([source,destination])})
                    }
                    try verifyBackup(receipt)
                    guard await lifecycle.areClosed([source,destination]) else { throw ConnectorError.rejected("A selected browser reopened during backup. No import was requested.") }
                    let inputData=try input(receipt)
                    try inputData.write(to:package.appendingPathComponent("connected-payload.json"),options:.atomic)
                    let object=try JSONSerialization.jsonObject(with:inputData) as? [String:Any]
                    receipt.packageID=(object?["package"] as? [String:Any])?["packageID"] as? String
                    try save(&receipt,phase:.reopening)
                case .reopening:
                    try verifyBackup(receipt)
                    let opened=Date();try await lifecycle.reopen(destination);try await ready(destination,after:opened)
                    try await verifyDestinationBaseline(&receipt,destination:destination)
                    try save(&receipt,phase:.importing)
                case .importing:
                    try verifyBackup(receipt)
                    let inputData=try input(receipt)
                    var remaining=Int.max,batches=0
                    repeat {
                        let result=try await command(destination,operation:"import",payload:inputData,receipt:&receipt,recovering:recoverCommand);recoverCommand=false
                        guard let journal=result["journal"] as? [String:Any],let next=journal["remainingTabs"] as? Int ?? (receipt.options.tabs ? nil : 0) else { throw ConnectorError.rejected("Destination returned an incomplete import journal.") }
                        if let errors=journal["errors"] as? [String] { receipt.warnings += errors }
                        guard next==0 || next<remaining else { throw ConnectorError.rejected("Tab import made no progress. Review its journal before resuming.") }
                        remaining=next;batches+=1
                        guard batches<=4_001 else { throw ConnectorError.rejected("Tab batch safety limit reached.") }
                    } while remaining>0
                    try save(&receipt,phase:.verifying)
                case .verifying:
                    try verifyBackup(receipt)
                    let verified=try await command(destination,operation:"verify",payload:input(receipt),receipt:&receipt,recovering:recoverCommand);recoverCommand=false
                    receipt.verification=try JSONSerialization.data(withJSONObject:verified,options:[.sortedKeys])
                    guard let mismatches=verified["mismatches"] as? [String],mismatches.isEmpty else { throw ConnectorError.rejected("Destination verification found differences. The backup and observed result are retained.") }
                    try save(&receipt,phase:.checkingDestination)
                case .checkingDestination:
                    try await verifyDestinationBaseline(&receipt,destination:destination)
                    receipt.error=nil;receipt.interruptedPhase=nil;try save(&receipt,phase:.complete);try? store.forgetCompletedJobs(receipt.jobIDs ?? []);return receipt
                case .complete:return receipt
                default:throw ConnectorError.rejected("This receipt phase requires explicit recovery review.")
                }
            }
        } catch {
            receipt.interruptedPhase=receipt.phase;receipt.error=error.localizedDescription;try save(&receipt,phase:.paused);throw error
        }
    }
    public func rollback(receiptURL:URL,confirmedOwnedBookmarkEditsRemoval:Bool,validationRoot:URL? = nil) async throws -> TransferReceipt {
        let lease=try acquireRunLock();defer{releaseRunLock(lease)}
        guard confirmedOwnedBookmarkEditsRemoval else { throw ConnectorError.rejected("Confirm that rollback removes helper-owned bookmark trees including your edits; history and changed/restarted tabs are retained.") }
        var receipt=try readReceipt(receiptURL)
        guard receipt.packageID != nil,[.complete,.paused,.rollbackPartial].contains(receipt.phase) else { throw ConnectorError.rejected("This transfer has no applied package eligible for rollback.") }
        guard let destination=try store.connections().first(where:{$0.id==receipt.destination.id && $0.profileID==receipt.destination.profileID && $0.profilePath==receipt.destination.profilePath && $0.browser==receipt.destination.browser && $0.browserExecutable==receipt.destination.browserExecutable && $0.browserVersion==receipt.destination.browserVersion}) else { throw ConnectorError.rejected("Reconnect the original destination profile before rollback. The source does not need to remain connected.") }
        if let root=validationRoot?.resolvingSymlinksInPath() {
            guard URL(fileURLWithPath:destination.profilePath).resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else { throw ConnectorError.rejected("Rollback validation requires a disposable destination inside its explicit root.") }
        } else { guard AutomaticRoutes.allows(receipt.source,destination) else { throw ConnectorError.rejected("This rollback route is unverified. Preserve its backup and use guided recovery.") } }
        try save(&receipt,phase:.rollingBack)
        return try await performRollback(&receipt,destination:destination,recovering:false)
    }
    private func performRollback(_ receipt:inout TransferReceipt,destination:ConnectorConnection,recovering:Bool) async throws -> TransferReceipt {
        do {
            guard let id=receipt.packageID else { throw ConnectorError.rejected("No package identity exists for rollback.") }
            let result=try await command(destination,operation:"rollback",payload:JSONSerialization.data(withJSONObject:["packageID":id],options:[.sortedKeys]),receipt:&receipt,recovering:recovering)
            guard let journal=result["journal"] as? [String:Any],let state=journal["state"] as? String,["rolled-back","rollback-partial"].contains(state) else { throw ConnectorError.rejected("Rollback did not return a valid result.") }
            receipt.verification=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]);receipt.error=nil;receipt.interruptedPhase=nil
            try save(&receipt,phase:state=="rolled-back" ? .rolledBack : .rollbackPartial);try? store.forgetCompletedJobs(receipt.jobIDs ?? []);return receipt
        } catch {receipt.interruptedPhase = .rollingBack;receipt.error=error.localizedDescription;try save(&receipt,phase:.paused);throw error}
    }
    public func cancelUnclaimed(receiptURL:URL) throws -> TransferReceipt {
        let lease=try acquireRunLock();defer{releaseRunLock(lease)}
        var receipt=try readReceipt(receiptURL)
        guard receipt.phase == .paused,let id=receipt.jobID,let phase=receipt.interruptedPhase else { throw ConnectorError.rejected("Only a paused unclaimed operation can be cancelled.") }
        let operation:String,connectionID:String
        switch phase {
        case .capturing:operation="capture";connectionID=receipt.source.id
        case .capturingDestination,.checkingDestination:operation="capture";connectionID=receipt.destination.id
        case .importing:operation="import";connectionID=receipt.destination.id
        case .verifying:operation="verify";connectionID=receipt.destination.id
        case .rollingBack:operation="rollback";connectionID=receipt.destination.id
        default:throw ConnectorError.rejected("This phase has no pending browser operation to cancel. Resume or review the receipt.")
        }
        guard let job=try store.job(id),job.connectionID==connectionID,job.operation==operation else { throw ConnectorError.rejected("The queued operation does not match this receipt’s active phase. Refresh and review its result.") }
        if operation != "capture" {
            let object=try JSONSerialization.jsonObject(with:job.payload) as? [String:Any]
            let packageID=operation=="rollback" ? object?["packageID"] as? String : (object?["package"] as? [String:Any])?["packageID"] as? String
            guard let packageID,packageID==receipt.packageID else { throw ConnectorError.rejected("The queued operation belongs to a different transfer package.") }
        }
        // Store cancellation atomically rejects a result that arrived after the receipt was read.
        try store.cancelQueuedJob(id)
        if [.capturing,.capturingDestination].contains(phase) && receipt.packageID == nil {
            receipt.error="Pre-transfer capture cancelled before browser delivery. No import was requested."
            try save(&receipt,phase:.cancelled)
        } else {
            receipt.error="This undelivered step was cancelled. Earlier imported items and backups remain. Resume retries the step; Roll back reviews helper changes."
            // Cancelling a later step does not cancel the transfer or erase recovery of prior effects.
            try save(&receipt,phase:.paused)
        }
        return receipt
    }
}
