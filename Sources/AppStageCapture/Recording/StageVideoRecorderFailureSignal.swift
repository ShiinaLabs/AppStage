import Foundation

/// Delivers the first fatal recording error to a single active workflow waiter.
actor StageVideoRecorderFailureSignal {
    private var failure: StageVideoRecorderError?
    private var continuation: CheckedContinuation<Never, any Error>?
    private var waiterCancelled = false

    func fail(_ error: StageVideoRecorderError) {
        guard failure == nil else { return }
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func wait() async throws -> Never {
        if let failure { throw failure }
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let failure {
                    continuation.resume(throwing: failure)
                } else if waiterCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if self.continuation == nil {
                    self.continuation = continuation
                } else {
                    continuation.resume(throwing: StageVideoRecorderError.writingFailed(
                        "A recorder failure waiter is already active."
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    private func cancelWaiter() {
        waiterCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
