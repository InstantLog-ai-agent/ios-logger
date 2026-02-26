import Foundation

// MARK: - SensorCoreError

/// Errors thrown by ``SensorCore/logAsync(_:level:userId:metadata:)``.
///
/// For fire-and-forget calls via ``SensorCore/log(_:level:userId:metadata:)``
/// these errors are swallowed internally and printed to the console in `DEBUG` builds only.
///
/// ### Handling errors
/// ```swift
/// do {
///     try await SensorCore.logAsync("Purchase failed", level: .error)
/// } catch let error as SensorCoreError {
///     switch error {
///     case .rateLimited:            // server banned this client — stop retrying
///     case .serverError(let code):  // e.g. 401 invalid API key, 500 server crash
///     case .networkError:           // timeout, no internet, etc.
///     case .notConfigured:          // forgot to call configure()
///     case .encodingFailed:         // metadata contained an un-serialisable type
///     }
/// }
/// ```
public enum SensorCoreError: Error, LocalizedError {

    /// ``SensorCore/logAsync(_:level:userId:metadata:)`` was called before
    /// ``SensorCore/configure(apiKey:host:defaultUserId:enabled:timeout:)``.
    case notConfigured

    /// The ``SensorCoreEntry`` could not be serialised to JSON.
    /// This usually means a metadata value contained an unsupported type
    /// that slipped past ``SensorCoreMetadataValue/init?(value:)``.
    case encodingFailed(Error)

    /// The server responded with a non-2xx HTTP status code other than 429.
    ///
    /// Common causes:
    /// - `401` — invalid or missing API key
    /// - `400` — request body failed server-side validation (e.g. `content` too long)
    /// - `500` — internal server error
    case serverError(statusCode: Int)

    /// A transport-level error occurred before a response was received.
    ///
    /// Common causes: no internet connection, request timeout, DNS failure.
    case networkError(Error)

    /// The server returned **HTTP 429** (Too Many Requests).
    ///
    /// The SDK has activated its circuit-breaker and will discard all future
    /// log calls for the remainder of the app session. No further network
    /// requests will be made until the app is relaunched.
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .notConfigured:          return "SensorCore is not configured. Call SensorCore.configure(...) at app startup."
        case .encodingFailed(let e):  return "Failed to encode log entry: \(e.localizedDescription)"
        case .serverError(let code):  return "Server returned HTTP \(code)"
        case .networkError(let e):    return "Network error: \(e.localizedDescription)"
        case .rateLimited:            return "SensorCore rate-limited (HTTP 429). Logging suspended for this session."
        }
    }
}

// MARK: - SensorCoreClient

/// Internal actor that owns the log queue and all network I/O.
///
/// ## Architecture
///
/// ```
///  log()          logAsync()
///    │                │
///    ▼                ▼
/// enqueue()      sendThrowing()   ← bypasses queue, async/throws
///    │
///    ▼
/// AsyncStream<SensorCoreEntry>     ← bounded FIFO queue (max 1 000 entries)
///    │
///    ▼
/// single consumer Task             ← one Task for the lifetime of the client
///    │
///    ▼
/// transmit() → URLSession → server
///                              │
///                         429? → silence() → stream.finish() → Task exits
/// ```
///
/// ## Thread safety
/// - The actor serialises all internal state access.
/// - `enqueue()` and `_isSilenced` are `nonisolated` for synchronous call-site use.
/// - The consumer Task captures only `Sendable` values — no reference to `self` is retained
///   (except weakly) so the actor can be released when the SDK is re-configured.
actor SensorCoreClient {

    // MARK: - Constants

    /// Maximum number of log entries that can be pending in the queue.
    /// When this limit is reached, **new** entries are dropped (oldest are preserved).
    static let queueCapacity = 1_000

    // MARK: - Private state

    /// `URLSession` configured with the project's timeout value.
    private let session: URLSession

    /// Reusable encoder for serialising ``SensorCoreEntry`` values to JSON.
    private let encoder: JSONEncoder

    /// API key sent in the `x-api-key` request header.
    private let apiKey: String

    /// Server base URL. The path `/api/logs` is appended by ``buildRequest(entry:)``.
    private let host: URL

    /// The write end of the internal ``AsyncStream``.
    /// Calling `.finish()` on it signals the consumer Task to exit gracefully.
    private let continuation: AsyncStream<SensorCoreEntry>.Continuation

    /// Circuit-breaker flag.
    ///
    /// Once set to `true` (on HTTP 429), it is never reset during the current session.
    /// Declared `nonisolated(unsafe)` so ``enqueue(_:)`` can read it without `await`.
    /// Safe because the transition `false → true` happens exactly once, from the
    /// sequential consumer Task, and a stale `false` read by `enqueue` at worst
    /// causes one extra `yield` that the already-finished stream will silently drop.
    nonisolated(unsafe) private var _isSilenced: Bool = false

    // MARK: - Init

    /// Creates a new client and immediately starts the background consumer Task.
    ///
    /// - Parameter config: The SDK configuration containing API key, host, and timeout.
    init(config: SensorCoreConfig) {
        let sessionCfg = URLSessionConfiguration.default
        sessionCfg.timeoutIntervalForRequest = config.timeout
        let session = URLSession(configuration: sessionCfg)
        self.session = session

        let encoder = JSONEncoder()
        self.encoder = encoder
        self.apiKey = config.apiKey
        self.host = config.host

        // Build the bounded FIFO stream. The continuation's `yield` is Sendable,
        // so it can be called from any thread / actor.
        var cont: AsyncStream<SensorCoreEntry>.Continuation!
        let stream = AsyncStream<SensorCoreEntry>(
            bufferingPolicy: .bufferingOldest(SensorCoreClient.queueCapacity)
        ) { cont = $0 }
        self.continuation = cont

        // Start the single consumer. `[weak self]` prevents a permanent reference
        // cycle — if this actor is released (e.g. after re-configure) the Task
        // will exit on the next loop iteration.
        Task.detached(priority: .utility) { [weak self] in
            for await entry in stream {
                guard let self else { break }
                let banned = await self.transmit(entry: entry)
                if banned { break }
            }
        }
    }

    // MARK: - Internal API

    /// Pushes a log entry into the queue. **Synchronous and nonisolated.**
    ///
    /// This method returns immediately without ever suspending — it is safe to
    /// call from `@MainActor` or any synchronous context with no performance impact.
    ///
    /// If the circuit-breaker has been triggered (``SensorCoreError/rateLimited``),
    /// the entry is silently dropped before it even reaches the stream.
    ///
    /// - Parameter entry: The pre-built log entry to enqueue.
    nonisolated func enqueue(_ entry: SensorCoreEntry) {
        guard !_isSilenced else { return }   // fast-path: no actor hop, no await
        continuation.yield(entry)
    }

    /// Sends a log entry **directly**, bypassing the queue.
    ///
    /// Used exclusively by ``SensorCore/logAsync(_:level:userId:metadata:)`` when
    /// the caller needs to confirm that the server received the log.
    ///
    /// - Parameter entry: The log entry to transmit.
    /// - Throws: ``SensorCoreError/rateLimited`` if already silenced;
    ///   ``SensorCoreError/networkError(_:)`` on transport failure;
    ///   ``SensorCoreError/serverError(statusCode:)`` on non-2xx response.
    func sendThrowing(entry: SensorCoreEntry) async throws {
        guard !_isSilenced else { throw SensorCoreError.rateLimited }
        let request = try buildRequest(entry: entry)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw SensorCoreError.networkError(error)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                silence()
                throw SensorCoreError.rateLimited
            }
            if !(200...299).contains(http.statusCode) {
                throw SensorCoreError.serverError(statusCode: http.statusCode)
            }
        }
    }

    // MARK: - Private

    /// Fetches the current Remote Config from the server.
    ///
    /// Safe by design:
    /// - Returns ``SensorCoreRemoteConfig/empty`` on any network / server / decoding error.
    /// - Never throws. Never crashes.
    /// - Does **not** interact with the circuit-breaker (uses a separate one-shot request).
    ///
    /// - Returns: The decoded config flags, or an empty config on any failure.
    func fetchRemoteConfig() async -> SensorCoreRemoteConfig {
        let url = host.appendingPathComponent("api/config")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                #if DEBUG
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[SensorCore] ⚠️ Remote Config fetch failed — HTTP \(code). Returning empty config.")
                #endif
                return .empty
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                #if DEBUG
                print("[SensorCore] ⚠️ Remote Config response could not be decoded. Returning empty config.")
                #endif
                return .empty
            }
            return SensorCoreRemoteConfig(raw: json)
        } catch {
            #if DEBUG
            print("[SensorCore] ⚠️ Remote Config network error: \(error.localizedDescription). Returning empty config.")
            #endif
            return .empty
        }
    }

    /// Sends one entry from the queue. Called by the consumer Task in a serial loop.
    ///
    /// - Parameter entry: The next entry dequeued from the `AsyncStream`.
    /// - Returns: `true` if a 429 was received and the consumer should stop; `false` otherwise.
    private func transmit(entry: SensorCoreEntry) async -> Bool {
        guard !_isSilenced else { return true }
        guard let request = try? buildRequest(entry: entry) else {
            #if DEBUG
            print("[SensorCore] 🔇 Failed to encode log entry — skipping.")
            #endif
            return false
        }
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 {
                    silence()
                    return true   // signal the consumer loop to break
                }
                if !(200...299).contains(http.statusCode) {
                    #if DEBUG
                    print("[SensorCore] ❌ Server error \(http.statusCode) — log dropped.")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("[SensorCore] ❌ Network error: \(error.localizedDescription)")
            #endif
        }
        return false
    }

    /// Activates the circuit-breaker.
    ///
    /// Sets `_isSilenced = true`, finishes the stream (which causes the consumer
    /// Task to exit after draining), and prints a warning in DEBUG builds.
    /// This method is idempotent — calling it more than once is harmless.
    private func silence() {
        _isSilenced = true
        continuation.finish()   // gracefully stops the consumer Task
        #if DEBUG
        print("[SensorCore] ⚠️ HTTP 429 — rate limited by server. Logging suspended for this session.")
        #endif
    }

    /// Builds a `POST /api/logs` request with the correct headers and JSON body.
    ///
    /// - Parameter entry: The entry to serialise as the request body.
    /// - Returns: A ready-to-send `URLRequest`.
    /// - Throws: ``SensorCoreError/encodingFailed(_:)`` if JSON encoding fails.
    private func buildRequest(entry: SensorCoreEntry) throws -> URLRequest {
        let url = host.appendingPathComponent("api/logs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        do {
            request.httpBody = try encoder.encode(entry)
        } catch {
            // Preserve the real encoding error so callers can surface it via SensorCoreError.encodingFailed.
            throw SensorCoreError.encodingFailed(error)
        }
        return request
    }
}
