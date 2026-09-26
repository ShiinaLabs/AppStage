/// A semantic action scheduled at a scenario position.
public struct StageCue: Sendable {
    public let at: Duration
    public let action: StageAction

    public init(at: Duration, action: StageAction) {
        self.at = at
        self.action = action
    }
}
