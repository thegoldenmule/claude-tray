import Foundation

/// The subset of Claude Code's OAuth credentials that ClaudeTray needs.
///
/// Only the access token and its expiry are ever decoded; the refresh token,
/// MCP secrets and everything else in the Keychain item are never retained.
/// We never refresh the token ourselves: doing so would rotate Claude Code's
/// refresh token and silently log Claude Code out.
struct ClaudeCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    /// nil when Claude Code didn't record an expiry.
    let expiresAt: Date?

    /// Treat the token as expired slightly early so a request doesn't race the expiry.
    static let expirySkew: TimeInterval = 60

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.expirySkew)
    }

    // Never let the token leak through string interpolation / logging.
    var description: String { "ClaudeCredentials(accessToken: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))" }
    var debugDescription: String { description }
}

enum Credentials {
    nonisolated static let keychainService = "Claude Code-credentials"

    /// `security` exit status when the item doesn't exist.
    nonisolated private static let errSecItemNotFoundExitCode: Int32 = 44
    /// A Keychain prompt or locked keychain can block `security` indefinitely.
    nonisolated private static let securityTimeout: TimeInterval = 15

    /// Reads Claude Code's OAuth credentials from the login Keychain.
    ///
    /// Shells out to `/usr/bin/security` rather than using SecItemCopyMatching:
    /// the item was created by `security`, so it is in the item's ACL and no
    /// Keychain prompt is shown. Runs off the main thread.
    ///
    /// - Throws: `UsageAPIError.notLoggedIn` if the item is missing or has no
    ///   Claude.ai OAuth entry, `UsageAPIError.unreadableCredentials` if it isn't
    ///   the expected JSON, `UsageAPIError.keychainUnavailable` for other failures.
    static func load() async throws -> ClaudeCredentials {
        let task = Task.detached(priority: .utility) { () throws -> ClaudeCredentials in
            let data = try readKeychainItem()
            return try decode(data)
        }
        return try await task.value
    }

    nonisolated private static func readKeychainItem() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let reader = stdout.fileHandleForReading
        defer { try? reader.close() }

        do {
            try process.run()
        } catch {
            throw UsageAPIError.keychainUnavailable
        }
        // Killing the process closes its end of the pipe, which unblocks the read below.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + securityTimeout, execute: timeout)
        // Drain the pipe before waiting so a large item can't deadlock on a full pipe buffer.
        let data = reader.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        guard process.terminationReason == .exit else { throw UsageAPIError.keychainUnavailable }
        switch process.terminationStatus {
        case 0:
            return data
        case errSecItemNotFoundExitCode:
            throw UsageAPIError.notLoggedIn
        default:
            throw UsageAPIError.keychainUnavailable
        }
    }

    private struct KeychainPayload: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?   // milliseconds since epoch
        }
        let claudeAiOauth: OAuth?
    }

    /// Parses `security -w` output. Internal for testing.
    nonisolated static func decode(_ output: Data) throws -> ClaudeCredentials {
        var data = output
        while let last = data.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            data.removeLast()
        }
        guard !data.isEmpty else { throw UsageAPIError.notLoggedIn }
        // `security -w` prints the value as hex if it has any non-ASCII byte or newline
        // (e.g. a non-ASCII MCP server name in the JSON).
        if data.first != UInt8(ascii: "{"), let decoded = hexDecoded(data) {
            data = decoded
        }
        guard let payload = try? JSONDecoder().decode(KeychainPayload.self, from: data) else {
            throw UsageAPIError.unreadableCredentials
        }
        guard let oauth = payload.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty
        else {
            throw UsageAPIError.notLoggedIn
        }
        let expiry = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiry)
    }

    /// nil unless `hex` is a non-empty, even-length run of hex digits.
    nonisolated private static func hexDecoded(_ hex: Data) -> Data? {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var result = Data(capacity: hex.count / 2)
        var high: UInt8?
        for char in hex {
            let nibble: UInt8
            switch char {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = char - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = char - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = char - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let h = high {
                result.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return result
    }
}
