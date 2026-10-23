import Testing
@testable import BridgeCore
@Test @MainActor func startupAndClosedSheetTicksRunCleanupButDemoNeverDoes() {
    var cleanups = 0
    let lifecycle = CredentialExpiryLifecycle(demo: false) { cleanups += 1 }
    lifecycle.start()
    #expect(cleanups == 1, "Startup sweeps even when the credential sheet has never opened")
    lifecycle.tick()
    #expect(cleanups == 2, "The app lifecycle continues cleanup while the sheet is closed")
    let demo = CredentialExpiryLifecycle(demo: true) { cleanups += 1 }
    demo.start(); demo.tick()
    #expect(cleanups == 2, "Demo must never invoke the real credential boundary")
}
