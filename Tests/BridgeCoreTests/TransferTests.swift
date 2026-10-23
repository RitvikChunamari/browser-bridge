import Foundation
import Testing
@testable import BridgeCore

@Test func transferCannotApplyBeforeBackupAndRetainsReceipt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ConnectorStore(root: root.appendingPathComponent("state"))
    let source = root.appendingPathComponent("source/Default"), target = root.appendingPathComponent("target/Default")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to:source.deletingLastPathComponent().appendingPathComponent("Local State"))
    let sourceID = UUID().uuidString, targetID = UUID().uuidString
    let a = try store.pair(code: store.beginPairing(browser: .chrome, profile: source), browser: .chrome, profileID: sourceID, label: "Source")
    let b = try store.pair(code: store.beginPairing(browser: .chrome, profile: target), browser: .chrome, profileID: targetID, label: "Target")
    let package = root.appendingPathComponent("package")
    let lifecycle = FixtureLifecycle()
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Importer")
    let coordinator = TransferCoordinator(store: store, lifecycle: lifecycle, importerResources: resources, receiptRoot: root.appendingPathComponent("receipts"), timeout: 3, pollInterval: 0.01, backupCheck: { _ in [] })
    let worker = Task {
        while !Task.isCancelled {
            for c in [a,b] {
                if let job = try? store.poll(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID) {
                    var result: [String:Any]
                    if job.operation == "capture" { result = ["ok":true,"capture":["schema":1,"format":"browser-bridge-capture","browser":"chrome","capturedAt":"2026-10-23T00:00:00Z","snapshot":try JSONSerialization.jsonObject(with: JSONEncoder().encode(Snapshot()))]] }
                    else {
                        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("backup-manifest.json").path))
                        if job.operation == "rollback" { result=["ok":true,"journal":["state":"rolled-back","tabs":[],"history":[],"errors":[]]] }
                        else { result = job.operation == "import" ? ["ok":true,"journal":["state":"complete","remainingTabs":0,"errors":[]]] : ["ok":true,"mismatches":[],"observed":["bookmarks":0,"tabs":0]] }
                    }
                    try store.complete(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID,jobID:job.id,result:JSONSerialization.data(withJSONObject:result))
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    defer { worker.cancel() }
    let receipt = try await coordinator.transfer(source:a,destination:b,package:package,options:TransferOptions(),validationRoot:root)
    #expect(receipt.phase == .complete)
    #expect(FileManager.default.fileExists(atPath:package.appendingPathComponent("Backups/Chrome-Global/source/Local State").path))
    #expect(FileManager.default.fileExists(atPath: receipt.receiptPath))
    let saved = try String(contentsOfFile: receipt.receiptPath,encoding:.utf8)
    #expect(!saved.contains(a.secret) && !saved.contains(b.secret))
    #expect(await lifecycle.events == ["close", "open"])
    do { _=try await coordinator.rollback(receiptURL:URL(fileURLWithPath:receipt.receiptPath),confirmedOwnedBookmarkEditsRemoval:false,validationRoot:root);Issue.record("Rollback requires explicit warning acknowledgement") } catch {}
    try store.disconnect(a.id) // Source may be removed after a completed migration.
    let rolledBack=try await coordinator.rollback(receiptURL:URL(fileURLWithPath:receipt.receiptPath),confirmedOwnedBookmarkEditsRemoval:true,validationRoot:root)
    #expect(rolledBack.phase == .rolledBack)
}
private actor FixtureLifecycle: TransferLifecycle {
    var events: [String] = []
    func close(_ connections: [ConnectorConnection]) async throws { events.append("close") }
    func reopen(_ connection: ConnectorConnection) async throws { events.append("open") }
    func areClosed(_ connections: [ConnectorConnection]) async -> Bool { true }
}

@Test func pausedAfterBackupResumesWithoutRecaptureOrDuplicateApply() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=try ConnectorStore(root:root.appendingPathComponent("state"))
    let source=root.appendingPathComponent("source/Default"),target=root.appendingPathComponent("target/Default")
    for path in [source,target] { try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true) }
    let a=try store.pair(code:store.beginPairing(browser:.chrome,profile:source),browser:.chrome,profileID:UUID().uuidString,label:"Source")
    let b=try store.pair(code:store.beginPairing(browser:.chrome,profile:target),browser:.chrome,profileID:UUID().uuidString,label:"Target")
    let resources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Importer")
    let lifecycle=RecoveringLifecycle()
    let coordinator=TransferCoordinator(store:store,lifecycle:lifecycle,importerResources:resources,receiptRoot:root.appendingPathComponent("receipts"),timeout:0.2,pollInterval:0.01,backupCheck:{_ in []})
    let counts=OperationCounts()
    let worker=Task {
        while !Task.isCancelled {
            for c in [a,b] {
                guard let job=try store.poll(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID) else { continue }
                await counts.record(job.operation + (c.id == a.id ? ":source" : ":destination"))
                let result:[String:Any]
                if job.operation=="capture" { result=["ok":true,"capture":["schema":1,"format":"browser-bridge-capture","browser":"chrome","capturedAt":"2026-10-23T00:00:00Z","snapshot":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Snapshot()))]] }
                else if job.operation=="import" { result=["ok":true,"journal":["state":"complete","remainingTabs":0,"errors":[]]] }
                else { result=["ok":true,"mismatches":[],"observed":["bookmarks":0,"tabs":0]] }
                try store.complete(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID,jobID:job.id,result:JSONSerialization.data(withJSONObject:result))
            }
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    defer { worker.cancel() }
    do { _=try await coordinator.transfer(source:a,destination:b,package:root.appendingPathComponent("package"),options:TransferOptions(),validationRoot:root);Issue.record("Expected reopen pause") } catch {}
    let paused=try #require(await coordinator.currentReceipt)
    #expect(paused.phase == .paused)
    #expect(paused.interruptedPhase == .reopening)
    await lifecycle.allowReopen()
    let reopened=TransferCoordinator(store:store,lifecycle:lifecycle,importerResources:resources,receiptRoot:root.appendingPathComponent("receipts"),timeout:1,pollInterval:0.01,backupCheck:{_ in []})
    let backupCapture=root.appendingPathComponent("package/Live Capture.json"),original=try Data(contentsOf:root.appendingPathComponent("package/Live Capture.json"))
    try Data("tampered".utf8).write(to:backupCapture)
    do { _=try await reopened.resume(receiptURL:URL(fileURLWithPath:paused.receiptPath),validationRoot:root);Issue.record("A modified backup must block recovery") } catch {}
    #expect(await counts.values["import:destination"] == nil)
    try original.write(to:backupCapture)
    let finished=try await reopened.resume(receiptURL:URL(fileURLWithPath:paused.receiptPath),validationRoot:root)
    #expect(finished.phase == .complete)
    #expect(await counts.values["capture:source"] == 1)
    #expect(await counts.values["import:destination"] == 1)
}
private actor RecoveringLifecycle: TransferLifecycle {
    var allowed=false
    func allowReopen(){allowed=true}
    func close(_ connections:[ConnectorConnection]) async throws {}
    func areClosed(_ connections:[ConnectorConnection]) async -> Bool { true }
    func reopen(_ connection:ConnectorConnection) async throws { if !allowed { throw ConnectorError.rejected("Browser needs setup.") } }
}
private actor OperationCounts { var values:[String:Int]=[:];func record(_ name:String){values[name,default:0]+=1} }

@Test func lateImportCompletionCannotCancelRecoveryAndPendingVerificationKeepsItsJob() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=try ConnectorStore(root:root.appendingPathComponent("state"))
    let source=root.appendingPathComponent("source/Default"),target=root.appendingPathComponent("target/Default")
    for path in [source,target] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
    let a=try store.pair(code:store.beginPairing(browser:.chrome,profile:source),browser:.chrome,profileID:UUID().uuidString,label:"Source")
    let b=try store.pair(code:store.beginPairing(browser:.chrome,profile:target),browser:.chrome,profileID:UUID().uuidString,label:"Target")
    let resources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Importer")
    let coordinator=TransferCoordinator(store:store,lifecycle:FixtureLifecycle(),importerResources:resources,receiptRoot:root.appendingPathComponent("receipts"),timeout:0.1,pollInterval:0.01,backupCheck:{_ in []})
    let held=HeldOperations()
    let worker=Task {
        while !Task.isCancelled {
            for c in [a,b] {
                guard let job=try store.poll(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID) else {continue}
                if job.operation != "capture" {
                    await held.record(job)
                    if job.operation=="verify",await held.allowVerify { try store.complete(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID,jobID:job.id,result:Data("{\"ok\":true,\"mismatches\":[],\"observed\":{}}".utf8)) }
                    continue
                }
                let result:[String:Any]=["ok":true,"capture":["schema":1,"format":"browser-bridge-capture","browser":"chrome","capturedAt":"2026-10-23T00:00:00Z","snapshot":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Snapshot()))]]
                try store.complete(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID,jobID:job.id,result:JSONSerialization.data(withJSONObject:result))
            }
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    defer {worker.cancel()}
    do {_=try await coordinator.transfer(source:a,destination:b,package:root.appendingPathComponent("package"),options:TransferOptions(),validationRoot:root);Issue.record("Expected import timeout")} catch {}
    let paused=try #require(await coordinator.currentReceipt),importJob=try #require(await held.jobs["import"])
    #expect(paused.interruptedPhase == .importing)
    try store.complete(connectionID:b.id,secret:b.secret,browser:b.browser,profileID:b.profileID,jobID:importJob.id,result:Data("{\"ok\":true,\"journal\":{\"state\":\"complete\",\"remainingTabs\":0,\"errors\":[]}}".utf8))
    do {_=try await coordinator.cancelUnclaimed(receiptURL:URL(fileURLWithPath:paused.receiptPath));Issue.record("Late-completed import must not become cancelled")} catch {}
    #expect(try await coordinator.readReceipt(URL(fileURLWithPath:paused.receiptPath)).phase == .paused)
    do {_=try await coordinator.resume(receiptURL:URL(fileURLWithPath:paused.receiptPath),validationRoot:root);Issue.record("Expected verification timeout")} catch {}
    let verifying=try #require(await coordinator.currentReceipt),verifyJob=try #require(await held.jobs["verify"])
    #expect(verifying.interruptedPhase == .verifying)
    do {_=try await coordinator.resume(receiptURL:URL(fileURLWithPath:paused.receiptPath),validationRoot:root);Issue.record("Expected still-pending verification timeout")} catch {}
    let retry=try #require(await coordinator.currentReceipt)
    #expect(retry.jobID == verifyJob.id)
    #expect(await held.ids["verify"]?.count == 1)
    try store.complete(connectionID:b.id,secret:b.secret,browser:b.browser,profileID:b.profileID,jobID:verifyJob.id,result:Data("{\"ok\":true,\"mismatches\":[\"stale observation\"]}".utf8))
    let competing=try store.enqueue(connectionID:b.id,operation:"import",payload:Data("{}".utf8))
    do {_=try await coordinator.resume(receiptURL:URL(fileURLWithPath:paused.receiptPath),validationRoot:root);Issue.record("Expected queue conflict")} catch {}
    #expect(try await coordinator.readReceipt(URL(fileURLWithPath:paused.receiptPath)).jobID == verifyJob.id)
    try store.complete(connectionID:b.id,secret:b.secret,browser:b.browser,profileID:b.profileID,jobID:competing.id,result:Data("{\"ok\":true}".utf8))
    await held.enableVerification()
    let finished=try await coordinator.resume(receiptURL:URL(fileURLWithPath:paused.receiptPath),validationRoot:root)
    #expect(finished.phase == .complete)
    #expect(await held.ids["verify"]?.count == 2)
}
private actor HeldOperations {
    var allowVerify=false
    func enableVerification(){allowVerify=true}
    var jobs:[String:ConnectorJob]=[:]
    var ids:[String:Set<String>]=[:]
    func record(_ job:ConnectorJob){jobs[job.operation]=job;ids[job.operation,default:[]].insert(job.id)}
}

@Test func cancellingUndeliveredVerificationPreservesRollbackOfPriorImport() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=try ConnectorStore(root:root.appendingPathComponent("state"))
    let source=root.appendingPathComponent("source/Default"),target=root.appendingPathComponent("target/Default")
    for path in [source,target] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
    let a=try store.pair(code:store.beginPairing(browser:.chrome,profile:source),browser:.chrome,profileID:UUID().uuidString,label:"Source")
    let b=try store.pair(code:store.beginPairing(browser:.chrome,profile:target),browser:.chrome,profileID:UUID().uuidString,label:"Target")
    let resources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Importer")
    let coordinator=TransferCoordinator(store:store,lifecycle:FixtureLifecycle(),importerResources:resources,receiptRoot:root.appendingPathComponent("receipts"),timeout:0.1,pollInterval:0.01,backupCheck:{_ in []})
    let hold=TargetPollControl()
    let worker=Task {
        while !Task.isCancelled {
            for c in [a,b] {
                if c.id==b.id,await hold.stopped {continue}
                guard let job=try store.poll(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID) else {continue}
                let result:[String:Any]
                if job.operation=="capture" {result=["ok":true,"capture":["schema":1,"format":"browser-bridge-capture","browser":"chrome","capturedAt":"2026-10-23T00:00:00Z","snapshot":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Snapshot()))]]}
                else if job.operation=="import" {await hold.stop();result=["ok":true,"journal":["state":"complete","remainingTabs":0,"errors":[]]]}
                else {result=["ok":true,"journal":["state":"rolled-back","tabs":[],"history":[],"errors":[]]]}
                try store.complete(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID,jobID:job.id,result:JSONSerialization.data(withJSONObject:result))
            }
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    defer {worker.cancel()}
    do {_=try await coordinator.transfer(source:a,destination:b,package:root.appendingPathComponent("package"),options:TransferOptions(),validationRoot:root);Issue.record("Expected undelivered verify timeout")} catch {}
    let paused=try #require(await coordinator.currentReceipt)
    #expect(paused.interruptedPhase == .verifying)
    let cancelledStep=try await coordinator.cancelUnclaimed(receiptURL:URL(fileURLWithPath:paused.receiptPath))
    #expect(cancelledStep.phase == .paused)
    #expect(cancelledStep.interruptedPhase == .verifying)
    await hold.allow()
    let result=try await coordinator.rollback(receiptURL:URL(fileURLWithPath:paused.receiptPath),confirmedOwnedBookmarkEditsRemoval:true,validationRoot:root)
    #expect(result.phase == .rolledBack)
}
private actor TargetPollControl {var stopped=false;func stop(){stopped=true};func allow(){stopped=false}}

@Test func transferPausesBeforeApplyIfDestinationSessionDoesNotSurviveReopen() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=try ConnectorStore(root:root.appendingPathComponent("state"))
    let source=root.appendingPathComponent("source/Default"),target=root.appendingPathComponent("target/Default")
    for path in [source,target] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)}
    let a=try store.pair(code:store.beginPairing(browser:.chrome,profile:source),browser:.chrome,profileID:UUID().uuidString,label:"Source")
    let b=try store.pair(code:store.beginPairing(browser:.chrome,profile:target),browser:.chrome,profileID:UUID().uuidString,label:"Target")
    let resources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Importer")
    let coordinator=TransferCoordinator(store:store,lifecycle:FixtureLifecycle(),importerResources:resources,receiptRoot:root.appendingPathComponent("receipts"),timeout:1,pollInterval:0.01,backupCheck:{_ in []})
    let fixture=DestinationBaselineFixture()
    let worker=Task {
        while !Task.isCancelled {
            for c in [a,b] {
                guard let job=try store.poll(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID) else {continue}
                let result:[String:Any]
                if job.operation=="capture" {
                    var snapshot=Snapshot()
                    if c.id==b.id,await fixture.captureContainsBaseline() {snapshot.tabs=[BrowserTab(id:"existing",url:"https://existing.example/",title:"Existing",pinned:false,essential:false,spaceID:nil,folderID:nil,order:0,originalURL:nil,container:0)]}
                    result=["ok":true,"capture":["schema":1,"format":"browser-bridge-capture","browser":"chrome","capturedAt":"2026-10-23T00:00:00Z","snapshot":try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot))]]
                } else if job.operation=="import" {await fixture.applied();result=["ok":true,"journal":["state":"complete","remainingTabs":0,"errors":[]]]}
                else {result=["ok":true,"mismatches":[],"observed":[:]]}
                try store.complete(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID,jobID:job.id,result:JSONSerialization.data(withJSONObject:result))
            }
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    defer{worker.cancel()}
    do {_=try await coordinator.transfer(source:a,destination:b,package:root.appendingPathComponent("package"),options:TransferOptions(),validationRoot:root)} catch {}
    let receipt=try #require(await coordinator.currentReceipt)
    #expect(receipt.phase == .paused)
    #expect(await fixture.imports == 0)
    await fixture.restore()
    let completed=try await coordinator.resume(receiptURL:URL(fileURLWithPath:receipt.receiptPath),validationRoot:root)
    #expect(completed.phase == .complete)
    #expect(await fixture.imports == 1)
}
private actor DestinationBaselineFixture {
    var captures=0,imports=0,restored=false
    func captureContainsBaseline()->Bool{captures+=1;return captures==1 || restored}
    func applied(){imports+=1}
    func restore(){restored=true}
}

@Test func automaticReadinessIsLimitedToTheAcceptedArchitectureAndExactChromeToBraveRoute() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=try ConnectorStore(root:root.appendingPathComponent("state"))
    let source=try store.pair(code:store.beginPairing(browser:.chrome,profile:root.appendingPathComponent("Chrome/Default")),browser:.chrome,profileID:UUID().uuidString,label:"Source",browserExecutable:"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",browserVersion:"156.0.8078.48")
    let destination=try store.pair(code:store.beginPairing(browser:.brave,profile:root.appendingPathComponent("Brave/Default")),browser:.brave,profileID:UUID().uuidString,label:"Destination",browserExecutable:"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",browserVersion:"156.1.98.60")
    #if arch(arm64)
    #expect(AutomaticRoutes.allows(source,destination))
    #else
    #expect(!AutomaticRoutes.allows(source,destination))
    #endif
    var changedSource=source;changedSource.browserVersion="156.0.8078.49"
    #expect(!AutomaticRoutes.allows(changedSource,destination))
    changedSource=source;changedSource.browserExecutable="/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
    #expect(!AutomaticRoutes.allows(changedSource,destination))
    var changedDestination=destination;changedDestination.browserVersion="156.1.98.61"
    #expect(!AutomaticRoutes.allows(source,changedDestination))
    changedDestination=destination;changedDestination.profilePath=source.profilePath
    #expect(!AutomaticRoutes.allows(source,changedDestination))
    #expect(!AutomaticRoutes.allows(destination,source))
    #expect(!AutomaticRoutes.allows(source,source))
}
