import Foundation

/// App-owned expiry boundary, independent of whether a credential sheet is mounted.
@MainActor public final class CredentialExpiryLifecycle {
    public static let interval: TimeInterval = 30
    private let demo: Bool
    private let cleanup: @MainActor () -> Void
    private var started = false
    public init(demo: Bool, cleanup: @escaping @MainActor () -> Void) {
        self.demo = demo; self.cleanup = cleanup
    }
    public func start() {
        guard !started else { return }
        started = true
        tick()
    }
    public func tick() {
        guard !demo else { return }
        cleanup()
    }
}
