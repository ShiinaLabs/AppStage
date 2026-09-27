import XCTest
import AppStage
import AppStageControl

final class StageControlStateTests: XCTestCase {
    func testCommandsRejectIllegalTransitionsAndEventsAdvanceState() throws {
        var machine = StageControlStateMachine()
        XCTAssertThrowsError(try machine.begin(.prepare))
        XCTAssertThrowsError(try machine.begin(.play))
        XCTAssertThrowsError(try machine.begin(.seek(positionMilliseconds: 1000))) {
            XCTAssertEqual($0 as? StageControlError, .unsupported("seek reconstruction"))
        }
        machine.connected()
        XCTAssertThrowsError(try machine.begin(.play))
        try machine.begin(.loadScenario(StageScenarioID("example")))
        machine.succeeded(.loadScenario(StageScenarioID("example")))
        XCTAssertEqual(machine.state, .scenarioLoaded)
        try machine.begin(.prepare)
        XCTAssertEqual(machine.state, .preparing)
        XCTAssertThrowsError(try machine.begin(.play))
        machine.received(.init(kind: .ready, scenarioID: StageScenarioID("example")))
        try machine.begin(.play)
        machine.received(.init(kind: .playing, scenarioID: StageScenarioID("example")))
        XCTAssertEqual(machine.state, .playing)
        machine.received(.init(kind: .finished, scenarioID: StageScenarioID("example")))
        XCTAssertEqual(machine.state, .finished)
    }

    func testDisconnectIsTerminalFailure() throws {
        var machine = StageControlStateMachine()
        machine.connected()
        machine.disconnected()
        XCTAssertEqual(machine.state, .failed)
        XCTAssertThrowsError(try machine.begin(.queryState))
    }

    func testScenarioDiscoveryDoesNotChangeControlState() throws {
        var machine = StageControlStateMachine()
        machine.connected()
        try machine.begin(.listScenarios)
        machine.succeeded(.listScenarios)
        XCTAssertEqual(machine.state, .connected)
    }
}
