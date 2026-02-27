import Foundation

// MARK: - SensorCoreEntry

/// Internal JSON-codable representation of a single log entry.
///
/// Instances are created by ``SensorCore`` and passed to ``SensorCoreClient``
/// for queuing and transmission. This type is intentionally internal — consumers
/// of the SDK interact only through ``SensorCore/log(_:level:userId:metadata:)``.
///
/// ### Persistence
/// When a log entry fails to send (e.g. no internet), it is written to disk
/// as a JSON-lines file and retried later. Both `Encodable` (for the server)
/// and `Decodable` (for reading back from disk) conformance are required.
struct SensorCoreEntry: Codable {

    // MARK: - Stored properties (match server field names exactly)

    /// The log message text. Already truncated to 5000 characters by the time
    /// this struct is created.
    let content: String

    /// Raw string value of ``SensorCoreLevel``, e.g. `"info"`, `"error"`.
    let level: String

    /// External user identifier, if provided. Snake-cased to match the server field name.
    let user_id: String?

    /// Key-value metadata encoded as ``SensorCoreMetadataValue`` wrappers.
    /// `nil` when the caller did not supply a metadata dict.
    let metadata: [String: SensorCoreMetadataValue]?

    /// ISO-8601 timestamp captured at log-creation time on the client.
    ///
    /// The server accepts an optional `created_at` field; when present it is used
    /// instead of the server-side `NOW()`. This guarantees that offline-buffered
    /// logs preserve the correct chronological order in analytics, even if they
    /// are delivered minutes or hours after the event actually occurred.
    let created_at: String

    /// Number of times this entry has been retried after a network failure.
    ///
    /// Excluded from the JSON sent to the server (not in ``CodingKeys``),
    /// but persisted to disk so the retry budget survives app restarts.
    var retryCount: Int

    // MARK: - CodingKeys

    /// Controls which fields appear in the encoded JSON.
    ///
    /// `retryCount` is intentionally included — it is needed for disk persistence.
    /// When building the server request, ``SensorCoreClient/buildRequest(entry:)``
    /// uses a separate encoder that excludes it via ``ServerCodingKeys``.
    enum CodingKeys: String, CodingKey {
        case content, level, user_id, metadata, created_at
        case retryCount = "retry_count"
    }

    // MARK: - ServerCodingKeys

    /// Coding keys used when encoding for the **server** HTTP request.
    /// This set deliberately omits `retryCount` so the server never sees it.
    enum ServerCodingKeys: String, CodingKey {
        case content, level, user_id, metadata, created_at
    }

    // MARK: - Init

    /// Creates a log entry from the SDK's public-facing parameters.
    ///
    /// During initialisation, unsupported metadata value types are silently dropped
    /// (see ``SensorCoreMetadataValue``).
    ///
    /// - Parameters:
    ///   - content: Already-truncated log message.
    ///   - level: Severity level; stored as `rawValue` string.
    ///   - userId: Optional user identifier.
    ///   - metadata: Raw dictionary; values are converted to ``SensorCoreMetadataValue``.
    init(
        content: String,
        level: SensorCoreLevel,
        userId: String?,
        metadata: [String: Any]?
    ) {
        self.content = content
        self.level = level.rawValue
        self.user_id = userId
        self.metadata = metadata.map { dict in
            dict.compactMapValues { SensorCoreMetadataValue(value: $0) }
        }

        // ISO-8601 timestamp captured right now — this is the "real" event time.
        self.created_at = Self.iso8601Formatter.string(from: Date())

        self.retryCount = 0
    }

    // MARK: - Shared Formatter

    /// Shared ISO-8601 formatter with fractional seconds.
    /// `ISO8601DateFormatter` is thread-safe, so a single static instance is fine.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Server Encoding

    /// Encodes the entry for the server request, **excluding** `retryCount`.
    func encodeForServer(encoder: JSONEncoder) throws -> Data {
        // Use a wrapper that only encodes the server-relevant fields.
        try encoder.encode(ServerEnvelope(entry: self))
    }
}

// MARK: - ServerEnvelope

/// A thin wrapper that encodes only the fields the server expects,
/// omitting internal bookkeeping like `retryCount`.
private struct ServerEnvelope: Encodable {
    let entry: SensorCoreEntry

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SensorCoreEntry.ServerCodingKeys.self)
        try container.encode(entry.content, forKey: .content)
        try container.encode(entry.level, forKey: .level)
        try container.encodeIfPresent(entry.user_id, forKey: .user_id)
        try container.encodeIfPresent(entry.metadata, forKey: .metadata)
        try container.encode(entry.created_at, forKey: .created_at)
    }
}

// MARK: - SensorCoreMetadataValue

/// Type-erasing wrapper that makes heterogeneous metadata dictionaries `Codable`.
///
/// The server accepts a flat JSON object for `metadata`. Swift's type system
/// requires all values in a `Codable` dictionary to be the same type, so this enum
/// wraps each supported primitive before encoding.
///
/// ### Supported types
/// | Swift type | JSON type |
/// |-----------|-----------
/// | `String`  | string    |
/// | `Int`     | number    |
/// | `Double` / `Float` | number |
/// | `Bool`    | boolean   |
///
/// Any other type (arrays, nested dictionaries, custom objects) is silently ignored
/// by ``init?(value:)`` returning `nil`, which causes `compactMapValues` to drop the key.
enum SensorCoreMetadataValue: Codable, Equatable {

    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    // MARK: - Init from Any

    /// Attempts to wrap a raw `Any` value.
    ///
    /// Returns `nil` for unsupported types so callers can use `compactMapValues`.
    ///
    /// - Parameter value: The raw value from the user-supplied metadata dictionary.
    init?(value: Any) {
        switch value {
        case let v as String: self = .string(v)
        case let v as Int:    self = .int(v)
        case let v as Double: self = .double(v)
        case let v as Float:  self = .double(Double(v))
        case let v as Bool:   self = .bool(v)
        default:              return nil
        }
    }

    // MARK: - Decodable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try each type in order of specificity.
        // Bool must come before Int because JSON booleans can decode as Int.
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "SensorCoreMetadataValue: unsupported JSON type"
            )
        }
    }

    // MARK: - Encodable

    /// Encodes the wrapped value as a JSON primitive into a single-value container.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v):   try container.encode(v)
        }
    }
}
