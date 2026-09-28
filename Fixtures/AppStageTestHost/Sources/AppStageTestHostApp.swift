import AppKit
import AppStage
import AppStageControl
import AppStageMac
import Observation
import SwiftUI

@main
struct AppStageTestHostApp: App {
    @State private var runtime: FixtureRuntime

    init() {
        let launch = try! StageLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        let runtime = FixtureRuntime(launch: launch)
        _runtime = State(initialValue: runtime)
        Task { await runtime.connectIfControlled() }
    }

    var body: some Scene {
        WindowGroup {
            FixtureContentView(runtime: runtime)
                .frame(minWidth: 680, minHeight: 480)
                .onAppear { runtime.configureWindow() }
        }
    }
}

@MainActor
@Observable
private final class FixtureRuntime: StageScenarioControlling {
    static let scenarioID = StageScenarioID("reliability-smoke")

    let launch: StageLaunchConfiguration
    let cursor = StageCursorModel()
    let conditions = StageConditionRegistry()
    let targets = StageTargetRegistry()
    let actions = StageActionRegistry()
    var isUIReady = false
    var controlStatus = "Not connected"
    var isSheetPresented = false
    var menuActionCompleted = false
    var selectedMode = "basic"
    var animationCompleted = false
    var animationProgress = 0.0

    private let eventStream: AsyncStream<StageControlEvent>
    private let eventContinuation: AsyncStream<StageControlEvent>.Continuation
    private var client: StageControlClient?
    private var accessibilityBridge: StageRemoteInteractionBridge?
    private var runner: StageScenarioRunner?
    private var loaded = false
    private var playTask: Task<Void, Never>?

    init(launch: StageLaunchConfiguration) {
        self.launch = launch
        var continuation: AsyncStream<StageControlEvent>.Continuation!
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
        registerConditions()
        registerTargets()
        let cursorModel = cursor
        let accessibilityBridge = StageRemoteInteractionBridge(client: makeClient(), targets: targets)
        self.accessibilityBridge = accessibilityBridge
        runner = StageScenarioRunner(
            script: Self.smokeScript,
            actions: actions,
            conditions: conditions,
            targets: targets,
            cursor: cursor,
            accessibility: accessibilityBridge,
            accessibilityFrameToPoint: { [weak cursorModel] frame in cursorModel?.overlayPoint(for: frame) }
        )
    }

    private static let smokeScript = StageScenarioScript(
        id: scenarioID,
        displayName: "Reliability Smoke",
        duration: .seconds(6),
        steps: [
            .waitUntil(StageConditionID("fixture.ui-ready"), timeout: .seconds(10)),
            .waitUntil(StageConditionID("fixture.start.available"), timeout: .seconds(10)),
            .accessibilityPress(
                target: StageTargetID("fixture.start"),
                condition: StageConditionID("fixture.sheet.available"),
                conditionTimeout: .seconds(10)
            ),
            .accessibilityPress(
                target: StageTargetID("fixture.sheet.continue"),
                condition: StageConditionID("fixture.sheet.dismissed"),
                conditionTimeout: .seconds(10)
            ),
            .accessibilityPress(target: StageTargetID("fixture.menu")),
            .accessibilityPress(
                target: StageTargetID("fixture.menu.item"),
                condition: StageConditionID("fixture.menu.completed"),
                conditionTimeout: .seconds(10)
            ),
            .accessibilityPress(
                target: StageTargetID("fixture.segment.advanced"),
                condition: StageConditionID("fixture.animation.completed"),
                conditionTimeout: .seconds(10)
            ),
            .finish,
        ]
    )

    private func registerConditions() {
        try! conditions.register(StageConditionID("fixture.ui-ready")) { [weak self] in self?.isUIReady == true }
        try! conditions.register(StageConditionID("fixture.start.available")) { [weak self] in self?.isUIReady == true }
        try! conditions.register(StageConditionID("fixture.start.ax-available")) { [weak self] in
            guard let self, let accessibilityBridge = self.accessibilityBridge else { return false }
            do {
                _ = try await accessibilityBridge.resolve(StageTargetID("fixture.start"))
                return true
            } catch {
                return false
            }
        }
        try! conditions.register(StageConditionID("fixture.sheet.available")) { [weak self] in self?.isSheetPresented == true }
        try! conditions.register(StageConditionID("fixture.sheet.dismissed")) { [weak self] in self?.isSheetPresented == false }
        try! conditions.register(StageConditionID("fixture.menu.completed")) { [weak self] in self?.menuActionCompleted == true }
        try! conditions.register(StageConditionID("fixture.animation.completed")) { [weak self] in self?.animationCompleted == true }
    }

    private func registerTargets() {
        try! targets.register(StageTargetID("fixture.start"), locator: .init(identifier: "fixture.start"))
        try! targets.register(StageTargetID("fixture.sheet.continue"), locator: .init(identifier: "fixture.sheet.continue"))
        try! targets.register(StageTargetID("fixture.menu"), locator: .init(identifier: "fixture.menu"))
        try! targets.register(StageTargetID("fixture.menu.item"), locator: .init(identifier: "fixture.menu.item"))
        try! targets.register(StageTargetID("fixture.segment.advanced"), locator: .init(identifier: "fixture.segment.advanced"))
    }

    private func makeClient() -> StageControlClient {
        if let client { return client }
        let client = StageControlClient(host: self)
        self.client = client
        return client
    }

    func configureWindow() {
        guard let size = launch.windowSize else { return }
        let configuration = StageWindowConfiguration(size: size)
        if let window = NSApp.windows.first(where: \.isKeyWindow) ?? NSApp.windows.first {
            configuration.apply(to: window)
        }
    }

    func connectIfControlled() async {
        guard let port = launch.controlPort,
              let token = launch.controlToken,
              let sessionID = launch.controlSession,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        do {
            try await makeClient().connect(
                port: port, token: token, sessionID: sessionID,
                bundleIdentifier: bundleID, pid: getpid()
            )
            controlStatus = "Connected"
        } catch {
            controlStatus = "Failed: \(error.localizedDescription)"
            NSLog("Fixture Host Control connect failed: %@", error.localizedDescription)
        }
    }

    func markUIReady() { isUIReady = true }

    func loadScenario(_ id: StageScenarioID) async throws {
        guard id == Self.scenarioID else { throw StageControlError.remoteFailure("Unknown fixture Scenario: \(id.rawValue)") }
        loaded = true
        isSheetPresented = false
        menuActionCompleted = false
        selectedMode = "basic"
        animationProgress = 0
        animationCompleted = false
    }

    func prepareScenario() async throws {
        guard loaded else { throw StageControlError.invalidState("Fixture Scenario was not loaded") }
        try await conditions.waitUntil(StageConditionID("fixture.ui-ready"), timeout: .seconds(10))
        try await conditions.waitUntil(StageConditionID("fixture.start.available"), timeout: .seconds(10))
        try await conditions.waitUntil(StageConditionID("fixture.start.ax-available"), timeout: .seconds(10))
    }

    func playScenario() async throws {
        guard loaded, let runner else { throw StageControlError.invalidState("Fixture Scenario is not ready") }
        let task = runner.start()
        playTask = Task { [weak self] in
            do {
                try await task.value
                self?.eventContinuation.yield(.init(kind: .finished, scenarioID: Self.scenarioID))
            } catch {
                self?.eventContinuation.yield(.init(kind: .failed, scenarioID: Self.scenarioID, error: error.localizedDescription))
            }
        }
    }

    func pauseScenario() async throws { runner?.cancel() }

    func resetScenario() async throws {
        runner?.cancel()
        playTask?.cancel()
        isSheetPresented = false
        menuActionCompleted = false
        selectedMode = "basic"
        animationProgress = 0
        animationCompleted = false
    }

    func performAction(_ action: StageAction) async throws {
        throw StageControlError.unsupported("Fixture Host has no semantic actions")
    }

    func availableScenarios() async -> [StageScenarioMetadata] {
        [StageScenarioMetadata(id: Self.scenarioID, displayName: "Reliability Smoke", durationMilliseconds: 6_000)]
    }

    func events() async -> AsyncStream<StageControlEvent> { eventStream }

    func controlDisconnected() async {
        runner?.cancel()
        playTask?.cancel()
        eventContinuation.finish()
    }
}

@MainActor
private struct FixtureContentView: View {
    @Bindable var runtime: FixtureRuntime

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Text("AppStage Reliability Fixture")
                    .font(.largeTitle)
                Button("Open fixture sheet") { runtime.isSheetPresented = true }
                    .accessibilityIdentifier("fixture.start")
                Menu("Fixture menu") {
                    Button("Run deterministic action") { runtime.menuActionCompleted = true }
                        .accessibilityIdentifier("fixture.menu.item")
                }
                .accessibilityIdentifier("fixture.menu")
                Picker("Fixture mode", selection: $runtime.selectedMode) {
                    Text("Basic").tag("basic")
                    Text("Advanced").tag("advanced")
                        .accessibilityIdentifier("fixture.segment.advanced")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("fixture.segmented")
                RoundedRectangle(cornerRadius: 12)
                    .fill(.blue.opacity(0.7))
                    .frame(width: 100 + runtime.animationProgress * 120, height: 60)
                    .accessibilityLabel("Deterministic animated shape")
                Text(runtime.animationCompleted ? "Animation complete" : "Animation waiting")
                    .accessibilityIdentifier("fixture.animation.status")
                Text("Control: \(runtime.controlStatus)")
                    .accessibilityIdentifier("fixture.control.status")
            }
            .padding(40)
            .sheet(isPresented: $runtime.isSheetPresented) {
                VStack(spacing: 20) {
                    Text("Fixture sheet")
                    Button("Continue") { runtime.isSheetPresented = false }
                        .accessibilityIdentifier("fixture.sheet.continue")
                }
                .padding(40)
                .frame(width: 360, height: 220)
            }
            .onChange(of: runtime.selectedMode) { _, newValue in
                guard newValue == "advanced" else { return }
                runtime.animationCompleted = false
                withAnimation(.linear(duration: 0.35), completionCriteria: .logicallyComplete) {
                    runtime.animationProgress = 1
                } completion: {
                    runtime.animationCompleted = true
                }
            }
            .onAppear { runtime.markUIReady() }
        }
        .stageCursorLayer(runtime.cursor)
    }
}
