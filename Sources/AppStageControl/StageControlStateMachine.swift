import AppStage

public struct StageControlStateMachine: Sendable {
    public private(set) var state: StageControlState = .disconnected
    public private(set) var scenarioID: StageScenarioID?

    public init() {}

    public mutating func connected() {
        state = .connected
    }

    public mutating func begin(_ command: StageControlCommand) throws {
        let allowed: Bool
        switch command {
        case .loadScenario:
            allowed = state == .connected || state == .finished
        case .prepare:
            allowed = state == .scenarioLoaded
        case .play:
            allowed = state == .ready || state == .paused
        case .pause:
            allowed = state == .playing
        case .reset:
            allowed = [.scenarioLoaded, .ready, .playing, .paused, .finished].contains(state)
        case .performAction:
            allowed = [.ready, .playing, .paused].contains(state)
        case .queryState:
            allowed = state != .disconnected && state != .failed
        case .seek:
            throw StageControlError.unsupported("seek reconstruction")
        }
        guard allowed else {
            throw StageControlError.invalidState("Cannot perform \(command) while control state is \(state.rawValue)")
        }
        if case .loadScenario = command, state == .finished { state = .connected }
        if case .reset = command { state = .scenarioLoaded }
        if case .prepare = command { state = .preparing }
    }

    public mutating func succeeded(_ command: StageControlCommand) {
        guard state != .finished && state != .failed else { return }
        switch command {
        case let .loadScenario(id):
            scenarioID = id
            state = .scenarioLoaded
        case .reset:
            state = .scenarioLoaded
        default:
            break
        }
    }

    public mutating func received(_ event: StageControlEvent) {
        guard state != .finished && state != .failed else { return }
        switch event.kind {
        case .ready: state = .ready
        case .playing: state = .playing
        case .paused: state = .paused
        case .finished: state = .finished
        case .failed: state = .failed
        }
    }

    public mutating func disconnected() {
        if state != .disconnected && state != .finished { state = .failed }
    }

    public mutating func failed() { state = .failed }
}
