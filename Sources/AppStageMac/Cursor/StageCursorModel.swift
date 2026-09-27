import AppStage
import Observation
import SwiftUI

@MainActor
@Observable
public final class StageCursorModel: StageCursorDriving {
    public private(set) var position = StagePoint(x: 0, y: 0)
    public private(set) var isVisible = false
    public private(set) var isClicking = false
    private var targetPoints: [StageTargetID: StagePoint] = [:]

    public init() {}

    public func targetPoint(for id: StageTargetID) -> StagePoint? { targetPoints[id] }

    public func setTargetPoints(_ points: [StageTargetID: StagePoint]) {
        targetPoints = points
    }

    func updateTargets(_ points: [StageTargetID: StagePoint]) {
        targetPoints = points
    }

    public func move(to point: StagePoint, duration: Duration) async throws {
        isVisible = true
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
            let eased = fraction * (2 - fraction)
            position = StagePoint(
                x: origin.x + (point.x - origin.x) * eased,
                y: origin.y + (point.y - origin.y) * eased
            )
            try await Task.sleep(for: .milliseconds(16))
        }
        position = point
    }

    public func click() async throws {
        isVisible = true
        isClicking = true
        defer { isClicking = false }
        try await Task.sleep(for: .milliseconds(280))
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

    var body: some View {
        if model.isVisible {
            ZStack {
                if model.isClicking {
                    Circle()
                        .fill(.blue.opacity(0.2))
                        .frame(width: 30, height: 30)
                        .scaleEffect(model.isClicking ? 1 : 0.5)
                }
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
                    .offset(x: 2, y: 3)
            }
            .position(x: model.position.x, y: model.position.y)
            .animation(.easeOut(duration: 0.12), value: model.isClicking)
        }
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
