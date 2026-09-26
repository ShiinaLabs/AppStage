import Foundation
import XCTest
@testable import AppStageCLI

@MainActor
final class StageAppSessionTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/Fixture.app")
    private let bundleID = "com.example.fixture"

    func testLaunchesAndTerminatesAppStartedByAppStage() async throws {
        let app = FakeApplication(pid: 41, bundleIdentifier: bundleID)
        let manager = FakeApplicationManager(launched: app)

        let session = try await StageAppSession.open(
            appURL: appURL,
            bundleIdentifier: bundleID,
            arguments: ["--scenario", "fixture"],
            applicationManager: manager
        )

        XCTAssertEqual(session.ownership, .launchedByAppStage)
        XCTAssertEqual(session.processIdentifier, 41)
        XCTAssertEqual(session.bundleIdentifier, bundleID)
        await session.finish()
        XCTAssertEqual(app.events, ["terminate", "wait"])
        XCTAssertEqual(app.gracePeriod, .seconds(3))
        XCTAssertEqual(manager.launchCount, 1)
    }

    func testAttachesToPreexistingAppAndNeverTerminatesIt() async throws {
        let app = FakeApplication(pid: 42, bundleIdentifier: bundleID)
        let manager = FakeApplicationManager(running: [app])

        let session = try await StageAppSession.open(
            appURL: appURL,
            bundleIdentifier: bundleID,
            arguments: [],
            applicationManager: manager
        )

        XCTAssertEqual(session.ownership, .preexisting)
        await session.finish()
        XCTAssertTrue(app.events.isEmpty)
        XCTAssertEqual(manager.launchCount, 0)
    }

    func testKeepAppRunningSkipsTerminationForOwnedApp() async throws {
        let app = FakeApplication(pid: 43, bundleIdentifier: bundleID)
        let session = try await StageAppSession.open(
            appURL: appURL,
            bundleIdentifier: bundleID,
            arguments: [],
            keepAppRunning: true,
            applicationManager: FakeApplicationManager(launched: app)
        )

        await session.finish()
        XCTAssertTrue(app.events.isEmpty)
    }

    func testGracefulTerminationDoesNotForceTerminateWhenSuccessful() async throws {
        let app = FakeApplication(pid: 44, bundleIdentifier: bundleID, gracefulExitSucceeds: true)
        let session = try await ownedSession(app)

        await session.finish()

        XCTAssertEqual(app.events, ["terminate", "wait"])
    }

    func testGracefulTerminationTimeoutFallsBackToForceTerminate() async throws {
        let app = FakeApplication(pid: 45, bundleIdentifier: bundleID, gracefulExitSucceeds: false)
        let session = try await ownedSession(app)

        await session.finish()

        XCTAssertEqual(app.events, ["terminate", "wait", "forceTerminate"])
    }

    func testCaptureFailureStillCleansUpOwnedApp() async throws {
        let app = FakeApplication(pid: 46, bundleIdentifier: bundleID)
        let session = try await ownedSession(app)

        do {
            try await session.performCapture {
                throw FixtureError.captureFailed
            }
            XCTFail("Expected capture failure")
        } catch FixtureError.captureFailed {
            // Expected; cleanup is asserted below.
        }

        XCTAssertEqual(app.events, ["terminate", "wait"])
    }

    func testCaptureFinalizesVideoBeforeOwnedAppTermination() async throws {
        let events = EventLog()
        let app = FakeApplication(pid: 47, bundleIdentifier: bundleID, eventLog: events)
        let session = try await ownedSession(app)

        try await session.performCapture {
            events.append("stopStream")
            events.append("finishWriter")
        }

        XCTAssertEqual(events.values, ["stopStream", "finishWriter", "terminate", "wait"])
    }

    private func ownedSession(_ app: FakeApplication) async throws -> StageAppSession {
        try await StageAppSession.open(
            appURL: appURL,
            bundleIdentifier: bundleID,
            arguments: [],
            applicationManager: FakeApplicationManager(launched: app)
        )
    }
}

@MainActor
private final class FakeApplication: StageApplicationHandle {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    var isTerminated = false
    let gracefulExitSucceeds: Bool
    private(set) var gracePeriod: Duration?
    private let eventLog: EventLog
    private(set) var events: [String] = []

    init(
        pid: pid_t,
        bundleIdentifier: String?,
        gracefulExitSucceeds: Bool = true,
        eventLog: EventLog? = nil
    ) {
        self.processIdentifier = pid
        self.bundleIdentifier = bundleIdentifier
        self.gracefulExitSucceeds = gracefulExitSucceeds
        self.eventLog = eventLog ?? EventLog()
    }

    func terminate() { record("terminate") }
    func forceTerminate() { record("forceTerminate") }
    func waitUntilTerminated(gracePeriod: Duration) async -> Bool {
        self.gracePeriod = gracePeriod
        record("wait")
        return gracefulExitSucceeds
    }

    private func record(_ event: String) {
        events.append(event)
        eventLog.append(event)
    }
}

@MainActor
private final class FakeApplicationManager: StageApplicationManaging {
    private let running: [any StageApplicationHandle]
    private let launched: any StageApplicationHandle
    private(set) var launchCount = 0

    init(running: [any StageApplicationHandle] = [], launched: any StageApplicationHandle? = nil) {
        self.running = running
        self.launched = launched ?? FakeApplication(pid: 99, bundleIdentifier: "com.example.fixture")
    }

    func runningApplications(bundleIdentifier: String) -> [any StageApplicationHandle] { running }
    func launchApplication(at url: URL, arguments: [String]) async throws -> any StageApplicationHandle {
        launchCount += 1
        return launched
    }
}

@MainActor
private final class EventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private enum FixtureError: Error {
    case captureFailed
}
