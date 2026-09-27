import Foundation

/// A bounded, low-frequency barrier for the first complete frame accepted by AVAssetWriter.
actor StageVideoFrameReadiness {
    private var frameAccepted = false
    private(set) var waiterCount = 0

    func signalFrameAccepted() {
        frameAccepted = true
    }

    func wait(timeout: Duration) async throws {
        waiterCount += 1
        defer { waiterCount -= 1 }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !frameAccepted {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw StageVideoRecorderError.firstFrameTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
