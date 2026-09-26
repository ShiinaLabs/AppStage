import XCTest
import Network
@testable import AppStageControl

final class StageControlListenerTests: XCTestCase {
    func testConcurrentCloseCompletesForEveryCaller() async throws {
        let queue = DispatchQueue(label: "appstage.control.listener.test")
        let listener = StageControlListener(queue: queue)
        _ = try await listener.start()
        queue.suspend()
        let first = Task { await listener.close() }
        let second = Task { await listener.close() }
        for _ in 0..<1_000 {
            if await listener.cancellationWaiterCount == 2 { break }
            await Task.yield()
        }
        let waiters = await listener.cancellationWaiterCount
        queue.resume()
        XCTAssertEqual(waiters, 2)
        await first.value
        await second.value
        let accepting = await listener.isAcceptingConnections
        XCTAssertFalse(accepting)
    }

    func testAcceptSuspendedDuringCloseCannotQueueConnection() async throws {
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let listener = StageControlListener(startSocket: { _ in
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        })
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let acceptance = Task { await listener.accept(connection) }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()
        await listener.close()
        releaseContinuation.yield(())
        await acceptance.value
        let queued = await listener.queuedConnectionCount
        XCTAssertEqual(queued, 0)
    }
}
