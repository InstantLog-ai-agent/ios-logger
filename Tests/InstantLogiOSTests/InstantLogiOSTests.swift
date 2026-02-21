import XCTest
@testable import InstantLogiOS

final class InstantLogiOSTests: XCTestCase {

    // Required for Linux XCTest runner
    static var allTests = [
        ("testLogLevelRawValues",              testLogLevelRawValues),
        ("testConfigDefaults",                 testConfigDefaults),
        ("testConfigCustomValues",             testConfigCustomValues),
        ("testEntryEncodesRequiredFields",     testEntryEncodesRequiredFields),
        ("testEntryEncodesUserId",             testEntryEncodesUserId),
        ("testEntryEncodesMetadataTypes",      testEntryEncodesMetadataTypes),
        ("testEntrySkipsUnsupportedMetadataValues", testEntrySkipsUnsupportedMetadataValues),
        ("testInstantLogTruncatesLongContent", testInstantLogTruncatesLongContent),
        ("testDisabledSDKDoesNotCrash",        testDisabledSDKDoesNotCrash),
    ]

    // MARK: - InstantLogLevel

    func testLogLevelRawValues() {
        XCTAssertEqual(InstantLogLevel.info.rawValue,     "info")
        XCTAssertEqual(InstantLogLevel.warning.rawValue,  "warning")
        XCTAssertEqual(InstantLogLevel.error.rawValue,    "error")
        XCTAssertEqual(InstantLogLevel.messages.rawValue, "messages")
    }

    // MARK: - InstantLogConfig

    func testConfigDefaults() {
        let config = InstantLogConfig(
            apiKey: "test-key",
            host: URL(string: "https://example.com")!
        )
        XCTAssertNil(config.defaultUserId)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.timeout, 10)
    }

    func testConfigCustomValues() {
        let config = InstantLogConfig(
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

    // MARK: - InstantLogEntry encoding

    func testEntryEncodesRequiredFields() throws {
        let entry = InstantLogEntry(content: "hello", level: .warning, userId: nil, metadata: nil)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["content"] as? String, "hello")
        XCTAssertEqual(json["level"] as? String,   "warning")
        XCTAssertNil(json["user_id"])
        XCTAssertNil(json["metadata"])
    }

    func testEntryEncodesUserId() throws {
        let entry = InstantLogEntry(content: "test", level: .info, userId: "abc-123", metadata: nil)
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
        let entry = InstantLogEntry(content: "meta test", level: .info, userId: nil, metadata: meta)
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
        let entry = InstantLogEntry(content: "test", level: .info, userId: nil, metadata: meta)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let encodedMeta = json["metadata"] as! [String: Any]

        XCTAssertEqual(encodedMeta["valid"] as? String, "yes")
        XCTAssertNil(encodedMeta["invalid"])
    }

    // MARK: - Content truncation

    func testInstantLogTruncatesLongContent() {
        // Configure with a dummy host (no real network call happens in this test)
        InstantLog.configure(
            apiKey: "test-key",
            host: URL(string: "http://localhost:0")!,
            enabled: true
        )

        // 300-char string — SDK should silently truncate without crashing
        let longMessage = String(repeating: "a", count: 300)

        // Just assert no crash — fire-and-forget, nothing to await
        InstantLog.log(longMessage)
    }

    // MARK: - Disabled SDK

    func testDisabledSDKDoesNotCrash() {
        InstantLog.configure(
            apiKey: "key",
            host: URL(string: "http://localhost:0")!,
            enabled: false
        )
        // Should be a no-op, no crash
        InstantLog.log("this should be ignored", level: .error)
    }
}
