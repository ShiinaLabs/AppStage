import AppStage
import AppStageCapture
import AppStageControl
import Foundation

@MainActor
protocol StageRecordControlling: Sendable {
    func start() async throws -> UInt16
    func bindExpectedPID(_ pid: Int32) async
    func waitForHandshake(timeout: Duration) async throws
    func request(_ command: StageControlCommand, timeout: Duration) async throws -> StageControlSnapshot
    func waitForEvent(_ kind: StageControlEventKind, timeout: Duration) async throws
    func close() async
}

@MainActor
protocol StageRecordSessioning {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String { get }
    func finish() async
}

@MainActor
protocol StageRecordRecording: Sendable {
    func start() async throws
    func stop() async throws
    func waitForFailure() async throws -> Never
    func discardOutputIfOwned() async
}

extension StageAppSession: StageRecordSessioning {}

@MainActor
final class StageRecordWorkflow {
    private let controller: any StageRecordControlling
    private let openSession: @MainActor ([String], StageExistingApplicationPolicy) async throws -> any StageRecordSessioning
    private let makeRecorder: @MainActor (pid_t, String, URL) async throws -> any StageRecordRecording
    private var session: (any StageRecordSessioning)?

    init(
        controller: any StageRecordControlling,
        openSession: @escaping @MainActor ([String], StageExistingApplicationPolicy) async throws -> any StageRecordSessioning,
        makeRecorder: @escaping @MainActor (pid_t, String, URL) async throws -> any StageRecordRecording
    ) {
        self.controller = controller
        self.openSession = openSession
        self.makeRecorder = makeRecorder
    }

    func startSession(
        bundleIdentifier: String,
        initialScenarioID: StageScenarioID? = nil,
        token: String,
        sessionID: UUID,
        timeout: Duration,
        existingApplicationPolicy: StageExistingApplicationPolicy
    ) async throws -> any StageRecordSessioning {
        let port = try await controller.start()
        try Task.checkCancellation()
        var arguments = [
            "--appstage-window", "1100x760",
            "--appstage-control-host", "127.0.0.1",
            "--appstage-control-port", String(port),
            "--appstage-control-token", token,
            "--appstage-control-session", sessionID.uuidString,
        ]
        if let initialScenarioID {
            arguments.insert(contentsOf: ["--appstage-scenario", initialScenarioID.rawValue], at: 0)
        } else {
            arguments.insert("--appstage-discover-scenarios", at: 0)
        }
        let opened = try await openSession(arguments, existingApplicationPolicy)
        session = opened
        await controller.bindExpectedPID(opened.processIdentifier)
        try await controller.waitForHandshake(timeout: timeout)
        return opened
    }

    func recordScenario(
        _ scenarioID: StageScenarioID,
        bundleIdentifier: String,
        timeout: Duration,
        outputURL: URL
    ) async throws {
        guard let session else { throw StageControlError.disconnected }
        var recorder: (any StageRecordRecording)?
        var recording = false
        var outputOwnedByWorkflow = false
        do {
            _ = try await controller.request(.loadScenario(scenarioID), timeout: timeout)
            _ = try await controller.request(.prepare, timeout: timeout)
            try await controller.waitForEvent(.ready, timeout: timeout)
            try Task.checkCancellation()
            let capture = try await makeRecorder(session.processIdentifier, bundleIdentifier, outputURL)
            recorder = capture
            try await capture.start()
            recording = true
            outputOwnedByWorkflow = true
            try Task.checkCancellation()
            _ = try await controller.request(.play, timeout: timeout)
            try await waitForFinishOrRecorderFailure(capture, timeout: timeout)
            recording = false
            try await capture.stop()
            try Task.checkCancellation()
            outputOwnedByWorkflow = false
        } catch {
            if recording { try? await recorder?.stop() }
            if outputOwnedByWorkflow { await recorder?.discardOutputIfOwned() }
            throw error
        }
    }

    func discoverScenarios(timeout: Duration) async throws -> [StageScenarioMetadata] {
        let snapshot = try await controller.request(.listScenarios, timeout: timeout)
        guard let scenarios = snapshot.scenarios, !scenarios.isEmpty else {
            throw StageBatchRecordError.noScenarios
        }
        return scenarios
    }

    func close() async {
        await controller.close()
        await session?.finish()
        session = nil
    }

    func run(
        scenarioID: StageScenarioID,
        bundleIdentifier: String,
        token: String,
        sessionID: UUID,
        timeout: Duration,
        existingApplicationPolicy: StageExistingApplicationPolicy,
        outputURL: URL
    ) async throws {
        do {
            _ = try await startSession(
                bundleIdentifier: bundleIdentifier,
                initialScenarioID: scenarioID,
                token: token,
                sessionID: sessionID,
                timeout: timeout,
                existingApplicationPolicy: existingApplicationPolicy
            )
            try await recordScenario(scenarioID, bundleIdentifier: bundleIdentifier, timeout: timeout, outputURL: outputURL)
            await close()
        } catch {
            await close()
            throw error
        }
    }

    private func waitForFinishOrRecorderFailure(
        _ recorder: any StageRecordRecording,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.controller.waitForEvent(.finished, timeout: timeout) }
            group.addTask { try await recorder.waitForFailure() }
            defer { group.cancelAll() }
            guard try await group.next() != nil else { throw CancellationError() }
        }
    }
}

@MainActor
struct StageSystemRecordController: StageRecordControlling {
    let underlying: StageControlController
    func start() async throws -> UInt16 { try await underlying.start() }
    func bindExpectedPID(_ pid: Int32) async { await underlying.bindExpectedPID(pid) }
    func waitForHandshake(timeout: Duration) async throws { try await underlying.waitForHandshake(timeout: timeout) }
    func request(_ command: StageControlCommand, timeout: Duration) async throws -> StageControlSnapshot {
        try await underlying.request(command, timeout: timeout)
    }
    func waitForEvent(_ kind: StageControlEventKind, timeout: Duration) async throws {
        _ = try await underlying.waitForEvent(kind, timeout: timeout)
    }
    func close() async { await underlying.close() }
}

@MainActor
struct StageSystemRecordRecorder: StageRecordRecording {
    let underlying: StageVideoRecorder
    func start() async throws { try await underlying.start() }
    func stop() async throws { try await underlying.stop() }
    func waitForFailure() async throws -> Never { try await underlying.waitForFailure() }
    func discardOutputIfOwned() async { await underlying.discardOutputIfOwned() }
}
