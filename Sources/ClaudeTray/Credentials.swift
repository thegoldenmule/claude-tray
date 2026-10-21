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

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    // Never let the token leak through string interpolation / logging.
    var description: String { "ClaudeCredentials(accessToken: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))" }
    var debugDescription: String { description }
}

enum Credentials {
    nonisolated static let keychainService = "Claude Code-credentials"

    /// `security` exit status when the item doesn't exist.
    nonisolated private static let errSecItemNotFoundExitCode: Int32 = 44

    /// Reads Claude Code's OAuth credentials from the login Keychain.
    ///
    /// Shells out to `/usr/bin/security` rather than using SecItemCopyMatching:
    /// the item was created by `security`, so it is in the item's ACL and no
    /// Keychain prompt is shown. Runs off the main thread.
    ///
    /// - Throws: `UsageAPIError.notLoggedIn` if the item is missing or has no
    ///   Claude.ai OAuth entry, `UsageAPIError.keychainUnavailable` for other failures.
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

        do {
            try process.run()
        } catch {
            throw UsageAPIError.keychainUnavailable
        }
        // Drain the pipe before waiting so a large item can't deadlock on a full pipe buffer.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

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

    nonisolated private static func decode(_ data: Data) throws -> ClaudeCredentials {
        guard let payload = try? JSONDecoder().decode(KeychainPayload.self, from: data),
              let oauth = payload.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty
        else {
            throw UsageAPIError.notLoggedIn
        }
        let expiry = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiry)
    }
}
