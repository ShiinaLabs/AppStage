import XCTest
import AppStage
@testable import AppStageControl
import Network

private actor ExampleHost: StageScenarioControlling {
    private var scenarioID: StageScenarioID?
    private let stream: AsyncStream<StageControlEvent>
    private let continuation: AsyncStream<StageControlEvent>.Continuation
    private let prepareStream: AsyncStream<Void>
    private let prepareStarted: AsyncStream<Void>.Continuation
    private let cancellationStream: AsyncStream<Void>
    private let prepareCancelled: AsyncStream<Void>.Continuation
    private(set) var disconnected = false
    private let holdPrepare: Bool
    private let cancellablePrepare: Bool
    private let throwUnknownAction: Bool
    private let finishInsidePlay: Bool
    private let failInsidePlay: Bool
    private var prepareWaiter: CheckedContinuation<Void, Never>?
    private var playWaiter: CheckedContinuation<Void, Never>?

    init(holdPrepare: Bool = false, finishInsidePlay: Bool = false, failInsidePlay: Bool = false, cancellablePrepare: Bool = false, throwUnknownAction: Bool = false) {
        self.holdPrepare = holdPrepare
        self.finishInsidePlay = finishInsidePlay
        self.failInsidePlay = failInsidePlay
        self.cancellablePrepare = cancellablePrepare
        self.throwUnknownAction = throwUnknownAction
        (stream, continuation) = AsyncStream.makeStream()
        (prepareStream, prepareStarted) = AsyncStream.makeStream()
        (cancellationStream, prepareCancelled) = AsyncStream.makeStream()
    }

    func loadScenario(_ id: StageScenarioID) async throws { scenarioID = id }
    func prepareScenario() async throws {
        prepareStarted.yield(())
        if cancellablePrepare {
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                prepareCancelled.yield(())
                throw error
            }
        }
        if holdPrepare { await withCheckedContinuation { prepareWaiter = $0 } }
    }
    func waitUntilPreparing() async {
        var iterator = prepareStream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func waitUntilPrepareCancelled() async {
        var iterator = cancellationStream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func playScenario() async throws {
        if finishInsidePlay || failInsidePlay {
            continuation.yield(.init(kind: failInsidePlay ? .failed : .finished, scenarioID: scenarioID, positionMilliseconds: 1000, error: failInsidePlay ? "Example cue failed" : nil))
            await withCheckedContinuation { playWaiter = $0 }
        }
    }
    func releasePlay() {
        playWaiter?.resume()
        playWaiter = nil
    }
    func pauseScenario() async throws {}
    func resetScenario() async throws {}
    func performAction(_ action: StageAction) async throws {
        if throwUnknownAction { throw StageActionRegistryError.unknownAction(action.id) }
    }
    func events() async -> AsyncStream<StageControlEvent> { stream }
    func controlDisconnected() async {
        disconnected = true
        prepareWaiter?.resume()
        prepareWaiter = nil
        playWaiter?.resume()
        playWaiter = nil
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

    func testTerminalEventDuringPlayCannotBeFollowedByPlaying() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let host = ExampleHost(finishInsidePlay: true)
        let client = StageControlClient(host: host)
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value
        _ = try await controller.request(.loadScenario(StageScenarioID("example")), timeout: .seconds(2))
        _ = try await controller.request(.prepare, timeout: .seconds(2))
        _ = try await controller.waitForEvent(.ready, timeout: .seconds(2))
        let play = Task { try await controller.request(.play, timeout: .seconds(2)) }
        _ = try await controller.waitForEvent(.finished, timeout: .seconds(2))
        await host.releasePlay()
        let result = try await play.value
        XCTAssertEqual(result.state, .finished)
        let state = await controller.state
        XCTAssertEqual(state, .finished)
        let queried = try await controller.request(.queryState, timeout: .seconds(2))
        XCTAssertEqual(queried.state, .finished)
        do {
            _ = try await controller.waitForEvent(.playing, timeout: .milliseconds(20))
            XCTFail("Playing must not follow finished")
        } catch {
            guard case .invalidState = error as? StageControlError else {
                XCTFail("Expected terminal-state rejection, got \(error)")
                return
            }
        }
        await client.close()
        await controller.close()
    }

    func testFailureEventDuringPlayFailsPendingPlayAndPreventsPlaying() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let host = ExampleHost(failInsidePlay: true)
        let client = StageControlClient(host: host)
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value
        _ = try await controller.request(.loadScenario(StageScenarioID("example")), timeout: .seconds(2))
        _ = try await controller.request(.prepare, timeout: .seconds(2))
        _ = try await controller.waitForEvent(.ready, timeout: .seconds(2))
        let play = Task { try await controller.request(.play, timeout: .seconds(2)) }
        let failure = try await controller.waitForEvent(.failed, timeout: .seconds(2))
        XCTAssertEqual(failure.error, "Example cue failed")
        await host.releasePlay()
        do {
            _ = try await play.value
            XCTFail("Play must fail")
        } catch {
            XCTAssertEqual(error as? StageControlError, .remoteFailure("Example cue failed"))
        }
        let state = await controller.state
        XCTAssertEqual(state, .failed)
        await client.close()
        await controller.close()
    }

    func testWaitForEventAfterCloseFailsImmediately() async throws {
        let controller = StageControlController(token: "test", sessionID: UUID(), bundleIdentifier: "example.app")
        await controller.close()
        do {
            _ = try await controller.waitForEvent(.finished, timeout: .milliseconds(30))
            XCTFail("Expected closed control channel")
        } catch {
            XCTAssertEqual(error as? StageControlError, .disconnected)
        }
    }

    func testCancellingEventWaitDoesNotLeaveContinuation() async throws {
        let controller = StageControlController(token: "test", sessionID: UUID(), bundleIdentifier: "example.app")
        let waiter = Task { try await controller.waitForEvent(.finished, timeout: .seconds(2)) }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await controller.close()
    }

    func testDisconnectCancelsInFlightHostRequest() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let host = ExampleHost(cancellablePrepare: true)
        let client = StageControlClient(host: host)
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value
        _ = try await controller.request(.loadScenario(StageScenarioID("example")), timeout: .seconds(2))
        let prepare = Task { try await controller.request(.prepare, timeout: .seconds(2)) }
        await host.waitUntilPreparing()
        await client.close()
        await host.waitUntilPrepareCancelled()
        do {
            _ = try await prepare.value
            XCTFail("Expected connection failure")
        } catch {
            XCTAssertTrue(error is StageControlError)
        }
        await controller.close()
    }

    func testListenerStopsAcceptingAfterValidHandshake() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let client = StageControlClient(host: ExampleHost())
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value
        let accepting = await controller.isAcceptingConnections()
        XCTAssertFalse(accepting)
        let second = StageControlClient(host: ExampleHost())
        do {
            try await second.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42, timeout: .milliseconds(100))
            XCTFail("Authenticated listener must be closed")
        } catch {
            XCTAssertTrue(error is StageControlError)
        }
        await client.close()
        await controller.close()
    }

    func testDelayedStaleSuccessResponseCannotRegressTerminalControllerState() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let wire = StageControlSocket(connection)
        await wire.start()
        let handshake = Task { try await controller.waitForHandshake(timeout: .seconds(2)) }
        try await wire.waitUntilReady()
        try await wire.send(.hello(.init(token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42)))
        let acceptance = try await wire.receive()
        XCTAssertEqual(acceptance, .accepted)
        try await handshake.value

        let query = Task { try await controller.request(.queryState, timeout: .seconds(2)) }
        let message = try await wire.receive()
        guard case let .request(request) = message else { XCTFail("Expected request"); return }
        try await wire.send(.event(.init(kind: .finished, scenarioID: StageScenarioID("example"), positionMilliseconds: 1000)))
        _ = try await controller.waitForEvent(.finished, timeout: .seconds(2))
        try await wire.send(.response(.init(requestID: request.id, result: .success(.init(state: .playing, scenarioID: StageScenarioID("example"))))))
        let result = try await query.value
        XCTAssertEqual(result.state, .finished)
        let state = await controller.state
        XCTAssertEqual(state, .finished)
        await wire.close()
        await controller.close()
    }

    func testUnknownActionFailureNamesTheAction() async throws {
        let token = try StageControlToken.generate()
        let sessionID = UUID()
        let controller = StageControlController(token: token, sessionID: sessionID, bundleIdentifier: "example.app")
        let port = try await controller.start()
        await controller.bindExpectedPID(42)
        let client = StageControlClient(host: ExampleHost(throwUnknownAction: true))
        let connect = Task { try await client.connect(port: port, token: token, sessionID: sessionID, bundleIdentifier: "example.app", pid: 42) }
        try await controller.waitForHandshake(timeout: .seconds(2))
        try await connect.value
        _ = try await controller.request(.loadScenario(StageScenarioID("example")), timeout: .seconds(2))
        _ = try await controller.request(.prepare, timeout: .seconds(2))
        _ = try await controller.waitForEvent(.ready, timeout: .seconds(2))
        do {
            _ = try await controller.request(.performAction(StageAction(id: StageActionID("example.missing"))), timeout: .seconds(2))
            XCTFail("Expected action error")
        } catch {
            XCTAssertEqual(error as? StageControlError, .remoteFailure("Unknown semantic action: example.missing"))
        }
        let failure = try await controller.waitForEvent(.failed, timeout: .seconds(2))
        XCTAssertEqual(failure.error, "Unknown semantic action: example.missing")
        await client.close()
        await controller.close()
    }
}
