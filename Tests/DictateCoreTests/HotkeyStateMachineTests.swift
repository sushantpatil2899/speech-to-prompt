import XCTest
@testable import DictateCore

final class HotkeyStateMachineTests: XCTestCase {
    private func machine(raw: HotkeyBehavior = .hold, clean: HotkeyBehavior = .hold) -> HotkeyStateMachine {
        HotkeyStateMachine(settings: .init(
            bindings: [
                .raw: HotkeyConfig(key: .rightOption, behavior: raw),
                .clean: HotkeyConfig(key: .rightCommand, behavior: clean),
            ],
            minHoldSeconds: 0.2, tapMaxSeconds: 0.35))
    }

    func testHoldStartsOnDownAndStopsOnUp() {
        let m = machine()
        XCTAssertEqual(m.handle(.modifierDown(.rightOption, time: 0)), .startRecording(.raw))
        XCTAssertTrue(m.isRecording)
        XCTAssertEqual(m.handle(.modifierUp(.rightOption, time: 1.5)), .stopRecording(.raw))
        XCTAssertEqual(m.state, .idle)
    }

    func testHoldTooShortIsCancelled() {
        let m = machine()
        m.handle(.modifierDown(.rightCommand, time: 0))
        XCTAssertEqual(m.handle(.modifierUp(.rightCommand, time: 0.1)), .cancelRecording(.clean, .tooShort))
        XCTAssertEqual(m.state, .idle)
    }

    func testChordCancelsAndWaitsForRelease() {
        let m = machine()
        m.handle(.modifierDown(.rightCommand, time: 0))
        XCTAssertEqual(m.handle(.otherKeyDown(time: 0.05)), .cancelRecording(.clean, .chord))
        XCTAssertFalse(m.isRecording)
        XCTAssertNil(m.handle(.modifierUp(.rightCommand, time: 0.4)))
        XCTAssertEqual(m.state, .idle)
    }

    func testEscapeCancelsHold() {
        let m = machine()
        m.handle(.modifierDown(.rightOption, time: 0))
        XCTAssertEqual(m.handle(.escape(time: 1)), .cancelRecording(.raw, .escape))
        XCTAssertNil(m.handle(.modifierUp(.rightOption, time: 2)))
        XCTAssertEqual(m.state, .idle)
    }

    func testUnboundModifierIsIgnored() {
        let m = machine()
        XCTAssertNil(m.handle(.modifierDown(.leftShift, time: 0)))
        XCTAssertEqual(m.state, .idle)
    }

    func testOtherModeKeyIgnoredWhileRecording() {
        let m = machine()
        m.handle(.modifierDown(.rightOption, time: 0))
        XCTAssertNil(m.handle(.modifierDown(.rightCommand, time: 0.5)))
        XCTAssertNil(m.handle(.modifierUp(.rightCommand, time: 0.6)))
        XCTAssertEqual(m.handle(.modifierUp(.rightOption, time: 1)), .stopRecording(.raw))
    }

    func testShiftDuringHoldDoesNotCancel() {
        let m = machine()
        m.handle(.modifierDown(.rightOption, time: 0))
        XCTAssertNil(m.handle(.modifierDown(.leftShift, time: 0.3)))
        XCTAssertNil(m.handle(.modifierUp(.leftShift, time: 0.4)))
        XCTAssertEqual(m.handle(.modifierUp(.rightOption, time: 1)), .stopRecording(.raw))
    }

    func testToggleTapLatchesThenSecondPressStops() {
        let m = machine(raw: .toggle)
        XCTAssertEqual(m.handle(.modifierDown(.rightOption, time: 0)), .startRecording(.raw))
        XCTAssertNil(m.handle(.modifierUp(.rightOption, time: 0.1)))
        XCTAssertEqual(m.state, .latched(.raw))
        XCTAssertTrue(m.isRecording)
        // Typing while latched does not cancel.
        XCTAssertNil(m.handle(.otherKeyDown(time: 1)))
        XCTAssertEqual(m.handle(.modifierDown(.rightOption, time: 3)), .stopRecording(.raw))
        XCTAssertNil(m.handle(.modifierUp(.rightOption, time: 3.1)))
        XCTAssertEqual(m.state, .idle)
    }

    func testToggleLongPressActsLikeHold() {
        let m = machine(clean: .toggle)
        m.handle(.modifierDown(.rightCommand, time: 0))
        XCTAssertEqual(m.handle(.modifierUp(.rightCommand, time: 2)), .stopRecording(.clean))
        XCTAssertEqual(m.state, .idle)
    }

    func testToggleEscapeWhileLatched() {
        let m = machine(raw: .toggle)
        m.handle(.modifierDown(.rightOption, time: 0))
        m.handle(.modifierUp(.rightOption, time: 0.1))
        XCTAssertEqual(m.handle(.escape(time: 2)), .cancelRecording(.raw, .escape))
        XCTAssertEqual(m.state, .idle)
    }

    func testMissedReleaseRecoversOnNextPress() {
        let m = machine()
        m.handle(.modifierDown(.rightOption, time: 0))
        m.handle(.otherKeyDown(time: 0.1))  // cancel, waiting for release
        // Release event lost; next press should still start.
        XCTAssertEqual(m.handle(.modifierDown(.rightOption, time: 5)), .startRecording(.raw))
    }

    func testResetWhileHeldWaitsForRelease() {
        let m = machine()
        m.handle(.modifierDown(.rightOption, time: 0))
        m.reset()  // e.g. max duration reached
        XCTAssertEqual(m.state, .waitingForRelease(.rightOption))
        XCTAssertNil(m.handle(.modifierUp(.rightOption, time: 200)))
        XCTAssertEqual(m.state, .idle)
    }
}
