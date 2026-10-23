import Foundation
import BridgeCore

// Local administration and reproducible disposable-profile validation. Never called through native messages.
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { throw ConnectorError.rejected("Usage: bridge-connect STATE_ROOT list | pair BROWSER PROFILE | enqueue CONNECTION OPERATION JSON_FILE | result JOB | install BROWSER HOST_EXECUTABLE CONNECTOR_RESOURCES HOME") }
    let store = try ConnectorStore(root: URL(fileURLWithPath: args[0]))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch args[1] {
    case "list": print(String(decoding: try encoder.encode(store.connections()), as: UTF8.self))
    case "pair":
        guard args.count == 4, let browser = BrowserID(rawValue: args[2]) else { throw ConnectorError.rejected("pair requires BROWSER PROFILE") }
        print(try store.beginPairing(browser: browser, profile: URL(fileURLWithPath: args[3])))
    case "enqueue":
        guard args.count == 5 else { throw ConnectorError.rejected("enqueue requires CONNECTION OPERATION JSON_FILE") }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[4])); _ = try JSONSerialization.jsonObject(with: data)
        print(try store.enqueue(connectionID: args[2], operation: args[3], payload: data).id)
    case "result":
        guard args.count == 3 else { throw ConnectorError.rejected("result requires JOB") }
        if let data = try store.result(jobID: args[2]) { print(String(decoding: data, as: UTF8.self)) } else { print("null") }
    case "receipts":
        let coordinator=TransferCoordinator(store:store,lifecycle:MacBrowserLifecycle(),importerResources:URL(fileURLWithPath:"."),receiptRoot:URL(fileURLWithPath:args[0]).deletingLastPathComponent().appendingPathComponent("Transfers"))
        print(String(decoding:try encoder.encode(await coordinator.receipts()),as:UTF8.self))
    case "receipt", "resume-validate", "rollback-validate":
        guard args.count >= 3 else { throw ConnectorError.rejected("Recovery requires RECEIPT [DISPOSABLE_ROOT]") }
        let coordinator=TransferCoordinator(store:store,lifecycle:MacBrowserLifecycle(),importerResources:URL(fileURLWithPath:"Resources/Importer"),receiptRoot:URL(fileURLWithPath:args[0]).deletingLastPathComponent().appendingPathComponent("Transfers"))
        let url=URL(fileURLWithPath:args[2]),receipt:TransferReceipt
        if args[1]=="receipt" { receipt=try await coordinator.readReceipt(url) }
        else {
            guard args.count==4 else { throw ConnectorError.rejected("Validation recovery requires an explicit disposable profile root.") }
            let root=URL(fileURLWithPath:args[3])
            if args[1]=="resume-validate" { receipt=try await coordinator.resume(receiptURL:url,validationRoot:root) }
            else { receipt=try await coordinator.rollback(receiptURL:url,confirmedOwnedBookmarkEditsRemoval:true,validationRoot:root) }
        }
        print(String(decoding:try encoder.encode(receipt),as:UTF8.self))
    case "transfer-validate":
        guard [7,8].contains(args.count) else { throw ConnectorError.rejected("transfer-validate requires SOURCE_CONNECTION DEST_CONNECTION PACKAGE IMPORTER_RESOURCES DISPOSABLE_ROOT [OPTIONS_JSON_FILE]") }
        let connections=try store.connections()
        guard let source=connections.first(where:{$0.id==args[2]}),let destination=connections.first(where:{$0.id==args[3]}) else { throw ConnectorError.rejected("Connect both disposable profiles first.") }
        let coordinator=TransferCoordinator(store:store,lifecycle:MacBrowserLifecycle(),importerResources:URL(fileURLWithPath:args[5]),receiptRoot:URL(fileURLWithPath:args[0]).deletingLastPathComponent().appendingPathComponent("Transfers"))
        let options = args.count == 8 ? try JSONDecoder().decode(TransferOptions.self,from:Data(contentsOf:URL(fileURLWithPath:args[7]))) : TransferOptions()
        let receipt=try await coordinator.transfer(source:source,destination:destination,package:URL(fileURLWithPath:args[4]),options:options,validationRoot:URL(fileURLWithPath:args[6]))
        print(String(decoding:try encoder.encode(receipt),as:UTF8.self))
    case "install":
        guard args.count == 6, let browser = BrowserID(rawValue: args[2]) else { throw ConnectorError.rejected("install requires BROWSER HOST_EXECUTABLE CONNECTOR_RESOURCES HOME") }
        print(try ConnectorInstallation.install(browser: browser, executable: URL(fileURLWithPath: args[3]), resources: URL(fileURLWithPath: args[4]), home: URL(fileURLWithPath: args[5])).path)
    default: throw ConnectorError.rejected("Unknown local command.")
    }
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
