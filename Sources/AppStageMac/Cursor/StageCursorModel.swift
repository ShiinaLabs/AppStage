import AppStage
import Observation
import SwiftUI

@MainActor
@Observable
public final class StageCursorModel: StageCursorInteractionDriving {
    public private(set) var position = StagePoint(x: 0, y: 0)
    public private(set) var isVisible = false
    public var isClicking: Bool { isMouseDown }
    public private(set) var opacity = 0.0
    public private(set) var isMouseDown = false
    public private(set) var clickFeedbackID = 0
    public private(set) var isScrolling = false
    public private(set) var scrollDirection: StageScrollDirection = .down
    public private(set) var scrollDistance = 0.0
    public private(set) var scrollProgress = 0.0
    public private(set) var typedText = ""
    private(set) var opacityTransitionDuration: Duration = .milliseconds(180)

    private var targetPoints: [StageTargetID: StagePoint] = [:]
    private var isPositionInitialized = false

    public init() {}

    public func targetPoint(for id: StageTargetID) -> StagePoint? { targetPoints[id] }

    public func setTargetPoints(_ points: [StageTargetID: StagePoint]) {
        targetPoints = points
    }

    public func place(at point: StagePoint) async throws {
        position = point
        isPositionInitialized = true
    }

    public func show(duration: Duration) async throws {
        opacityTransitionDuration = duration
        isVisible = true
        if duration <= .zero {
            opacity = 1
            return
        }
        opacity = 0
        try await Task.sleep(for: .milliseconds(16))
        try Task.checkCancellation()
        opacity = 1
        try await Task.sleep(for: duration)
    }

    public func hide(duration: Duration) async throws {
        opacityTransitionDuration = duration
        guard isVisible else { return }
        if duration <= .zero {
            opacity = 0
        } else {
            opacity = 0
            try await Task.sleep(for: duration)
        }
        try Task.checkCancellation()
        isVisible = false
        typedText = ""
        isScrolling = false
        scrollDistance = 0
        scrollProgress = 0
    }

    public func move(to point: StagePoint, duration: Duration) async throws {
        if !isPositionInitialized {
            position = point
            isPositionInitialized = true
            isVisible = true
            opacity = 1
            return
        }
        if !isVisible {
            isVisible = true
            opacity = 1
        }
        let origin = position
        guard duration > .zero else {
            position = point
            return
        }

        let clock = ContinuousClock()
        let start = clock.now
        let end = start.advanced(by: duration)
        while clock.now < end {
            try Task.checkCancellation()
            let elapsed = start.duration(to: clock.now)
            let fraction = min(1, max(0, seconds(elapsed) / seconds(duration)))
            let eased = fraction * fraction * (3 - 2 * fraction)
            position = StagePoint(
                x: origin.x + (point.x - origin.x) * eased,
                y: origin.y + (point.y - origin.y) * eased
            )
            try await Task.sleep(for: .milliseconds(16))
        }
        try Task.checkCancellation()
        position = point
    }

    public func hover(for duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }

    public func mouseDown() async throws {
        isMouseDown = true
    }

    public func mouseUp() async throws {
        guard isMouseDown else { return }
        isMouseDown = false
        clickFeedbackID &+= 1
    }

    public func click() async throws {
        try await mouseDown()
        do {
            try await Task.sleep(for: .milliseconds(85))
            try Task.checkCancellation()
            try await mouseUp()
        } catch {
            isMouseDown = false
            throw error
        }
    }

    public func doubleClick(interval: Duration) async throws {
        try await click()
        if interval > .zero { try await Task.sleep(for: interval) }
        try Task.checkCancellation()
        try await click()
    }

    public func scroll(
        direction: StageScrollDirection,
        amount: StageScrollAmount,
        duration: Duration
    ) async throws {
        scrollDirection = direction
        scrollDistance = amount.distance
        guard duration > .zero else {
            isScrolling = false
            scrollProgress = 0
            return
        }
        isScrolling = true
        defer {
            isScrolling = false
            scrollDistance = 0
            scrollProgress = 0
        }
        let clock = ContinuousClock()
        let start = clock.now
        let end = start.advanced(by: duration)
        while clock.now < end {
            try Task.checkCancellation()
            let fraction = min(1, max(0, seconds(start.duration(to: clock.now)) / seconds(duration)))
            scrollProgress = fraction
            try await Task.sleep(for: .milliseconds(16))
        }
        try Task.checkCancellation()
        scrollProgress = 1
    }

    public func typeText(_ text: String, characterInterval: Duration) async throws {
        typedText = ""
        for (index, character) in text.enumerated() {
            try Task.checkCancellation()
            typedText.append(character)
            if index < text.count - 1, characterInterval > .zero {
                try await Task.sleep(for: characterInterval)
            }
        }
    }

    public func reset() {
        position = StagePoint(x: 0, y: 0)
        isVisible = false
        opacity = 0
        isMouseDown = false
        isScrolling = false
        scrollDistance = 0
        scrollProgress = 0
        typedText = ""
        isPositionInitialized = false
    }

    func updateTargets(_ points: [StageTargetID: StagePoint]) {
        targetPoints = points
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private enum StageCursorCoordinateSpace {
    static let name = "appstage.cursor"
}

private struct StageCursorTargetPreference: PreferenceKey {
    static let defaultValue: [StageTargetID: StagePoint] = [:]

    static func reduce(value: inout [StageTargetID: StagePoint], nextValue: () -> [StageTargetID: StagePoint]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct StageCursorTargetModifier: ViewModifier {
    let id: StageTargetID

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(StageCursorCoordinateSpace.name))
                Color.clear.preference(
                    key: StageCursorTargetPreference.self,
                    value: [id: StagePoint(x: frame.midX, y: frame.midY)]
                )
            }
        }
    }
}

private struct StageCursorLayerModifier: ViewModifier {
    let model: StageCursorModel

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: StageCursorCoordinateSpace.name)
            .overlay(alignment: .topLeading) {
                StageCursorOverlay(model: model)
                    .allowsHitTesting(false)
            }
            .onPreferenceChange(StageCursorTargetPreference.self) { model.updateTargets($0) }
    }
}

private struct StageCursorOverlay: View {
    @Bindable var model: StageCursorModel
    @State private var clickRippleVisible = false
    @State private var clickRippleProgress = 0.0
    @State private var clickRippleTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                if clickRippleVisible {
                    Circle()
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                        .frame(width: 22, height: 22)
                        .scaleEffect(0.55 + clickRippleProgress * 0.95)
                        .opacity(0.38 * (1 - clickRippleProgress))
                }
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.78), radius: 2, x: 1, y: 1)
                    .scaleEffect(model.isMouseDown ? 0.93 : 1)
                if model.isScrolling {
                    let travel = CGFloat(min(abs(model.scrollDistance), 24) * model.scrollProgress)
                    let verticalTravel = model.scrollDirection == .down ? travel : -travel
                    Image(systemName: model.scrollDirection == .up ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .offset(x: 17, y: 20 + verticalTravel)
                }
                if !model.typedText.isEmpty {
                    Text(model.typedText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .offset(x: 25, y: -20)
                }
            }
            .frame(width: 48, height: 48)
            .scaleEffect(model.isMouseDown ? 0.98 : 1)
            .offset(x: model.position.x - 24, y: model.position.y - 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(model.opacity)
        .animation(.easeInOut(duration: seconds(model.opacityTransitionDuration)), value: model.opacity)
        .animation(.easeOut(duration: 0.08), value: model.isMouseDown)
        .onChange(of: model.clickFeedbackID) { _, _ in
            clickRippleTask?.cancel()
            clickRippleVisible = true
            clickRippleProgress = 0
            withAnimation(.easeOut(duration: 0.24)) {
                clickRippleProgress = 1
            }
            clickRippleTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled else { return }
                clickRippleVisible = false
            }
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

public extension View {
    /// Publishes this view's current center as a semantic cursor target.
    func stageCursorTarget(_ id: StageTargetID) -> some View {
        modifier(StageCursorTargetModifier(id: id))
    }

    /// Displays the AppStage demo cursor over this view and resolves descendant targets.
    func stageCursorLayer(_ model: StageCursorModel) -> some View {
        modifier(StageCursorLayerModifier(model: model))
    }
}
