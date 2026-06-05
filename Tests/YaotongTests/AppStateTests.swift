import XCTest
@testable import Yaotong

@MainActor
final class AppStateTests: XCTestCase {

    func testForcedStateDefaultsToNil() {
        let state = AppState()
        XCTAssertNil(state.forcedIconState)
    }

    func testSetForcedState() {
        let state = AppState()
        state.setForcedState(.overtime)
        XCTAssertEqual(state.forcedIconState, .overtime)
        state.setForcedState(.working)
        XCTAssertEqual(state.forcedIconState, .working)
        state.setForcedState(nil)
        XCTAssertNil(state.forcedIconState)
    }

    func testClearForcedState() {
        let state = AppState()
        state.setForcedState(.overtime)
        state.clearForcedState()
        XCTAssertNil(state.forcedIconState)
    }
}
