import XCTest
import AppStage
import AppStageControl

private actor ExampleHost: StageScenarioControlling {
    private var scenarioID: StageScenarioID?
    private let stream: AsyncStream<StageControlEvent>
    private let continuation: AsyncStream<StageControlEvent>.Continuation
    private let prepareStream: AsyncStream<Void>
    private let prepareStarted: AsyncStream<Void>.Continuation
    private(set) var disconnected = false
    private let holdPrepare: Bool
    private var prepareWaiter: CheckedContinuation<Void, Never>?

    init(holdPrepare: Bool = false) {
        self.holdPrepare = holdPrepare
        (stream, continuation) = AsyncStream.makeStream()
        (prepareStream, prepareStarted) = AsyncStream.makeStream()
    }

    func loadScenario(_ id: StageScenarioID) async throws { scenarioID = id }
    func prepareScenario() async throws {
        prepareStarted.yield(())
        if holdPrepare { await withCheckedContinuation { prepareWaiter = $0 } }
    }
    func waitUntilPreparing() async {
        var iterator = prepareStream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func playScenario() async throws {}
    func pauseScenario() async throws {}
    func resetScenario() async throws {}
    func performAction(_ action: StageAction) async throws {}
    func events() async -> AsyncStream<StageControlEvent> { stream }
    func controlDisconnected() async {
        disconnected = true
        prepareWaiter?.resume()
        prepareWaiter = nil
    }
    func finish() { continuation.yield(.init(kind: .finished, scenarioID: scenarioID, positionMilliseconds: 1000)) }
}

final class StageControlTransportTests: XCTestCase {
    func testLoopbackHandshakeCorrelatedRequestsAndFinishedEvent() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let host = ExampleHost()
        let client = StageControlClient(host: host)
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value

        _ = try await controller.request(.loadScenario(StageScenarioID("example")), timeout: .seconds(2))
        _ = try await controller.request(.prepare, timeout: .seconds(2))
        let ready = try await controller.waitForEvent(.ready, timeout: .seconds(2))
        XCTAssertEqual(ready.scenarioID, StageScenarioID("example"))
        _ = try await controller.request(.play, timeout: .seconds(2))
        let queries = try await withThrowingTaskGroup(of: StageControlSnapshot.self) { group in
            group.addTask { try await controller.request(.queryState, timeout: .seconds(2)) }
            group.addTask { try await controller.request(.queryState, timeout: .seconds(2)) }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(queries.map(\.state), [.playing, .playing])
        await host.finish()
        let finished = try await controller.waitForEvent(.finished, timeout: .seconds(2))
        XCTAssertEqual(finished.positionMilliseconds, 1000)
        await controller.close()
        await client.close()
    }

    func testPendingRequestFailsWhenConnectionCloses() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let host = ExampleHost(holdPrepare: true)
        let client = StageControlClient(host: host)
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value
        _ = try await controller.request(.loadScenario(StageScenarioID("example")), timeout: .seconds(2))
        let request = Task { try await controller.request(.prepare, timeout: .seconds(2)) }
        await host.waitUntilPreparing()
        await client.close()
        do {
            _ = try await request.value
            XCTFail("Expected connection loss")
        } catch {
            XCTAssertTrue(error is StageControlError)
        }
        await controller.close()
    }

    func testWrongTokenIsRejectedOnTheWire() async throws {
        let sessionID = UUID()
        let controller = StageControlController(token: "correct", sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let handshake = Task { try await controller.waitForHandshake(timeout: .seconds(2)) }
        let client = StageControlClient(host: ExampleHost())
        do {
            try await client.connect(port: port, token: "wrong", sessionID: sessionID, bundleIdentifier: "example.app", pid: 42)
            XCTFail("Expected token rejection")
        } catch {
            XCTAssertEqual(error as? StageControlError, .invalidToken)
        }
        await controller.close()
        _ = try? await handshake.value
    }

    func testHandshakeTimesOutWithoutHost() async throws {
        let controller = StageControlController(token: "test", sessionID: UUID(), bundleIdentifier: "example.app")
        _ = try await controller.start()
        await controller.bindExpectedPID(42)
        do {
            try await controller.waitForHandshake(timeout: .milliseconds(30))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? StageControlError, .timedOut("handshake"))
        }
        let state = await controller.state
        XCTAssertEqual(state, .failed)
    }

    func testPendingPrepareTimesOut() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let host = ExampleHost(holdPrepare: true)
        let client = StageControlClient(host: host)
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value
        _ = try await controller.request(.loadScenario(StageScenarioID("example")), timeout: .seconds(2))
        do {
            _ = try await controller.request(.prepare, timeout: .milliseconds(30))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? StageControlError, .timedOut("request"))
        }
        await client.close()
    }
}
