import Foundation
import Testing
@testable import BridgeCore

@Test func pairedProfileReceivesOnlyItsOwnDurableJobs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ConnectorStore(root: root)
    let code = try store.beginPairing(browser: .chrome, profile: root.appendingPathComponent("Profile A"))
    let profile = UUID().uuidString
    let connection = try store.pair(code: code, browser: .chrome, profileID: profile, label: "Personal")
    #expect(throws: (any Error).self) { try store.pair(code: code, browser: .chrome, profileID: UUID().uuidString, label: "Other") }
    let job = try store.enqueue(connectionID: connection.id, operation: "capture", payload: Data("{}".utf8))
    let reopened = try ConnectorStore(root: root)
    #expect(throws: (any Error).self) { try reopened.poll(connectionID: connection.id, secret: "wrong", browser: .chrome, profileID: profile) }
    let received = try reopened.poll(connectionID: connection.id, secret: connection.secret, browser: .chrome, profileID: profile)
    #expect(received?.id == job.id)
    try reopened.complete(connectionID: connection.id, secret: connection.secret, browser: .chrome, profileID: profile, jobID: job.id, result: Data("{\"ok\":true}".utf8))
    #expect(try reopened.result(jobID: job.id) == Data("{\"ok\":true}".utf8))
    #expect(try reopened.poll(connectionID: connection.id, secret: connection.secret, browser: .chrome, profileID: profile) == nil)
}

@Test func connectionCannotBeReusedByAnotherBrowserOrExtensionProfile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ConnectorStore(root: root)
    let code = try store.beginPairing(browser: .firefox, profile: root.appendingPathComponent("Firefox"))
    let profile = UUID().uuidString
    #expect(throws: (any Error).self) { try store.pair(code: code, browser: .chrome, profileID: profile, label: "Forged") }
    let connection = try store.pair(code: code, browser: .firefox, profileID: profile, label: "Personal")
    #expect(throws: (any Error).self) { try store.poll(connectionID: connection.id, secret: connection.secret, browser: .chrome, profileID: profile) }
    #expect(throws: (any Error).self) { try store.poll(connectionID: connection.id, secret: connection.secret, browser: .firefox, profileID: UUID().uuidString) }
    #expect(throws: (any Error).self) { try store.enqueue(connectionID: connection.id, operation: "import", payload: Data(repeating: 0, count: 700_000)) }
    try store.disconnect(connection.id)
    #expect(throws: (any Error).self) { try store.poll(connectionID: connection.id, secret: connection.secret, browser: .firefox, profileID: profile) }
}

@Test func cancellingUndeliveredWorkReleasesProfileButCannotCancelDeliveredEffects() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=try ConnectorStore(root:root)
    let c=try store.pair(code:store.beginPairing(browser:.chrome,profile:root.appendingPathComponent("Default")),browser:.chrome,profileID:UUID().uuidString,label:"Disposable")
    let first=try store.enqueue(connectionID:c.id,operation:"capture",payload:Data("{}".utf8))
    try store.cancelQueuedJob(first.id)
    #expect(try store.result(jobID:first.id) != nil)
    let next=try store.enqueue(connectionID:c.id,operation:"capture",payload:Data("{}".utf8))
    #expect(try store.poll(connectionID:c.id,secret:c.secret,browser:c.browser,profileID:c.profileID)?.id == next.id)
    #expect(throws:(any Error).self) { try store.cancelQueuedJob(next.id) }
}
