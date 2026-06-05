import XCTest
@testable import Yaotong

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Tag prefix

    func testStripTagPrefix() {
        XCTAssertEqual(UpdateChecker.stripTagPrefix("v0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateChecker.stripTagPrefix("V1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateChecker.stripTagPrefix("0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateChecker.stripTagPrefix("  v0.2.0  "), "0.2.0")
    }

    // MARK: - Version validity

    func testValidVersions() {
        for v in ["0.2.0", "1.0", "1.0.0", "10.20.30", "0.1.0-beta", "1.0.0+build.42"] {
            XCTAssertTrue(UpdateChecker.isValidVersion(v), "expected valid: \(v)")
        }
    }

    func testInvalidVersions() {
        for v in ["", "abc", "1.0.0.0", "1..2", ".1.0", "1.0.", "v", "v.."] {
            XCTAssertFalse(UpdateChecker.isValidVersion(v), "expected invalid: \(v)")
        }
    }

    // MARK: - Semver comparison

    func testIsNewerTrueCases() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2.1", current: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.3.0", current: "0.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0", current: "0.9.9"))
        // Single-component vs multi-component: "1" pads to "1.0.0"
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1", current: "0.9.9"))
        // 0.10.0 must beat 0.9.0 — easy string-comparison trap.
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.10.0", current: "0.9.0"))
    }

    func testIsNewerFalseCases() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.2.0", current: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.1.9", current: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.9.9", current: "1.0.0"))
        // Unparseable current → false, never claim an update on
        // garbage.
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.2.0", current: "garbage"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "garbage", current: "0.2.0"))
    }

    // MARK: - JSON parsing

    func testParseReleaseFullPayload() throws {
        let json = """
        {
          "tag_name": "v0.3.0",
          "html_url": "https://github.com/nerozhao/yaotong/releases/tag/v0.3.0",
          "body": "## What's new\\n- thing one\\n- thing two"
        }
        """.data(using: .utf8)!
        let info = try UpdateChecker.parseRelease(json)
        XCTAssertEqual(info.version, "0.3.0")
        XCTAssertEqual(info.htmlURL.absoluteString, "https://github.com/nerozhao/yaotong/releases/tag/v0.3.0")
        XCTAssertNotNil(info.notes)
        XCTAssertTrue(info.notes!.contains("thing one"))
    }

    func testParseReleaseMissingBody() throws {
        let json = """
        { "tag_name": "v1.0.0", "html_url": "https://example.com" }
        """.data(using: .utf8)!
        let info = try UpdateChecker.parseRelease(json)
        XCTAssertEqual(info.version, "1.0.0")
        XCTAssertNil(info.notes)
    }

    func testParseReleaseRejectsMalformedPayloads() {
        // Not a JSON object
        XCTAssertThrowsError(try UpdateChecker.parseRelease(Data("[1,2,3]".utf8)))
        // Missing tag_name
        XCTAssertThrowsError(try UpdateChecker.parseRelease(Data("{}".utf8)))
        // Empty tag_name
        XCTAssertThrowsError(try UpdateChecker.parseRelease(Data("{\"tag_name\":\"\"}".utf8)))
        // Tag that doesn't parse as a version
        XCTAssertThrowsError(try UpdateChecker.parseRelease(Data("{\"tag_name\":\"latest\"}".utf8)))
        // html_url that isn't a URL
        XCTAssertThrowsError(try UpdateChecker.parseRelease(Data("{\"tag_name\":\"v0.1.0\",\"html_url\":\"\"}".utf8)))
    }

    // MARK: - Result classification

    func testClassifyNewerReturnsUpdateAvailable() {
        let info = UpdateChecker.UpdateInfo(
            version: "0.3.0",
            htmlURL: URL(string: "https://example.com")!,
            notes: nil
        )
        let result = UpdateChecker.classify(
            info: info,
            currentVersion: "0.2.0",
            skipped: nil
        )
        XCTAssertEqual(result, .updateAvailable(info))
    }

    func testClassifySameVersionIsUpToDate() {
        let info = UpdateChecker.UpdateInfo(
            version: "0.2.0",
            htmlURL: URL(string: "https://example.com")!,
            notes: nil
        )
        let result = UpdateChecker.classify(
            info: info,
            currentVersion: "0.2.0",
            skipped: nil
        )
        XCTAssertEqual(result, .upToDate)
    }

    func testClassifySkippedVersionIsTreatedAsSkipped() {
        let info = UpdateChecker.UpdateInfo(
            version: "0.3.0",
            htmlURL: URL(string: "https://example.com")!,
            notes: nil
        )
        let result = UpdateChecker.classify(
            info: info,
            currentVersion: "0.2.0",
            skipped: "0.3.0"
        )
        if case .skipped(let v) = result {
            XCTAssertEqual(v.version, "0.3.0")
        } else {
            XCTFail("expected .skipped, got \(result)")
        }
    }

    // MARK: - Prompt gating (background vs manual)

    private func info(_ version: String) -> UpdateChecker.UpdateInfo {
        UpdateChecker.UpdateInfo(
            version: version,
            htmlURL: URL(string: "https://example.com")!,
            notes: nil
        )
    }

    func testShouldShowUpdateAvailableForBothSources() {
        XCTAssertTrue(UpdatePrompt.shouldShow(.updateAvailable(info("0.3.0")), source: .background))
        XCTAssertTrue(UpdatePrompt.shouldShow(.updateAvailable(info("0.3.0")), source: .manual))
    }

    func testShouldShowUpToDateOnlyOnManual() {
        // Background: silence — don't pester the user on every launch.
        XCTAssertFalse(UpdatePrompt.shouldShow(.upToDate, source: .background))
        // Manual: user clicked the button, acknowledge the result.
        XCTAssertTrue(UpdatePrompt.shouldShow(.upToDate, source: .manual))
    }

    func testShouldShowFailedOnlyOnManual() {
        // Background: log only, never pop a dialog.
        XCTAssertFalse(UpdatePrompt.shouldShow(.failed("HTTP 500"), source: .background))
        // Manual: user explicitly asked — a brief error is appropriate.
        XCTAssertTrue(UpdatePrompt.shouldShow(.failed("HTTP 500"), source: .manual))
    }

    func testShouldShowSkippedForNeitherSource() {
        // The user already dismissed this version — never re-prompt.
        XCTAssertFalse(UpdatePrompt.shouldShow(.skipped(info("0.3.0")), source: .background))
        XCTAssertFalse(UpdatePrompt.shouldShow(.skipped(info("0.3.0")), source: .manual))
    }

    // MARK: - Throttle

    /// Throttling is the only state that lives across calls;
    /// verify it survives a round-trip through UserDefaults so a
    /// relaunch doesn't re-prompt.
    func testStateRoundTrip() {
        let suite = "test.yaotong.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let state = UpdateChecker.State(defaults: defaults)

        XCTAssertNil(state.lastCheck)
        XCTAssertNil(state.skippedVersion)

        let now = Date()
        state.lastCheck = now
        state.skippedVersion = "0.3.0"

        let restored = UpdateChecker.State(defaults: defaults)
        XCTAssertEqual(restored.lastCheck, now)
        XCTAssertEqual(restored.skippedVersion, "0.3.0")
    }
}
