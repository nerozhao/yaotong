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

    func testPauseSetsFutureDate() {
        XCTAssertFalse(store.isPaused())
        let now = Date()
        store.pauseUntil = now.addingTimeInterval(60 * 60)
        XCTAssertTrue(store.isPaused(now: now))
        XCTAssertFalse(store.isPaused(now: now.addingTimeInterval(2 * 60 * 60)))
    }

    func testTogglePause() {
        let now = Date()
        XCTAssertTrue(store.togglePause(now: now), "first toggle should activate pause")
        XCTAssertTrue(store.isPaused(now: now))
        XCTAssertFalse(store.togglePause(now: now), "second toggle should clear pause")
        XCTAssertFalse(store.isPaused(now: now))
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
