/// A value that becomes active at a point in a scenario timeline.
public struct StageStep<Value>: Sendable where Value: Sendable {
    public let at: Duration
    public let value: Value

    public init(at: Duration, value: Value) {
        self.at = at
        self.value = value
    }
}
