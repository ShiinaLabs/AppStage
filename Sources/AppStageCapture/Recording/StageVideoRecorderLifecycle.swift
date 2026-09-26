import Foundation
import ScreenCaptureKit

enum StageVideoRecorderLifecycleState: Equatable {
    case idle
    case starting
    case running
    case stopping
    case stopped
}

struct StageVideoRecorderLifecycle {
    private(set) var state: StageVideoRecorderLifecycleState = .idle

    mutating func beginStart() throws {
        guard state == .idle else {
            throw StageVideoRecorderError.alreadyStarted
        }
        state = .starting
    }

    mutating func completeStart() {
        state = .running
    }

    mutating func failStart() {
        state = .idle
    }

    mutating func beginStop() throws {
        guard state == .running else {
            if state == .starting || state == .stopping {
                throw StageVideoRecorderError.transitionInProgress
            }
            throw StageVideoRecorderError.notStarted
        }
        state = .stopping
    }

    mutating func completeStop() {
        state = .stopped
    }
}

enum StageVideoFrameStatus {
    static func isComplete(_ rawValue: Int?) -> Bool {
        guard let rawValue,
              let status = SCFrameStatus(rawValue: rawValue)
        else {
            return false
        }
        return status == .complete
    }
}
