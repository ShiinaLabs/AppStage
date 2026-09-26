/// A deterministic, hold-style sequence of values over time.
public struct StageSequence<Value>: Sendable where Value: Sendable {
    /// Steps in ascending time order. Equal-time steps retain declaration order.
    public let steps: [StageStep<Value>]

    public init(_ steps: [StageStep<Value>]) {
        self.steps = steps
            .enumerated()
            .sorted {
                if $0.element.at == $1.element.at {
                    return $0.offset < $1.offset
                }
                return $0.element.at < $1.element.at
            }
            .map(\.element)
    }

    /// Returns the latest declared step at or before `time`, or `nil` before the first step.
    public func value(at time: Duration) -> Value? {
        steps.last(where: { $0.at <= time })?.value
    }
}
