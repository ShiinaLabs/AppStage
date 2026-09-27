import AppStage
import Foundation
import Network

/// Outgoing host-side connection; product behavior stays behind StageScenarioControlling.
public actor StageControlClient {
    private let host: any StageScenarioControlling
    private var socket: StageControlSocket?
    private var machine = StageControlStateMachine()
    private var readTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private var connectTimedOut = false

    public init(host: any StageScenarioControlling) { self.host = host }

    public func connect(port: UInt16, token: String, sessionID: UUID, bundleIdentifier: String, pid: Int32, timeout: Duration = .seconds(30)) async throws {
        try await withTaskCancellationHandler {
            try await connectUncancelled(port: port, token: token, sessionID: sessionID, bundleIdentifier: bundleIdentifier, pid: pid, timeout: timeout)
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func connectUncancelled(port: UInt16, token: String, sessionID: UUID, bundleIdentifier: String, pid: Int32, timeout: Duration) async throws {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let socket = StageControlSocket(connection)
        self.socket = socket
        await socket.start()
        let timer = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            await self.expireConnect()
        }
        defer { timer.cancel() }
        do {
            try await socket.waitUntilReady()
            try await socket.send(.hello(.init(token: token, sessionID: sessionID, bundleIdentifier: bundleIdentifier, pid: pid)))
            let reply = try await socket.receive()
            switch reply {
            case .accepted: machine.connected()
            case let .rejected(error): await socket.close(); throw error
            default: await socket.close(); throw StageControlError.invalidState("Controller did not accept handshake")
            }
        } catch {
            if connectTimedOut { throw StageControlError.timedOut("host handshake") }
            throw error
        }
        readTask = Task { await self.readLoop() }
        eventTask = Task { await self.forwardEvents() }
    }

    private func expireConnect() async {
        guard machine.state != .connected else { return }
        connectTimedOut = true
        await socket?.close()
    }

    private func readLoop() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard case let .request(request) = message else {
                    throw StageControlError.invalidState("Unexpected controller control message")
                }
                guard !closed else { break }
                requestTasks[request.id] = Task { await self.handle(request) }
            }
        } catch {
            if !closed { await close() }
        }
    }

    private func handle(_ request: StageControlRequest) async {
        defer { requestTasks.removeValue(forKey: request.id) }
        guard !closed && !Task.isCancelled, let socket else { return }
        do {
            try machine.begin(request.command)
            switch request.command {
            case let .loadScenario(id): try await host.loadScenario(id)
            case .prepare: try await host.prepareScenario()
            case .play: try await host.playScenario()
            case .pause: try await host.pauseScenario()
            case .reset: try await host.resetScenario()
            case let .performAction(action): try await host.performAction(action)
            case .listScenarios: break
            case .queryState: break
            case .seek: throw StageControlError.unsupported("seek reconstruction")
            }
            guard !closed && !Task.isCancelled else { return }
            if machine.state == .failed { return }
            machine.succeeded(request.command)
            let scenarios = request.command == .listScenarios ? await host.availableScenarios() : nil
            let snapshot = StageControlSnapshot(state: machine.state, scenarioID: machine.scenarioID, scenarios: scenarios)
            try await socket.send(.response(.init(requestID: request.id, result: .success(snapshot))))
            guard !closed && !Task.isCancelled && machine.state != .finished && machine.state != .failed else { return }
            switch request.command {
            case .prepare: try await sendEvent(.init(kind: .ready, scenarioID: machine.scenarioID))
            case .play: try await sendEvent(.init(kind: .playing, scenarioID: machine.scenarioID))
            case .pause: try await sendEvent(.init(kind: .paused, scenarioID: machine.scenarioID))
            default: break
            }
        } catch {
            guard !closed && !Task.isCancelled else { return }
            let wrapped = controlError(error)
            try? await socket.send(.response(.init(requestID: request.id, result: .failure(wrapped))))
            if case .invalidState = wrapped { return }
            if case .unsupported = wrapped { return }
            machine.failed()
            try? await socket.send(.event(.init(kind: .failed, scenarioID: machine.scenarioID, error: wrapped.localizedDescription)))
        }
    }

    private func controlError(_ error: Error) -> StageControlError {
        if let error = error as? StageControlError { return error }
        if let registryError = error as? StageActionRegistryError {
            switch registryError {
            case let .unknownAction(id): return .remoteFailure("Unknown semantic action: \(id.rawValue)")
            case let .duplicateAction(id): return .remoteFailure("Duplicate semantic action registration: \(id.rawValue)")
            }
        }
        return .remoteFailure(error.localizedDescription)
    }

    private func forwardEvents() async {
        let stream = await host.events()
        for await event in stream {
            guard !closed else { break }
            do { try await sendEvent(event) }
            catch { await close(); break }
        }
    }

    private func sendEvent(_ event: StageControlEvent) async throws {
        guard !closed else { throw StageControlError.disconnected }
        if machine.state == .finished || machine.state == .failed { return }
        machine.received(event)
        guard let socket else { throw StageControlError.disconnected }
        try await socket.send(.event(event))
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        eventTask?.cancel()
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        await socket?.close()
        await host.controlDisconnected()
        machine.disconnected()
    }
}
