import Foundation
import XCTest
@testable import VibeTyping

final class SessionStateMachineTests: XCTestCase {
    func testNormalHoldCommitsAndAppliesTranscript() {
        var machine = SessionStateMachine()
        XCTAssertEqual(machine.handle(.serverReady), [])
        XCTAssertEqual(machine.phase, .idle)

        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(machine.handle(.press(start)), [.beginCapture])
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(
            machine.handle(.release(start.addingTimeInterval(0.8))),
            [.stopAndCommit]
        )
        XCTAssertEqual(machine.phase, .transcribing)
        XCTAssertEqual(
            machine.handle(.transcript(" hello ")),
            [.applyTranscript("hello")]
        )
        XCTAssertEqual(machine.handle(.applyCompleted), [.scheduleReadyReset])
        XCTAssertEqual(machine.phase, .ready)
        XCTAssertEqual(machine.handle(.readyExpired), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testShortHoldClearsWithoutCommit() {
        var machine = SessionStateMachine()
        _ = machine.handle(.serverReady)
        let start = Date(timeIntervalSince1970: 100)
        _ = machine.handle(.press(start))
        XCTAssertEqual(
            machine.handle(.release(start.addingTimeInterval(0.49))),
            [.stopAndClear]
        )
        XCTAssertEqual(machine.phase, .idle)
    }

    func testAutoLimitCommits() {
        var machine = SessionStateMachine()
        _ = machine.handle(.serverReady)
        _ = machine.handle(.press(.now))
        XCTAssertEqual(machine.handle(.autoLimitReached), [.stopAndCommit])
        XCTAssertEqual(machine.phase, .transcribing)
    }

    func testEmptyTranscriptReturnsIdle() {
        var machine = SessionStateMachine()
        _ = machine.handle(.serverReady)
        let start = Date()
        _ = machine.handle(.press(start))
        _ = machine.handle(.release(start.addingTimeInterval(1)))
        XCTAssertEqual(machine.handle(.transcript(" \n ")), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testFailureCanRetry() {
        var machine = SessionStateMachine()
        XCTAssertEqual(machine.handle(.fail("offline")), [.reportError("offline")])
        XCTAssertEqual(machine.phase, .error)
        XCTAssertEqual(machine.lastError, "offline")
        XCTAssertEqual(machine.handle(.retry), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.lastError)
    }
}
