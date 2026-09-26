import AppStage
import Foundation

/// Owns the loopback listener and a single authenticated host session.
public actor StageControlController {
    private let token: String
    private let sessionID: UUID
    private let bundleIdentifier: String
    private var expectedPID: Int32?
    private let listener = StageControlListener()
    private var socket: StageControlSocket?
    private var machine = StageControlStateMachine()
    private var pending: [UUID: CheckedContinuation<StageControlSnapshot, Error>] = [:]
    private var eventWaiters: [StageControlEventKind: [CheckedContinuation<StageControlEvent, Error>]] = [:]
    private var eventBacklog: [StageControlEvent] = []
    private var readTask: Task<Void, Never>?
    private var timeoutPhase: String?
    private var closed = false

    public var state: StageControlState { machine.state }

    public init(token: String, sessionID: UUID, bundleIdentifier: String) {
        self.token = token
        self.sessionID = sessionID
        self.bundleIdentifier = bundleIdentifier
    }

    public func start() async throws -> UInt16 { try await listener.start() }

    /// Bind the PID from the launched, concrete app instance before accepting hello.
    public func bindExpectedPID(_ pid: Int32) { expectedPID = pid }

    public func waitForHandshake(timeout: Duration = .seconds(30)) async throws {
        try await withTaskCancellationHandler {
            try await waitForHandshakeUncancelled(timeout: timeout)
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func waitForHandshakeUncancelled(timeout: Duration) async throws {
        let timer = deadline(.handshake, after: timeout)
        defer { timer.cancel() }
        guard let expectedPID else { throw StageControlError.invalidState("Expected application PID is not bound") }
        while !closed {
            let candidate: StageControlSocket
            do { candidate = try await listener.nextConnection() }
            catch {
                if let timeoutPhase { throw StageControlError.timedOut(timeoutPhase) }
                throw error
            }
            do {
                socket = candidate
                try await candidate.waitUntilReady()
                let message = try await candidate.receive()
                guard case let .hello(hello) = message else { throw StageControlError.invalidState("Host must send hello first") }
                let identity = StageControlIdentity(token: token, sessionID: sessionID, bundleIdentifier: bundleIdentifier, pid: expectedPID)
                try identity.validate(hello)
                try await candidate.send(.accepted)
                machine.connected()
                readTask = Task { await self.readLoop() }
                return
            } catch {
                let rejection = (error as? StageControlError) ?? .transport(error.localizedDescription)
                try? await candidate.send(.rejected(rejection))
                await candidate.close()
                socket = nil
                if let timeoutPhase { throw StageControlError.timedOut(timeoutPhase) }
            }
        }
        throw StageControlError.timedOut(timeoutPhase ?? "handshake")
    }

    public func request(_ command: StageControlCommand, timeout: Duration = .seconds(30)) async throws -> StageControlSnapshot {
        try await withTaskCancellationHandler {
            try await requestUncancelled(command, timeout: timeout)
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func requestUncancelled(_ command: StageControlCommand, timeout: Duration) async throws -> StageControlSnapshot {
        try machine.begin(command)
        guard let socket else { throw StageControlError.disconnected }
        let request = StageControlRequest(command: command)
        let timer = deadline(.request, after: timeout)
        defer { timer.cancel() }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = continuation
                Task {
                    do { try await socket.send(.request(request)) }
                    catch { self.failRequest(request.id, error: error) }
                }
            }
        } catch {
            if let timeoutPhase { throw StageControlError.timedOut(timeoutPhase) }
            throw error
        }
    }

    public func waitForEvent(_ kind: StageControlEventKind, timeout: Duration = .seconds(30)) async throws -> StageControlEvent {
        try await withTaskCancellationHandler {
            try await waitForEventUncancelled(kind, timeout: timeout)
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func waitForEventUncancelled(_ kind: StageControlEventKind, timeout: Duration) async throws -> StageControlEvent {
        if let index = eventBacklog.firstIndex(where: { $0.kind == kind }) {
            return eventBacklog.remove(at: index)
        }
        if let failed = eventBacklog.first(where: { $0.kind == .failed }) {
            throw StageControlError.remoteFailure(failed.error ?? "Host scenario failed")
        }
        let timer = deadline(.scenario, after: timeout)
        defer { timer.cancel() }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                eventWaiters[kind, default: []].append(continuation)
            }
        } catch {
            if let timeoutPhase { throw StageControlError.timedOut(timeoutPhase) }
            throw error
        }
    }

    private enum Phase: String { case handshake, request, scenario }

    private func deadline(_ phase: Phase, after duration: Duration) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: duration) }
            catch { return }
            await self.expire(phase.rawValue)
        }
    }

    private func expire(_ phase: String) async {
        guard !closed else { return }
        timeoutPhase = phase
        receive(.init(kind: .failed, scenarioID: machine.scenarioID, error: "Control \(phase) timed out"))
        await close()
    }

    private func readLoop() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case let .response(response): resolve(response)
                case let .event(event): receive(event)
                default: throw StageControlError.invalidState("Unexpected host control message")
                }
            }
        } catch {
            if !closed { await failConnection(error) }
        }
    }

    private func resolve(_ response: StageControlResponse) {
        guard let continuation = pending.removeValue(forKey: response.requestID) else { return }
        switch response.result {
        case let .success(snapshot):
            // Host's snapshot is authoritative for correlated command completion.
            if snapshot.state == .scenarioLoaded, let id = snapshot.scenarioID {
                machine.succeeded(.loadScenario(id))
            } else if snapshot.state == .preparing {
                // A ready event follows the prepare response.
            } else if snapshot.state == .ready { machine.received(.init(kind: .ready, scenarioID: snapshot.scenarioID)) }
            else if snapshot.state == .playing { machine.received(.init(kind: .playing, scenarioID: snapshot.scenarioID)) }
            else if snapshot.state == .paused { machine.received(.init(kind: .paused, scenarioID: snapshot.scenarioID)) }
            continuation.resume(returning: snapshot)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func receive(_ event: StageControlEvent) {
        machine.received(event)
        if event.kind == .failed {
            let error = StageControlError.remoteFailure(event.error ?? "Host scenario failed")
            for (kind, waiters) in eventWaiters where kind != .failed {
                waiters.forEach { $0.resume(throwing: error) }
            }
            eventWaiters = eventWaiters.filter { $0.key == .failed }
        }
        if var waiters = eventWaiters[event.kind], !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            eventWaiters[event.kind] = waiters
            waiter.resume(returning: event)
        } else { eventBacklog.append(event) }
    }

    private func failRequest(_ id: UUID, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failConnection(_ error: Error) async {
        machine.disconnected()
        let event = StageControlEvent(kind: .failed, scenarioID: machine.scenarioID, error: error.localizedDescription)
        receive(event)
        await close()
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        await socket?.close()
        await listener.close()
        let error = StageControlError.disconnected
        let pendingValues = Array(pending.values)
        pending.removeAll()
        pendingValues.forEach { $0.resume(throwing: error) }
        for waiters in eventWaiters.values { waiters.forEach { $0.resume(throwing: error) } }
        eventWaiters.removeAll()
        machine.disconnected()
    }
}
