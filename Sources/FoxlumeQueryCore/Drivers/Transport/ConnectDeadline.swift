import Foundation

/// Aborts a connection handshake that does not finish in time.
///
/// A peer that accepts TCP but never speaks the expected protocol (a wrong port) would otherwise block
/// the first read forever. When the deadline passes, the watched transport is interrupted, which makes
/// the pending read throw.
public final class ConnectDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private weak var transport: SocketTransport?
    private var fired = false
    private var finished = false
    private var item: DispatchWorkItem?

    public init(timeout: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        self.item = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(1, timeout), execute: item)
    }

    /// Watch the transport currently in use. A handshake may replace it, for example after a plaintext retry.
    public func watch(_ transport: SocketTransport) {
        lock.lock()
        defer { lock.unlock() }
        self.transport = transport
        if fired { transport.interrupt() }
    }

    /// Stop the timer. Returns true when the deadline already passed and the connection must be discarded.
    @discardableResult
    public func finish() -> Bool {
        lock.lock()
        finished = true
        let didFire = fired
        lock.unlock()
        item?.cancel()
        return didFire
    }

    private func fire() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        fired = true
        transport?.interrupt()
    }
}
