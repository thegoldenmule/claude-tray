import AppKit
import Foundation
import Observation

/// One rate-limit window. percent is 0...100 (may exceed 100).
struct UsageWindow: Sendable, Equatable {
    var percent: Double
    var resetsAt: Date?
}

struct UsageSnapshot: Sendable, Equatable {
    var session: UsageWindow?   // five_hour
    var weekly: UsageWindow?    // seven_day
    var fetchedAt: Date
}

enum UsageStatus: Sendable, Equatable {
    case idle                   // never fetched yet
    case loading
    case ok
    case stale(String)          // have old data, latest refresh failed / token expired; message is user-facing
    case error(String)          // no data at all; message is user-facing
}

/// Polls the usage endpoint and publishes the latest snapshot.
///
/// Scheduling: a single loop sleeps until `nextDueAt`; any fetch (loop, wake or
/// user) pushes `nextDueAt` forward, so manual refreshes never cause a
/// duplicate poll right after. The loop is suspended across system sleep and
/// resumed ~5s after wake, fetching immediately on resume.
///
/// App Nap: we hold a `.userInitiatedAllowingIdleSystemSleep` activity for the
/// app's lifetime. Otherwise a hidden menu bar app gets napped and the 5-minute
/// timer can drift by many minutes. The cost is one small HTTPS request every
/// 5 minutes; idle system sleep is still allowed.
@MainActor @Observable
final class UsageModel {
    private(set) var snapshot: UsageSnapshot?
    private(set) var status: UsageStatus = .idle

    // MARK: Tuning
    private static let baseInterval: TimeInterval = 300
    private static let maxBackoff: TimeInterval = 1800
    private static let maxRetryAfter: TimeInterval = 3600
    /// Re-check the Keychain sooner when there's no usable token (no API call is made).
    private static let credentialRecheckInterval: TimeInterval = 60
    private static let userRefreshThrottle: TimeInterval = 60
    private static let wakeDelay: Duration = .seconds(5)

    // MARK: State (not observed)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var lastAttemptAt: Date?
    @ObservationIgnored private var nextDueAt = Date.distantPast
    @ObservationIgnored private var rateLimitedUntil: Date?
    @ObservationIgnored private var consecutiveRateLimits = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    init() {}

    /// Begins polling. Idempotent.
    func start() {
        guard !started else { return }
        started = true

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Polling Claude usage limits"
        )

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        })

        startLoop()
    }

    /// Fetches now unless a fetch is in flight, we're inside a 429 backoff, or
    /// (for user-initiated calls) the last attempt was under 60s ago.
    func refresh(userInitiated: Bool) async {
        guard !isFetching else { return }
        let now = Date()
        if userInitiated, let last = lastAttemptAt, now.timeIntervalSince(last) < Self.userRefreshThrottle { return }
        if let until = rateLimitedUntil, until > now { return }
        await performFetch()
    }

    // MARK: - Loop

    private func startLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.tick() else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Fetches if due; returns seconds to sleep before the next check.
    private func tick() async -> TimeInterval {
        if Date() >= nextDueAt, !isFetching {
            await performFetch()
        }
        // If a fetch was in flight elsewhere, nextDueAt may still be in the past; re-check shortly.
        return max(1, nextDueAt.timeIntervalSinceNow)
    }

    private func handleWillSleep() {
        wakeTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
    }

    private func handleDidWake() {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: UsageModel.wakeDelay)
            guard !Task.isCancelled, let self else { return }
            // Refresh on wake (respecting any rate-limit backoff), then resume polling.
            if self.rateLimitedUntil.map({ $0 <= Date() }) ?? true {
                self.nextDueAt = .distantPast
            }
            self.startLoop()
        }
    }

    // MARK: - Fetch

    private func performFetch() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let now = Date()
        lastAttemptAt = now
        // Provisional schedule so concurrent callers don't pile up; replaced below.
        nextDueAt = now.addingTimeInterval(Self.baseInterval)
        if snapshot == nil { status = .loading }

        do {
            // Read fresh every time: picks up tokens Claude Code has refreshed.
            let credentials = try await Credentials.load()
            guard !credentials.isExpired() else { throw UsageAPIError.tokenExpired }
            let result = try await UsageAPI.fetch(token: credentials.accessToken)
            snapshot = result
            status = .ok
            consecutiveRateLimits = 0
            rateLimitedUntil = nil
            nextDueAt = Date().addingTimeInterval(Self.baseInterval)
        } catch let error as UsageAPIError {
            handle(error)
        } catch {
            handle(.network(error.localizedDescription))
        }
    }

    private func handle(_ error: UsageAPIError) {
        let now = Date()
        let message: String
        switch error {
        case .rateLimited(let retryAfter):
            consecutiveRateLimits += 1
            let exponential = min(Self.maxBackoff, Self.baseInterval * pow(2, Double(consecutiveRateLimits - 1)))
            let delay = max(min(retryAfter ?? 0, Self.maxRetryAfter), exponential)
            let until = now.addingTimeInterval(delay)
            rateLimitedUntil = until
            nextDueAt = until
            message = "Rate limited — retrying in \(Self.formatMinutes(delay))"
        case .notLoggedIn, .keychainUnavailable, .unreadableCredentials, .tokenExpired:
            // No usable token and no API call was made: re-check the Keychain sooner to recover quickly.
            nextDueAt = now.addingTimeInterval(Self.credentialRecheckInterval)
            message = error.userMessage
        case .unauthorized, .http, .network, .decoding:
            nextDueAt = now.addingTimeInterval(Self.baseInterval)
            message = error.userMessage
        }
        status = snapshot == nil ? .error(message) : .stale(message)
    }

    private static func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(1, minutes))m"
    }
}
