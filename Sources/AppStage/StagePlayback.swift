import Clocks

/// Tracks scenario position against an injectable monotonic clock.
public actor StagePlayback {
    private let clock: AnyClock<Duration>
    private var storedPosition: Duration = .zero
    private var anchorInstant: AnyClock<Duration>.Instant
    private var currentRate: Double = 1

    public private(set) var state: StagePlaybackState = .stopped
    /// Increments on every reset so timeline consumers can re-arm after a reset.
    public private(set) var resetGeneration: UInt64 = 0

    public var position: Duration {
        guard state == .playing else { return storedPosition }
        return position(
            from: storedPosition,
            elapsed: anchorInstant.duration(to: clock.now),
            rate: currentRate
        )
    }

    public var playbackRate: Double {
        currentRate
    }

    public init<C: Clock>(clock: C = ContinuousClock()) where C.Duration == Duration {
        let erasedClock = AnyClock(clock)
        self.clock = erasedClock
        self.anchorInstant = erasedClock.now
    }

    public func play() {
        guard state != .playing else { return }
        anchorInstant = clock.now
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        storedPosition = position
        anchorInstant = clock.now
        state = .paused
    }

    public func reset() {
        resetGeneration &+= 1
        storedPosition = .zero
        anchorInstant = clock.now
        state = .stopped
    }

    /// Changes the timeline position without changing the current playback state.
    public func seek(to position: Duration) {
        storedPosition = position
        anchorInstant = clock.now
    }

    /// Changes the playback rate while preserving the current position.
    public func setPlaybackRate(_ rate: Double) {
        precondition(rate.isFinite && rate > 0, "Playback rate must be finite and greater than zero")
        if state == .playing {
            storedPosition = position
            anchorInstant = clock.now
        }
        currentRate = rate
    }

    /// Sleeps on the same injectable clock that advances playback.
    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }

    private func position(from base: Duration, elapsed: Duration, rate: Double) -> Duration {
        guard elapsed != .zero else { return base }
        return adding(base, scaled(elapsed, by: rate))
    }

    private func scaled(_ duration: Duration, by rate: Double) -> Duration {
        if rate == 1 {
            return duration
        }

        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let scaledSeconds = seconds * rate

        // Duration's public seconds component is Int64. Clamp before converting so
        // large but valid rates cannot trap during conversion.
        if scaledSeconds >= Double(Int64.max) {
            return .seconds(Int64.max)
        }
        if scaledSeconds <= Double(Int64.min) {
            return .seconds(Int64.min)
        }

        let wholeSeconds = Int64(scaledSeconds.rounded(.towardZero))
        let fractionalAttoseconds = Int64((scaledSeconds - Double(wholeSeconds)) * 1e18)
        return Duration(secondsComponent: wholeSeconds, attosecondsComponent: fractionalAttoseconds)
    }

    private func adding(_ lhs: Duration, _ rhs: Duration) -> Duration {
        let lhsComponents = lhs.components
        let rhsComponents = rhs.components
        let attoseconds = lhsComponents.attoseconds + rhsComponents.attoseconds
        let carry = attoseconds / 1_000_000_000_000_000_000
        let fractionalAttoseconds = attoseconds % 1_000_000_000_000_000_000

        let (seconds, secondsOverflow) = lhsComponents.seconds.addingReportingOverflow(rhsComponents.seconds)
        guard !secondsOverflow else {
            return rhsComponents.seconds >= 0 ? .seconds(Int64.max) : .seconds(Int64.min)
        }

        let (normalizedSeconds, carryOverflow) = seconds.addingReportingOverflow(carry)
        guard !carryOverflow else {
            return carry >= 0 ? .seconds(Int64.max) : .seconds(Int64.min)
        }

        if normalizedSeconds == Int64.max, fractionalAttoseconds > 0 {
            return .seconds(Int64.max)
        }
        if normalizedSeconds == Int64.min, fractionalAttoseconds < 0 {
            return .seconds(Int64.min)
        }

        return Duration(secondsComponent: normalizedSeconds, attosecondsComponent: fractionalAttoseconds)
    }
}
