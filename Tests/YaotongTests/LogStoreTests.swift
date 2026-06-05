import XCTest
@testable import Yaotong

final class LogStoreTests: XCTestCase {

    @MainActor
    func testBasicLogging() {
        let store = LogStore()
        XCTAssertEqual(store.entries.count, 0)
        store.log("hello")
        // log() hops onto a background queue then the main thread; allow
        // the runloop to drain.
        let exp = expectation(description: "entry arrives")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(store.entries.count, 1)
            XCTAssertEqual(store.entries.first?.message, "hello")
            XCTAssertEqual(store.entries.first?.level, .info)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testLevelPropagates() {
        let store = LogStore()
        store.log("warn", level: .warn)
        store.log("err",  level: .error)
        let exp = expectation(description: "entries arrive")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(store.entries.count, 2)
            XCTAssertEqual(store.entries[0].level, .warn)
            XCTAssertEqual(store.entries[1].level, .error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testIsLoggingFalseDropsEntries() {
        let store = LogStore()
        store.isLogging = false
        store.log("dropped")
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(store.entries.count, 0)
            // Re-enable logging and confirm new entries flow.
            store.isLogging = true
            store.log("kept")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(store.entries.count, 1)
                XCTAssertEqual(store.entries.first?.message, "kept")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testRingBufferCap() {
        let store = LogStore()
        // Drop the cap so the test is fast.
        let cap = LogStore.maxEntries
        XCTAssertGreaterThan(cap, 0)
        for i in 0..<(cap + 100) {
            store.log("entry \(i)")
        }
        let exp = expectation(description: "cap holds")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(store.entries.count, cap)
            // Oldest 100 entries should have been dropped; first kept one
            // should be "entry 100".
            XCTAssertEqual(store.entries.first?.message, "entry 100")
            XCTAssertEqual(store.entries.last?.message, "entry \(cap + 99)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    @MainActor
    func testClear() {
        let store = LogStore()
        store.log("a")
        store.log("b")
        let exp = expectation(description: "clear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(store.entries.count, 2)
            store.clear()
            XCTAssertEqual(store.entries.count, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testFormattedIncludesTimestampAndSymbol() {
        let store = LogStore()
        store.log("hello", level: .warn)
        let exp = expectation(description: "formatted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let line = store.formatted(store.entries[0])
            // Should contain the warning symbol and "hello".
            XCTAssertTrue(line.contains("hello"), "line: \(line)")
            XCTAssertTrue(line.contains("⚠️"), "line: \(line)")
            // Sanity check: line should be longer than the bare message
            // (timestamp + symbol add ~16 chars).
            XCTAssertTrue(line.count > "hello".count + 10, "line: \(line)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
