import XCTest
@testable import Yaotong

final class ConfigStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ConfigStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.yaotong.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = ConfigStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultsAre30And10() {
        XCTAssertEqual(store.workMinutes, 30)
        XCTAssertEqual(store.restMinutes, 10)
    }

    // MARK: - Allowed values

    func testAllowedValuesAreAccepted() {
        for minutes in ConfigStore.allowedWorkMinuteOptions {
            store.workMinutes = minutes
            XCTAssertEqual(store.workMinutes, minutes)
        }
        for minutes in ConfigStore.allowedRestMinuteOptions {
            store.restMinutes = minutes
            XCTAssertEqual(store.restMinutes, minutes)
        }
    }

    func testDisallowedValuesFallBackToDefault() {
        defaults.set(7, forKey: "yaotong.workMinutes")
        XCTAssertEqual(store.workMinutes, ConfigStore.defaultWorkMinutes)
    }

    // MARK: - Persistence

    func testSettingsPersistAcrossInstances() {
        store.workMinutes = 45
        store.restMinutes = 15

        let other = ConfigStore(defaults: defaults)
        XCTAssertEqual(other.workMinutes, 45)
        XCTAssertEqual(other.restMinutes, 15)
    }

    // MARK: - Pause

    func testPauseIsOffByDefault() {
        XCTAssertFalse(store.isPaused)
    }

    func testTogglePause() {
        XCTAssertTrue(store.togglePause(), "first toggle should activate pause")
        XCTAssertTrue(store.isPaused)
        XCTAssertFalse(store.togglePause(), "second toggle should clear pause")
        XCTAssertFalse(store.isPaused)
    }

    func testPauseDoesNotPersistAcrossInstances() {
        store.isPaused = true
        let other = ConfigStore(defaults: defaults)
        XCTAssertFalse(
            other.isPaused,
            "every launch should start running (isPaused = false) — no stale pause from yesterday"
        )
    }

    // MARK: - Callbacks

    func testOnChangeFires() {
        var calls: [ConfigStore] = []
        store.onChange = { calls.append($0) }
        store.workMinutes = 20
        store.restMinutes = 5
        XCTAssertEqual(calls.count, 2)
    }
}
