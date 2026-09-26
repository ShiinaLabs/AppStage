import Foundation
import Network

actor StageControlSocket {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "appstage.control.connection")
    private var decoder = StageControlFrameDecoder()
    private var pendingMessages: [StageControlMessage] = []
    private var ready = false
    private var failure: StageControlError?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.updated(state) }
        }
        connection.start(queue: queue)
    }

    private func updated(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case .failed(let error):
            fail(.transport(error.localizedDescription))
        case .cancelled:
            fail(.disconnected)
        default:
            break
        }
    }

    private func fail(_ error: StageControlError) {
        failure = error
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    func waitUntilReady() async throws {
        if ready { return }
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    func send(_ message: StageControlMessage) async throws {
        if let failure { throw failure }
        let bytes = try StageControlCodec.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: StageControlError.transport(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> StageControlMessage {
        if !pendingMessages.isEmpty { return pendingMessages.removeFirst() }
        while true {
            if let failure { throw failure }
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: StageControlError.transport(error.localizedDescription)) }
                    else if complete && (data?.isEmpty ?? true) { continuation.resume(throwing: StageControlError.disconnected) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            pendingMessages.append(contentsOf: try decoder.append(Array(data)))
            if !pendingMessages.isEmpty { return pendingMessages.removeFirst() }
        }
    }

    func close() {
        connection.cancel()
        fail(.disconnected)
    }
}

actor StageControlListener {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "appstage.control.listener")
    private var readyWaiter: CheckedContinuation<UInt16, Error>?
    private var connectionWaiters: [CheckedContinuation<StageControlSocket, Error>] = []
    private var connections: [StageControlSocket] = []
    private var failure: StageControlError?
    private var cancelled = false
    private var cancelledWaiter: CheckedContinuation<Void, Never>?

    var isAcceptingConnections: Bool { listener != nil && failure == nil && !cancelled }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw StageControlError.transport(error.localizedDescription) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.updated(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            readyWaiter = continuation
            listener.start(queue: queue)
        }
    }

    private func updated(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                readyWaiter?.resume(returning: port)
                readyWaiter = nil
            } else { fail(.transport("Listener has no local port")) }
        case .failed(let error): fail(.transport(error.localizedDescription))
        case .cancelled:
            cancelled = true
            fail(.disconnected)
            cancelledWaiter?.resume()
            cancelledWaiter = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) async {
        guard failure == nil else { connection.cancel(); return }
        let socket = StageControlSocket(connection)
        await socket.start()
        if connectionWaiters.isEmpty { connections.append(socket) }
        else { connectionWaiters.removeFirst().resume(returning: socket) }
    }

    func nextConnection() async throws -> StageControlSocket {
        if !connections.isEmpty { return connections.removeFirst() }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { connectionWaiters.append($0) }
    }

    private func fail(_ error: StageControlError) {
        failure = error
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    func close() async {
        fail(.disconnected)
        if !cancelled, let listener {
            await withCheckedContinuation { continuation in
                cancelledWaiter = continuation
                listener.cancel()
            }
        }
        for connection in connections { await connection.close() }
        connections.removeAll()
    }
}
