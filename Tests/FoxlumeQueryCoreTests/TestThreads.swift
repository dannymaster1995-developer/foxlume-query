import Foundation

/// Background work for tests that must run on time: cancels fired at a statement, fake servers that answer a client.
///
/// `DispatchQueue.global()` and Swift's cooperative pool only have about as many threads as the machine has cores.
/// In a parallel run on a small CI machine other tests keep them busy for many seconds, so a cancel scheduled there
/// can arrive after the statement it should stop has finished, and a fake server can answer after the client gave
/// up. A thread of its own does not wait for either pool.
enum TestThreads {
    /// Runs `body` on a new thread after `seconds`.
    static func after(_ seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) {
        start {
            Thread.sleep(forTimeInterval: seconds)
            body()
        }
    }

    /// Runs `body` on a new thread.
    static func start(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "Foxlume test helper"
        thread.start()
    }
}
