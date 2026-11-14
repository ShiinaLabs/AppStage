import AppStage
import AppStageControl
import Foundation

public enum StageHostLaunchMode {
    case discoverScenarios
    case scenario(StageScenarioID)
    case captureCase(StageCaseID)
}

@MainActor
public final class StageControlledHostSession {
    public let processIdentifier: Int32
    public let bundleIdentifier: String

    private let controller: StageControlController
    private let application: StageAppSession
    private var isClosed = false

    private init(controller: StageControlController, application: StageAppSession) {
        self.controller = controller
        self.application = application
        self.processIdentifier = application.processIdentifier
        self.bundleIdentifier = application.bundleIdentifier
    }

    public static func open(
        appURL: URL,
        bundleIdentifier: String,
        mode: StageHostLaunchMode,
        timeout: Duration = .seconds(30),
        keepAppRunning: Bool = false,
        existingApplicationPolicy: StageExistingApplicationPolicy = .reject
    ) async throws -> StageControlledHostSession {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(
            token: token,
            sessionID: sessionID,
            bundleIdentifier: bundleIdentifier,
            accessibilityHandler: { operation, pid in
                StageAccessibilityController.handle(operation, pid: pid)
            }
        )
        var application: StageAppSession?
        do {
            let port = try await controller.start()
            var arguments = [
                "--appstage-control-host", "127.0.0.1",
                "--appstage-control-port", String(port),
                "--appstage-control-token", token,
                "--appstage-control-session", sessionID.uuidString,
            ]
            switch mode {
            case .discoverScenarios:
                arguments.insert("--appstage-discover-scenarios", at: 0)
            case let .scenario(scenarioID):
                arguments.insert(contentsOf: [
                    "--appstage-scenario", scenarioID.rawValue,
                    "--appstage-window", "1100x760",
                ], at: 0)
            case let .captureCase(caseID):
                arguments.insert(contentsOf: ["--appstage-case", caseID.rawValue], at: 0)
            }
            let opened = try await StageAppSession.open(
                appURL: appURL,
                bundleIdentifier: bundleIdentifier,
                arguments: arguments,
                keepAppRunning: keepAppRunning,
                existingApplicationPolicy: existingApplicationPolicy
            )
            application = opened
            await controller.bindExpectedPID(opened.processIdentifier)
            try await controller.waitForHandshake(timeout: timeout)
            return StageControlledHostSession(controller: controller, application: opened)
        } catch {
            await controller.close()
            await application?.finish()
            throw error
        }
    }

    public func request(
        _ command: StageControlCommand,
        timeout: Duration = .seconds(30)
    ) async throws -> StageControlSnapshot {
        try await controller.request(command, timeout: timeout)
    }

    public func waitForEvent(
        _ kind: StageControlEventKind,
        timeout: Duration = .seconds(30)
    ) async throws -> StageControlEvent {
        try await controller.waitForEvent(kind, timeout: timeout)
    }

    public func listScenarios(timeout: Duration = .seconds(30)) async throws -> [StageScenarioMetadata] {
        let result = try await request(.listScenarios, timeout: timeout)
        return result.scenarios ?? []
    }

    public func listCases(timeout: Duration = .seconds(30)) async throws -> [StageCaseMetadata] {
        let result = try await request(.listCases, timeout: timeout)
        return result.cases ?? []
    }

    public func prepare(_ caseID: StageCaseID, timeout: Duration = .seconds(30)) async throws {
        _ = try await request(.loadCase(caseID), timeout: timeout)
        _ = try await request(.prepare, timeout: timeout)
        _ = try await waitForEvent(.ready, timeout: timeout)
    }

    public func prepare(_ scenarioID: StageScenarioID, timeout: Duration = .seconds(30)) async throws {
        _ = try await request(.loadScenario(scenarioID), timeout: timeout)
        _ = try await request(.prepare, timeout: timeout)
        _ = try await waitForEvent(.ready, timeout: timeout)
    }

    public func prepareCapture(
        _ capturePointID: StageCapturePointID,
        timeout: Duration = .seconds(30)
    ) async throws {
        _ = try await request(.prepareCapture(capturePointID), timeout: timeout)
    }

    public func play(timeout: Duration = .seconds(30)) async throws {
        _ = try await request(.play, timeout: timeout)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await controller.close()
        await application.finish()
    }

    public static func withSession<T>(
        appURL: URL,
        bundleIdentifier: String,
        mode: StageHostLaunchMode,
        timeout: Duration = .seconds(30),
        keepAppRunning: Bool = false,
        existingApplicationPolicy: StageExistingApplicationPolicy = .reject,
        operation: @MainActor (StageControlledHostSession) async throws -> T
    ) async throws -> T {
        let session = try await open(
            appURL: appURL,
            bundleIdentifier: bundleIdentifier,
            mode: mode,
            timeout: timeout,
            keepAppRunning: keepAppRunning,
            existingApplicationPolicy: existingApplicationPolicy
        )
        do {
            let result = try await operation(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }
}
