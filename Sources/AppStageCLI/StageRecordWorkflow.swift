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
    var isTerminated: Bool { get }
    var terminationStatus: Int32 { get }
    func finish() async
}

extension StageRecordSessioning {
    var isTerminated: Bool { false }
    var terminationStatus: Int32 { 0 }
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
    enum Phase: String, Codable {
        case controlListen, launch, controlConnect, loadScenario, prepareScenario
        case recordingStart, playScenario, scenarioRuntime, recordingFinalize
        case processTermination, cleanup, controlDisconnect, movieValidation, recordingCleanup, finishEventMissing
    }

    typealias EventHandler = @MainActor (Phase, String, Int32?, Int64?) -> Void
    private let controller: any StageRecordControlling
    private let openSession: @MainActor ([String], StageExistingApplicationPolicy) async throws -> any StageRecordSessioning
    private let makeRecorder: @MainActor (pid_t, String, URL) async throws -> any StageRecordRecording
    private var session: (any StageRecordSessioning)?
    private let eventHandler: EventHandler

    init(
        controller: any StageRecordControlling,
        openSession: @escaping @MainActor ([String], StageExistingApplicationPolicy) async throws -> any StageRecordSessioning,
        makeRecorder: @escaping @MainActor (pid_t, String, URL) async throws -> any StageRecordRecording,
        eventHandler: @escaping EventHandler = { _, _, _, _ in }
    ) {
        self.controller = controller
        self.openSession = openSession
        self.makeRecorder = makeRecorder
        self.eventHandler = eventHandler
    }

    func startSession(
        bundleIdentifier: String,
        initialScenarioID: StageScenarioID? = nil,
        token: String,
        sessionID: UUID,
        timeout: Duration,
        existingApplicationPolicy: StageExistingApplicationPolicy
    ) async throws -> any StageRecordSessioning {
        let port: UInt16
        do { port = try await controller.start() }
        catch {
            eventHandler(.controlListen, "failure: \(error.localizedDescription)", nil, nil)
            throw error
        }
        eventHandler(.controlListen, "control server ready", nil, nil)
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
        let opened: any StageRecordSessioning
        do { opened = try await openSession(arguments, existingApplicationPolicy) }
        catch {
            eventHandler(.launch, "failure: \(error.localizedDescription)", nil, nil)
            throw error
        }
        session = opened
        eventHandler(.launch, "child launched", Int32(opened.processIdentifier), nil)
        await controller.bindExpectedPID(opened.processIdentifier)
        try await timed(.controlConnect, name: "child control handshake accepted") {
            try await controller.waitForHandshake(timeout: timeout)
        }
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
            _ = try await timed(.loadScenario, name: "scenario loaded") {
                try await controller.request(.loadScenario(scenarioID), timeout: timeout)
            }
            _ = try await timed(.prepareScenario, name: "scenario prepared") {
                let snapshot = try await controller.request(.prepare, timeout: timeout)
                try await controller.waitForEvent(.ready, timeout: timeout)
                return snapshot
            }
            try Task.checkCancellation()
            let capture = try await timed(.recordingStart, name: "recording started") {
                let capture = try await makeRecorder(session.processIdentifier, bundleIdentifier, outputURL)
                try await capture.start()
                return capture
            }
            recorder = capture
            recording = true
            outputOwnedByWorkflow = true
            try Task.checkCancellation()
            _ = try await timed(.playScenario, name: "scenario playing") {
                try await controller.request(.play, timeout: timeout)
            }
            try await timed(.scenarioRuntime, name: "scenario finished") {
                try await waitForFinishOrRecorderFailure(capture, timeout: timeout)
            }
            recording = false
            try await timed(.recordingFinalize, name: "recording finalized") { try await capture.stop() }
            try Task.checkCancellation()
            outputOwnedByWorkflow = false
        } catch {
            var recorderCleanupPassed = true
            if recording {
                do { try await recorder?.stop() }
                catch { recorderCleanupPassed = false }
            }
            if outputOwnedByWorkflow { await recorder?.discardOutputIfOwned() }
            eventHandler(
                .recordingCleanup,
                recorderCleanupPassed ? "recorder cleanup completed" : "failure: recorder cleanup failed",
                nil,
                nil
            )
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

    func runDiscovery(
        bundleIdentifier: String,
        token: String,
        sessionID: UUID,
        timeout: Duration,
        existingApplicationPolicy: StageExistingApplicationPolicy
    ) async throws -> [StageScenarioMetadata] {
        do {
            _ = try await startSession(
                bundleIdentifier: bundleIdentifier,
                initialScenarioID: nil,
                token: token,
                sessionID: sessionID,
                timeout: timeout,
                existingApplicationPolicy: existingApplicationPolicy
            )
            let scenarios = try await discoverScenarios(timeout: timeout)
            await close()
            return scenarios
        } catch {
            await close()
            throw error
        }
    }

    func close() async {
        await controller.close()
        eventHandler(.controlDisconnect, "control connection closed", nil, nil)
        await session?.finish()
        if let session {
            eventHandler(.processTermination, session.isTerminated ? "child exited" : "child remains alive", session.terminationStatus, nil)
        }
        eventHandler(.cleanup, "cleanup completed", nil, nil)
        session = nil
    }

    private func timed<T>(_ phase: Phase, name: String, operation: () async throws -> T) async throws -> T {
        let start = ContinuousClock.now
        do {
            let value = try await operation()
            let duration = start.duration(to: .now).components
            let milliseconds = Int64(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
            eventHandler(phase, name, nil, milliseconds)
            return value
        } catch {
            let failedPhase: Phase
            if phase == .scenarioRuntime,
               let controlError = error as? StageControlError,
               case .timedOut = controlError {
                failedPhase = .finishEventMissing
            } else {
                failedPhase = phase
            }
            eventHandler(failedPhase, "failure: \(error.localizedDescription)", nil, nil)
            throw error
        }
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
