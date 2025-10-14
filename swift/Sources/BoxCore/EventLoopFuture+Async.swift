import NIOCore

/// Async/await helper bridging an `EventLoopFuture` into Swift concurrency.
public extension EventLoopFuture {
    /// Suspends the current task until the future completes.
    /// - Returns: The future value once available.
    /// - Throws: Any error produced by the future.
    func get() async throws -> Value {
        let boxed: UncheckedSendableBox<Value> = try await withCheckedThrowingContinuation { continuation in
            self.whenComplete { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: UncheckedSendableBox(value))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        return boxed.value
    }
}
