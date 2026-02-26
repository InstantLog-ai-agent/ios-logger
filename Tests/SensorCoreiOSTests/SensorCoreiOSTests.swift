import XCTest
@testable import SensorCoreiOS

final class SensorCoreiOSTests: XCTestCase {

    // Required for Linux XCTest runner
    static var allTests = [
        ("testLogLevelRawValues",              testLogLevelRawValues),
        ("testConfigDefaults",                 testConfigDefaults),
        ("testConfigCustomValues",             testConfigCustomValues),
        ("testEntryEncodesRequiredFields",     testEntryEncodesRequiredFields),
        ("testEntryEncodesUserId",             testEntryEncodesUserId),
        ("testEntryEncodesMetadataTypes",      testEntryEncodesMetadataTypes),
        ("testEntrySkipsUnsupportedMetadataValues", testEntrySkipsUnsupportedMetadataValues),
        ("testSensorCoreTruncatesLongContent", testSensorCoreTruncatesLongContent),
        ("testDisabledSDKDoesNotCrash",        testDisabledSDKDoesNotCrash),
        ("testRemoteConfigWithValidJSON",       testRemoteConfigWithValidJSON),
        ("testRemoteConfigAccessors",           testRemoteConfigAccessors),
        ("testRemoteConfigWithEmptyJSON",       testRemoteConfigWithEmptyJSON),
        // Note: testRemoteConfigNotConfiguredReturnsEmpty is async — omitted from Linux manifest
    ]

    // MARK: - SensorCoreLevel

    func testLogLevelRawValues() {
        XCTAssertEqual(SensorCoreLevel.info.rawValue,     "info")
        XCTAssertEqual(SensorCoreLevel.warning.rawValue,  "warning")
        XCTAssertEqual(SensorCoreLevel.error.rawValue,    "error")
        XCTAssertEqual(SensorCoreLevel.messages.rawValue, "messages")
    }

    // MARK: - SensorCoreConfig

    func testConfigDefaults() {
        let config = SensorCoreConfig(
            apiKey: "test-key",
            host: URL(string: "https://example.com")!
        )
        XCTAssertNil(config.defaultUserId)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.timeout, 10)
    }

    func testConfigCustomValues() {
        let config = SensorCoreConfig(
            apiKey: "il_abc",
            host: URL(string: "https://logs.example.com")!,
            defaultUserId: "user-123",
            enabled: false,
            timeout: 30
        )
        XCTAssertEqual(config.apiKey, "il_abc")
        XCTAssertEqual(config.defaultUserId, "user-123")
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.timeout, 30)
    }

    // MARK: - SensorCoreEntry encoding

    func testEntryEncodesRequiredFields() throws {
        let entry = SensorCoreEntry(content: "hello", level: .warning, userId: nil, metadata: nil)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["content"] as? String, "hello")
        XCTAssertEqual(json["level"] as? String,   "warning")
        XCTAssertNil(json["user_id"])
        XCTAssertNil(json["metadata"])
    }

    func testEntryEncodesUserId() throws {
        let entry = SensorCoreEntry(content: "test", level: .info, userId: "abc-123", metadata: nil)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["user_id"] as? String, "abc-123")
    }

    func testEntryEncodesMetadataTypes() throws {
        let meta: [String: Any] = [
            "str": "value",
            "int": 42,
            "dbl": 3.14,
            "bool": true
        ]
        let entry = SensorCoreEntry(content: "meta test", level: .info, userId: nil, metadata: meta)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let encodedMeta = json["metadata"] as! [String: Any]

        XCTAssertEqual(encodedMeta["str"] as? String, "value")
        XCTAssertEqual(encodedMeta["int"] as? Int,    42)
        XCTAssertEqual(encodedMeta["bool"] as? Bool,  true)
        XCTAssertNotNil(encodedMeta["dbl"])
    }

    func testEntrySkipsUnsupportedMetadataValues() throws {
        // Arrays are not a supported metadata type — should be dropped
        let meta: [String: Any] = ["valid": "yes", "invalid": [1, 2, 3]]
        let entry = SensorCoreEntry(content: "test", level: .info, userId: nil, metadata: meta)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let encodedMeta = json["metadata"] as! [String: Any]

        XCTAssertEqual(encodedMeta["valid"] as? String, "yes")
        XCTAssertNil(encodedMeta["invalid"])
    }

    // MARK: - Content truncation

    func testSensorCoreTruncatesLongContent() {
        // Configure with a dummy host (no real network call happens in this test)
        SensorCore.configure(
            apiKey: "test-key",
            host: URL(string: "http://localhost:0")!,
            enabled: true
        )

        // 300-char string — SDK should silently truncate without crashing
        let longMessage = String(repeating: "a", count: 300)

        // Just assert no crash — fire-and-forget, nothing to await
        SensorCore.log(longMessage)
    }

    // MARK: - Disabled SDK

    func testDisabledSDKDoesNotCrash() {
        SensorCore.configure(
            apiKey: "key",
            host: URL(string: "http://localhost:0")!,
            enabled: false
        )
        // Should be a no-op, no crash
        SensorCore.log("this should be ignored", level: .error)
    }

    // MARK: - Remote Config

    func testRemoteConfigWithValidJSON() {
        // Build a config directly from a raw dictionary (no network needed)
        let raw: [String: Any] = [
            "show_new_onboarding": true,
            "api_timeout_seconds": 30.0,
            "experiment_variant": "B",
            "max_retries": 3
        ]
        let config = SensorCoreRemoteConfig(raw: raw)
        XCTAssertNotNil(config["show_new_onboarding"])
        XCTAssertEqual(config.string(for: "experiment_variant"), "B")
    }

    func testRemoteConfigAccessors() {
        let raw: [String: Any] = [
            "flag": true,
            "count": 7,
            "ratio": 0.5,
            "label": "hello"
        ]
        let config = SensorCoreRemoteConfig(raw: raw)

        // Bool
        XCTAssertEqual(config.bool(for: "flag"), true)
        XCTAssertNil(config.bool(for: "label"))     // wrong type
        XCTAssertNil(config.bool(for: "missing"))   // missing key

        // Int
        XCTAssertEqual(config.int(for: "count"), 7)
        XCTAssertNil(config.int(for: "ratio"))      // 0.5 is not exact int

        // Double
        XCTAssertEqual(config.double(for: "ratio"), 0.5)
        XCTAssertEqual(config.double(for: "count"), 7.0) // int -> double promotion

        // String
        XCTAssertEqual(config.string(for: "label"), "hello")
        XCTAssertNil(config.string(for: "count"))   // wrong type
    }

    func testRemoteConfigWithEmptyJSON() {
        let config = SensorCoreRemoteConfig(raw: [:])
        XCTAssertNil(config["anything"])
        XCTAssertNil(config.bool(for: "flag"))
        XCTAssertNil(config.string(for: "label"))
        XCTAssertTrue(config.raw.isEmpty)
    }

    func testRemoteConfigNotConfiguredReturnsEmpty() async {
        // Re-configure with disabled SDK so client is nil
        SensorCore.configure(
            apiKey: "key",
            host: URL(string: "http://localhost:0")!,
            enabled: false
        )
        // Should return empty config without crashing
        let config = await SensorCore.remoteConfig()
        XCTAssertTrue(config.raw.isEmpty)
    }
}
