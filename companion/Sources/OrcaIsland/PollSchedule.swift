import Foundation

enum SyncTransportMode: String {
    case event
    case compatibility
}

/// Monotonic-time scheduling, kept independent of Dispatch and the Orca CLI.
/// Bridge confirmation is sticky: quiet agents do not imply a broken bridge.
struct PollSchedule {
    private(set) var mode: SyncTransportMode = .compatibility
    private(set) var isRunning = false
    private(set) var isPolling = false
    private(set) var pollCount = 0

    private var regularPollAt: TimeInterval?
    private var refreshAt: TimeInterval?
    private var firstRefreshRequestAt: TimeInterval?
    private var lastRefreshPollAt: TimeInterval?
    private var retryNotBefore: TimeInterval?

    var nextPollAt: TimeInterval? {
        guard isRunning, !isPolling else { return nil }
        guard let due = [regularPollAt, refreshAt].compactMap({ $0 }).min() else { return nil }
        return max(due, retryNotBefore ?? due)
    }

    mutating func start(at now: TimeInterval) {
        guard !isRunning else { return }
        isRunning = true
        regularPollAt = now
    }

    mutating func stop() {
        isRunning = false
        isPolling = false
        regularPollAt = nil
        refreshAt = nil
        firstRefreshRequestAt = nil
        lastRefreshPollAt = nil
        retryNotBefore = nil
    }

    @discardableResult
    mutating func confirmBridge(at now: TimeInterval) -> Bool {
        guard mode != .event else { return false }
        mode = .event
        requestRefresh(at: now, immediate: true)
        return true
    }

    mutating func requestRefresh(at now: TimeInterval, immediate: Bool = false) {
        guard isRunning else { return }
        if immediate {
            firstRefreshRequestAt = now
            refreshAt = now
            retryNotBefore = nil
            return
        }
        // Never postpone an already-requested immediate refresh.
        if let refreshAt, refreshAt <= now { return }
        let firstRequest = firstRefreshRequestAt ?? now
        firstRefreshRequestAt = firstRequest
        let debounced = min(now + 0.3, firstRequest + 1)
        // Unknown panes may generate many status messages while their metadata
        // is unavailable. Such a stream cannot launch one CLI per message.
        refreshAt = max(debounced, lastRefreshPollAt.map { $0 + 2 } ?? debounced)
    }

    @discardableResult
    mutating func beginPoll(at now: TimeInterval) -> Bool {
        guard let due = nextPollAt, due <= now else { return false }
        isPolling = true
        pollCount += 1
        if refreshAt != nil { lastRefreshPollAt = now }
        regularPollAt = nil
        refreshAt = nil
        firstRefreshRequestAt = nil
        retryNotBefore = nil
        return true
    }

    mutating func finishPoll(at now: TimeInterval, succeeded: Bool) {
        guard isRunning, isPolling else { return }
        isPolling = false
        if succeeded {
            regularPollAt = now + (mode == .event ? 45 : 2)
            retryNotBefore = nil
        } else {
            regularPollAt = now + 5
            retryNotBefore = now + 5
        }
    }
}
