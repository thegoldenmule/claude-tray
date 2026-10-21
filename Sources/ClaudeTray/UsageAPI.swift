import Foundation

/// Every error surfaced by Credentials / UsageAPI.
enum UsageAPIError: Error, Sendable, Equatable {
    case notLoggedIn
    case keychainUnavailable
    case tokenExpired
    case unauthorized(Int)                      // 401 / 403
    case rateLimited(retryAfter: TimeInterval?) // 429
    case http(Int)
    case network(String)
    case decoding

    /// Short, user-facing message (rate limiting is formatted by the model, which knows the backoff).
    var userMessage: String {
        switch self {
        case .notLoggedIn: "Not logged in to Claude Code"
        case .keychainUnavailable: "Couldn't read Claude Code credentials"
        case .tokenExpired, .unauthorized: "Token expired — open Claude Code to refresh"
        case .rateLimited: "Rate limited"
        case .http(let code): "Server error (\(code))"
        case .network: "Network error"
        case .decoding: "Unexpected response from server"
        }
    }
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Ephemeral: no cookies, no disk cache, nothing persisted.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// Fetches current usage. Always throws `UsageAPIError`.
    static func fetch(token: String, now: Date = Date()) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeTray/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageAPIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.network("Invalid response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw UsageAPIError.unauthorized(http.statusCode)
        case 429:
            throw UsageAPIError.rateLimited(retryAfter: parseRetryAfter(http.value(forHTTPHeaderField: "retry-after"), now: now))
        default:
            throw UsageAPIError.http(http.statusCode)
        }

        return try parse(data, fetchedAt: now)
    }

    // MARK: - Parsing (internal for testing)

    static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw UsageAPIError.decoding
        }
        return UsageSnapshot(session: body.fiveHour?.window,
                             weekly: body.sevenDay?.window,
                             fetchedAt: fetchedAt)
    }

    /// `retry-after` is either delta-seconds or an HTTP-date.
    static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    /// Parses ISO-8601 with any number of fractional-second digits (the API sends
    /// microseconds, e.g. `2026-10-21T20:30:00.412488+00:00`), with `Z` or `±hh:mm`.
    static func parseDate(_ string: String) -> Date? {
        var base = string
        var fraction: TimeInterval = 0
        if let dot = string.firstIndex(of: ".") {
            let digitsEnd = string[string.index(after: dot)...].firstIndex { !$0.isNumber } ?? string.endIndex
            let digits = string[string.index(after: dot)..<digitsEnd]
            fraction = TimeInterval("0." + digits) ?? 0
            base = String(string[..<dot] + string[digitsEnd...])
        }
        guard let date = try? Date(base, strategy: .iso8601) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    private struct ResponseBody: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        // Lenient: a malformed window becomes nil instead of failing the whole response.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
        }
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
        }

        var window: UsageWindow? {
            guard let utilization, utilization.isFinite else { return nil }
            return UsageWindow(percent: utilization, resetsAt: resetsAt.flatMap(UsageAPI.parseDate))
        }
    }
}
