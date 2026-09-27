import AppStage
import Foundation

/// Host-side adapter from semantic scenario targets to the controller's AX service.
@MainActor
public final class StageRemoteInteractionBridge: StageAccessibilityInteractionDriving {
    private let client: StageControlClient
    private let targets: StageTargetRegistry

    public init(client: StageControlClient, targets: StageTargetRegistry) {
        self.client = client
        self.targets = targets
    }

    public func resolve(_ target: StageTargetID) async throws -> StageAccessibilityFrame {
        let locator = try targets.accessibilityLocator(for: target)
        switch try await client.accessibility(.resolve(locator)) {
        case let .resolved(frame): return frame
        case let .failure(message): throw StageControlError.remoteFailure("Resolve \(target.rawValue): \(message)")
        default: throw StageControlError.invalidState("Controller returned an invalid accessibility resolve response")
        }
    }

    public func press(_ target: StageTargetID) async throws {
        let locator = try targets.accessibilityLocator(for: target)
        switch try await client.accessibility(.press(locator)) {
        case .pressed: return
        case let .failure(message): throw StageControlError.remoteFailure("Press \(target.rawValue): \(message)")
        default: throw StageControlError.invalidState("Controller returned an invalid accessibility press response")
        }
    }

    public func elementExists(_ target: StageTargetID) async throws -> Bool {
        let locator = try targets.accessibilityLocator(for: target)
        switch try await client.accessibility(.exists(locator)) {
        case let .exists(value): return value
        case let .failure(message): throw StageControlError.remoteFailure("Check \(target.rawValue): \(message)")
        default: throw StageControlError.invalidState("Controller returned an invalid accessibility condition response")
        }
    }
}
