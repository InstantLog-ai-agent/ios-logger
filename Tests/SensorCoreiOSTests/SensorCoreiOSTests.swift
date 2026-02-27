import XCTest
@testable import SensorCoreiOS

final class SensorCoreiOSTests: XCTestCase {

    // Required for Linux XCTest runner
    static var allTests = [
        ("testLogLevelRawValues",              testLogLevelRawValues),
        ("testConfigDefaults",                 testConfigDefaults),
        ("testConfigCustomValues",             testConfigCustomValues),
        ("testConfigPersistenceDefaults",      testConfigPersistenceDefaults),
        ("testEntryEncodesRequiredFields",     testEntryEncodesRequiredFields),
        ("testEntryEncodesUserId",             testEntryEncodesUserId),
        ("testEntryEncodesMetadataTypes",      testEntryEncodesMetadataTypes),
        ("testEntrySkipsUnsupportedMetadataValues", testEntrySkipsUnsupportedMetadataValues),
        ("testEntryRoundTrip",                 testEntryRoundTrip),
        ("testEntryServerEncodingExcludesRetryCount", testEntryServerEncodingExcludesRetryCount),
        ("testEntryHasCreatedAtTimestamp",     testEntryHasCreatedAtTimestamp),
        ("testSensorCoreTruncatesLongContent", testSensorCoreTruncatesLongContent),
        ("testDisabledSDKDoesNotCrash",        testDisabledSDKDoesNotCrash),
        ("testRemoteConfigWithValidJSON",       testRemoteConfigWithValidJSON),
        ("testRemoteConfigAccessors",           testRemoteConfigAccessors),
        ("testRemoteConfigWithEmptyJSON",       testRemoteConfigWithEmptyJSON),
        ("testPersistenceSaveAndLoad",          testPersistenceSaveAndLoad),
        ("testPersistencePrunesStaleEntries",   testPersistencePrunesStaleEntries),
        ("testPersistenceRespectsMaxCap",        testPersistenceRespectsMaxCap),
        ("testPersistenceClear",                testPersistenceClear),
        ("testPersistencePrunesExcessRetries",  testPersistencePrunesExcessRetries),
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

    func testConfigPersistenceDefaults() {
        let config = SensorCoreConfig(
            apiKey: "test-key",
            host: URL(string: "https://example.com")!
        )
        XCTAssertTrue(config.persistFailedLogs)
        XCTAssertEqual(config.maxPendingLogs, 500)
        XCTAssertEqual(config.pendingLogMaxAge, 86400)
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
        // created_at should be present
        XCTAssertNotNil(json["created_at"])
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

    func testEntryRoundTrip() throws {
        let meta: [String: Any] = ["key": "value", "count": 42, "flag": true]
        let original = SensorCoreEntry(content: "round trip", level: .error, userId: "user-1", metadata: meta)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SensorCoreEntry.self, from: data)

        XCTAssertEqual(decoded.content, "round trip")
        XCTAssertEqual(decoded.level, "error")
        XCTAssertEqual(decoded.user_id, "user-1")
        XCTAssertEqual(decoded.created_at, original.created_at)
        XCTAssertEqual(decoded.retryCount, 0)
        XCTAssertNotNil(decoded.metadata)
        XCTAssertEqual(decoded.metadata?["key"], .string("value"))
        XCTAssertEqual(decoded.metadata?["count"], .int(42))
        XCTAssertEqual(decoded.metadata?["flag"], .bool(true))
    }

    func testEntryServerEncodingExcludesRetryCount() throws {
        var entry = SensorCoreEntry(content: "test", level: .info, userId: nil, metadata: nil)
        entry.retryCount = 2

        let data = try entry.encodeForServer(encoder: JSONEncoder())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // retryCount / retry_count should NOT be in the server JSON
        XCTAssertNil(json["retryCount"])
        XCTAssertNil(json["retry_count"])
        // But content and created_at should
        XCTAssertEqual(json["content"] as? String, "test")
        XCTAssertNotNil(json["created_at"])
    }

    func testEntryHasCreatedAtTimestamp() {
        let entry = SensorCoreEntry(content: "ts test", level: .info, userId: nil, metadata: nil)

        // created_at should be a valid ISO-8601 string
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: entry.created_at)
        XCTAssertNotNil(date, "created_at should be a valid ISO-8601 timestamp")

        // It should be very close to now (within 2 seconds)
        if let date {
            XCTAssertTrue(abs(date.timeIntervalSinceNow) < 2, "created_at should be close to now")
        }
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

    // MARK: - Persistence

    /// Helper: creates a persistence instance using a temp directory for isolation.
    private func makeTempPersistence(maxEntries: Int = 500, maxAge: TimeInterval = 86400) -> SensorCorePersistence {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SensorCoreTests-\(UUID().uuidString)", isDirectory: true)
        return SensorCorePersistence(maxEntries: maxEntries, maxAge: maxAge, directory: dir)
    }

    func testPersistenceSaveAndLoad() {
        let persistence = makeTempPersistence()
        defer { persistence.clear() }

        let e1 = SensorCoreEntry(content: "log one", level: .info, userId: "u1", metadata: ["key": "val"])
        let e2 = SensorCoreEntry(content: "log two", level: .error, userId: nil, metadata: nil)

        persistence.save([e1, e2])

        let loaded = persistence.loadPending()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].content, "log one")
        XCTAssertEqual(loaded[0].level, "info")
        XCTAssertEqual(loaded[0].user_id, "u1")
        XCTAssertEqual(loaded[1].content, "log two")
        XCTAssertEqual(loaded[1].level, "error")
        XCTAssertNil(loaded[1].user_id)
    }

    func testPersistencePrunesStaleEntries() {
        // maxAge = 1 second
        let persistence = makeTempPersistence(maxAge: 1)
        defer { persistence.clear() }

        let entry = SensorCoreEntry(content: "stale", level: .info, userId: nil, metadata: nil)
        persistence.save([entry])

        // Wait for the entry to become stale
        Thread.sleep(forTimeInterval: 1.5)

        let loaded = persistence.loadPending()
        XCTAssertTrue(loaded.isEmpty, "Stale entries should be pruned")
    }

    func testPersistenceRespectsMaxCap() {
        let persistence = makeTempPersistence(maxEntries: 5)
        defer { persistence.clear() }

        var entries: [SensorCoreEntry] = []
        for i in 0..<10 {
            entries.append(SensorCoreEntry(content: "log \(i)", level: .info, userId: nil, metadata: nil))
        }
        persistence.save(entries)

        let loaded = persistence.loadPending()
        XCTAssertEqual(loaded.count, 5, "Should cap at maxEntries")
        // Should keep the newest (last 5)
        XCTAssertEqual(loaded[0].content, "log 5")
        XCTAssertEqual(loaded[4].content, "log 9")
    }

    func testPersistenceClear() {
        let persistence = makeTempPersistence()

        let entry = SensorCoreEntry(content: "to clear", level: .info, userId: nil, metadata: nil)
        persistence.save([entry])
        XCTAssertEqual(persistence.loadPending().count, 1)

        persistence.clear()
        XCTAssertTrue(persistence.loadPending().isEmpty, "clear() should remove all entries")
    }

    func testPersistencePrunesExcessRetries() {
        let persistence = makeTempPersistence()
        defer { persistence.clear() }

        var entry = SensorCoreEntry(content: "retried too much", level: .info, userId: nil, metadata: nil)
        entry.retryCount = 3  // >= 3 should be pruned
        persistence.save([entry])

        var goodEntry = SensorCoreEntry(content: "still ok", level: .info, userId: nil, metadata: nil)
        goodEntry.retryCount = 2  // < 3, should survive
        persistence.save([goodEntry])

        let loaded = persistence.loadPending()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "still ok")
    }
}
