import SwiftUI
import BridgeCore
import AppKit
import Combine
import UniformTypeIdentifiers

private struct CredentialVault: Decodable, Identifiable, Sendable {
    let vaultId: String
    let count: Int
    let createdAt: Double
    var id: String { vaultId }
}
private struct CredentialStage: Decodable, Identifiable, Sendable {
    let stageId: String
    let vaultId: String
    let expiresAt: Double
    var id: String { stageId }
}
private struct CredentialResult: Decodable, Sendable {
    let vaultId: String?
    let stageId: String?
    let temporaryPath: String?
    let notice: String?
    let outcome: String?
    let cleaned: Bool?
    let vaults: [CredentialVault]?
    let stages: [CredentialStage]?
}
private struct CredentialEnvelope: Decodable {
    let ok: Bool
    let result: CredentialResult?
    let error: Failure?
    struct Failure: Decodable { let message: String }
}
private struct CredentialUIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private enum CredentialTransport {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrowserBridgeCredentials", isDirectory: true)
    }
    static func send(_ data: Data) async throws -> CredentialResult {
        guard let executable = Bundle.main.executableURL else { throw CredentialUIError(message: "Open the packaged Browser Bridge app to use its credential helper.") }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("bridge-credentials")
        let location = root
        let response = try await Task.detached(priority: .userInitiated) {
            try exchange(data, helper: helper, root: location)
        }.value
        let envelope: CredentialEnvelope
        do { envelope = try JSONDecoder().decode(CredentialEnvelope.self, from: response) }
        catch { throw CredentialUIError(message: "The credential helper returned an unreadable result. Update the packaged app and retry.") }
        guard envelope.ok, let result = envelope.result else {
            throw CredentialUIError(message: envelope.error?.message ?? "The credential step could not finish. Your original export is unchanged.")
        }
        return result
    }
    private static func exchange(_ request: Data, helper: URL, root: URL) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CredentialUIError(message: "The bundled credential helper is missing. Use the current packaged Mac app; your browser data has not changed.")
        }
        guard request.count <= 64 * 1024 else { throw CredentialUIError(message: "The credential request is too large.") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper
        process.arguments = ["--root", root.path]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw CredentialUIError(message: "The local credential helper could not start. Reopen the packaged app and retry.") }
        do { try input.fileHandleForWriting.write(contentsOf: request); try input.fileHandleForWriting.close() }
        catch { process.terminate(); throw CredentialUIError(message: "The credential request could not be delivered. Retry this step.") }
        var response = Data()
        while let part = try output.fileHandleForReading.read(upToCount: 16 * 1024), !part.isEmpty {
            response.append(part)
            guard response.count <= 1024 * 1024 else { process.terminate(); throw CredentialUIError(message: "The credential helper result exceeded the supported size.") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CredentialUIError(message: "The credential helper stopped before completing its step. Review temporary files on reopening.") }
        return response
    }
}

@MainActor @Observable private final class CredentialModel {
    static let shared = CredentialModel()
    var sourceCSV: URL?
    var passphrase = ""
    var protectConsent = false
    var stageConsent = false
    var selectedVault = ""
    var vaults: [CredentialVault] = []
    var stages: [CredentialStage] = []
    var temporaryPath: String?
    var currentStage: String?
    var busy = false
    var terminating = false
    var message: String?
    var failure: String?

    func chooseCSV() {
        let panel = NSOpenPanel()
        panel.title = "Choose the source browser's password CSV"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceCSV = url; protectConsent = false
    }
    func protect() {
        guard let sourceCSV, protectConsent else { return }
        perform(["command":"protect", "path":sourceCSV.path, "passphrase":passphrase, "consent":true])
        passphrase = ""; protectConsent = false
    }
    func stage() {
        guard !selectedVault.isEmpty, stageConsent else { return }
        perform(["command":"stage", "vaultId":selectedVault, "passphrase":passphrase, "consent":true])
        passphrase = ""; stageConsent = false
    }
    func reload() { perform(["command":"list"], showNotice: false) }
    func cleanup(_ id: String) { perform(["command":"cleanup", "stageId":id]) }
    func confirm(_ id: String) { perform(["command":"confirmImport", "stageId":id, "confirmed":true]) }
    private func applyList(_ result: CredentialResult) {
        vaults = result.vaults ?? []; stages = result.stages ?? []
        if !vaults.contains(where: { $0.id == selectedVault }) { selectedVault = vaults.first?.id ?? "" }
        if let currentStage, !stages.contains(where: { $0.id == currentStage }) { self.currentStage = nil; temporaryPath = nil }
    }
    private func perform(_ request: [String: Any], showNotice: Bool = true) {
        guard !busy, !terminating else { return }
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: request) }
        catch { failure = "The credential request could not be prepared."; return }
        let isList = request["command"] as? String == "list"
        busy = true; failure = nil
        Task {
            defer { busy = false }
            do {
                let result = try await CredentialTransport.send(data)
                if let path = result.temporaryPath { temporaryPath = path; currentStage = result.stageId }
                if let vault = result.vaultId { selectedVault = vault }
                if showNotice { message = result.notice ?? (result.outcome == "user-confirmed" ? "Import recorded as user-confirmed. Temporary CSV removed; browser import was not independently verified." : "Temporary CSV removed. Your vault and original export are unchanged.") }
                if isList { applyList(result) }
                else { applyList(try await CredentialTransport.send(Data(#"{"command":"list"}"#.utf8))) }
            } catch { failure = error.localizedDescription }
        }
    }
    func cleanupBeforeClosing() async throws {
        while terminating { try await Task.sleep(for: .milliseconds(100)) }
        terminating = true; passphrase = ""
        defer { terminating = false }
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        guard FileManager.default.fileExists(atPath: CredentialTransport.root.path) else { return }
        let result = try await CredentialTransport.send(Data(#"{"command":"list"}"#.utf8))
        for stage in result.stages ?? [] {
            let request = try JSONSerialization.data(withJSONObject: ["command":"cleanup", "stageId":stage.id])
            _ = try await CredentialTransport.send(request)
        }
        stages = []; currentStage = nil; temporaryPath = nil
    }
}

struct CredentialView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var model = CredentialModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Passwords & Vaults", systemImage: "key.horizontal.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working on credentials") }
                Button("Done") { Task { do { try await model.cleanupBeforeClosing(); dismiss() } catch { model.failure = error.localizedDescription } } }
                    .keyboardShortcut(.cancelAction).disabled(model.busy || model.terminating)
            }
            Text("Protect a browser export locally, then use the destination browser’s own importer. Complete its authentication prompts. Passkeys and signed-in sessions require separate provider/browser support.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Protect the source export", systemImage: "lock.shield")
                            .font(.headline)
                        Text("Export passwords from your source browser, then choose its CSV. The original export stays untouched.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Choose Password CSV…") { model.chooseCSV() }
                            Text(model.sourceCSV?.lastPathComponent ?? "No file selected")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        SecureField("Vault passphrase (12+ bytes; keep it safe)", text: $model.passphrase)
                            .textFieldStyle(.roundedBorder)
                        Text("Your passphrase is not saved. A forgotten passphrase cannot be recovered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("I allow this CSV to be read and stored in an encrypted local vault.", isOn: $model.protectConsent)
                        Button("Protect Export") { model.protect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.sourceCSV == nil || model.passphrase.utf8.count < 12 || !model.protectConsent)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nativeGroupSurface()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Import through your destination browser", systemImage: "tray.and.arrow.down")
                            .font(.headline)
                        if model.vaults.isEmpty {
                            Text("No saved vaults yet. Protect a source CSV above to begin.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Saved vault", selection: $model.selectedVault) {
                                ForEach(model.vaults) { vault in
                                    Text("\(vault.vaultId.prefix(8)) · \(vault.count) passwords · \(Date(timeIntervalSince1970: vault.createdAt).formatted(date: .abbreviated, time: .omitted))").tag(vault.id)
                                }
                            }
                            SecureField("Vault passphrase to unlock", text: $model.passphrase)
                                .textFieldStyle(.roundedBorder)
                            Toggle("I allow a temporary plaintext CSV for this browser-managed import.", isOn: $model.stageConsent)
                            Button("Prepare Temporary Import File") { model.stage() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.passphrase.utf8.count < 12 || !model.stageConsent)
                        }
                        if let path = model.temporaryPath, let stage = model.currentStage {
                            Divider()
                            Text("Use your destination browser’s password importer to choose this file:").font(.headline)
                            Text(path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                Button("Browser Reported Import Complete") { model.confirm(stage) }
                                    .buttonStyle(.borderedProminent)
                                Button("Remove Temporary CSV") { model.cleanup(stage) }
                            }
                            Text("Completion is recorded as user-confirmed, not independently verified.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nativeGroupSurface()

                    if !model.stages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Temporary files", systemImage: "clock.badge.exclamationmark")
                                .font(.headline)
                            Text("Eligible for cleanup after 15 minutes. Cleanup runs every 30 seconds while the app is running, when you close it normally, and on the next launch/action. A crash or powered-off Mac can leave plaintext until then. Deletion is not guaranteed secure erasure on SSDs or backups.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(model.stages) { stage in
                                HStack {
                                    Text("Import \(stage.stageId.prefix(8)) · cleanup after \(Date(timeIntervalSince1970: stage.expiresAt).formatted(date: .omitted, time: .shortened))").font(.callout)
                                    Spacer()
                                    Button("Remove CSV") { model.cleanup(stage.id) }
                                        .controlSize(.small)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .nativeGroupSurface()
                    }
                    if let message = model.message { Label(message, systemImage: "info.circle").foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if let failure = model.failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Credential step error: \(failure)") }
                }.disabled(model.busy || model.terminating)
            }
        }
        .padding(24)
        .frame(width: 720, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled()
        .task { model.reload() }
        .onDisappear { model.passphrase = ""; model.protectConsent = false; model.stageConsent = false }
    }
}

@MainActor final class CredentialExitDelegate: NSObject, NSApplicationDelegate {
    private var expiryTimer: Timer?
    private lazy var expiry = CredentialExpiryLifecycle(demo: CommandLine.arguments.contains("--demo")) {
        guard FileManager.default.fileExists(atPath: CredentialTransport.root.path) else { return }
        CredentialModel.shared.reload()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        expiry.start()
        expiryTimer = Timer(timeInterval: CredentialExpiryLifecycle.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expiry.tick() }
        }
        if let expiryTimer { RunLoop.main.add(expiryTimer, forMode: .common) }
    }
    func applicationWillTerminate(_ notification: Notification) { expiryTimer?.invalidate() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !CommandLine.arguments.contains("--demo") else { return .terminateNow }
        Task {
            do { try await CredentialModel.shared.cleanupBeforeClosing(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                let alert = NSAlert()
                alert.messageText = "Temporary credential cleanup could not finish"
                alert.informativeText = "Temporary plaintext files may remain until Browser Bridge can clean them on a later launch. \(error.localizedDescription)"
                alert.addButton(withTitle: "Cancel quit"); alert.addButton(withTitle: "Quit anyway")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        return .terminateLater
    }
}
