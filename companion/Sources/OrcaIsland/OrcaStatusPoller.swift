import Foundation

struct OrcaPollSnapshot {
    let events: [IslandEvent]
    let livePaneKeys: Set<String>
    let startedAt: Date
    let mode: SyncTransportMode
    let pollCount: Int

    init(events: [IslandEvent], livePaneKeys: Set<String>, startedAt: Date,
         mode: SyncTransportMode = .compatibility, pollCount: Int = 0) {
        self.events = events
        self.livePaneKeys = livePaneKeys
        self.startedAt = startedAt
        self.mode = mode
        self.pollCount = pollCount
    }
}

final class OrcaStatusPoller {
    private let queue = DispatchQueue(label: "com.orca-island.poller")
    private let readerQueue = DispatchQueue(label: "com.orca-island.poller.reader")
    private let onEvents: (OrcaPollSnapshot?) -> Void
    private let onModeChange: ((SyncTransportMode) -> Void)?
    private let clock: () -> TimeInterval
    private let readSnapshot: (Date) -> OrcaPollSnapshot?
    private var schedule = PollSchedule()
    private var pendingPoll: DispatchWorkItem?
    private var generation = 0
    // Callbacks execute on main; the lock only guards their cancellation token.
    private let deliveryLock = NSLock()
    private var deliveryGeneration = 0

    init(onEvents: @escaping (OrcaPollSnapshot?) -> Void,
         onModeChange: ((SyncTransportMode) -> Void)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         readSnapshot: ((Date) -> OrcaPollSnapshot?)? = nil) {
        self.onEvents = onEvents
        self.onModeChange = onModeChange
        self.clock = clock
        self.readSnapshot = readSnapshot ?? Self.readOrcaSnapshot
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.schedule.isRunning else { return }
            self.schedule.start(at: self.clock())
            self.scheduleNextPoll()
        }
    }

    func stop() {
        deliveryLock.lock()
        deliveryGeneration += 1
        deliveryLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.pendingPoll?.cancel()
            self.pendingPoll = nil
            self.schedule.stop()
        }
    }

    func confirmBridge() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.schedule.confirmBridge(at: self.clock()) {
                let token = self.currentDeliveryGeneration()
                self.deliver(generation: token) { [weak self] in self?.onModeChange?(.event) }
            }
            self.scheduleNextPoll()
        }
    }

    func requestRefresh(immediate: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            self.schedule.requestRefresh(at: self.clock(), immediate: immediate)
            self.scheduleNextPoll()
        }
    }

    private func scheduleNextPoll() {
        pendingPoll?.cancel()
        pendingPoll = nil
        guard let due = schedule.nextPollAt else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pollIfDue()
        }
        pendingPoll = work
        queue.asyncAfter(deadline: .now() + max(0, due - clock()), execute: work)
    }

    private func pollIfDue() {
        guard schedule.beginPoll(at: clock()) else {
            scheduleNextPoll()
            return
        }
        pendingPoll = nil
        let token = generation
        let deliveryToken = currentDeliveryGeneration()
        let startedAt = Date()
        // The scheduler remains responsive during a bounded CLI read. Only one
        // read is in flight; the dedicated reader queue also serializes restarts.
        readerQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.readSnapshot(startedAt)
            self.queue.async { [weak self] in
                guard let self, self.generation == token, self.schedule.isRunning else { return }
                self.schedule.finishPoll(at: self.clock(), succeeded: snapshot != nil)
                let annotated = snapshot.map {
                    OrcaPollSnapshot(events: $0.events, livePaneKeys: $0.livePaneKeys,
                                     startedAt: $0.startedAt, mode: self.schedule.mode,
                                     pollCount: self.schedule.pollCount)
                }
                self.deliver(generation: deliveryToken) { [onEvents = self.onEvents] in
                    onEvents(annotated)
                }
                self.scheduleNextPoll()
            }
        }
    }

    private static func readOrcaSnapshot(startedAt: Date) -> OrcaPollSnapshot? {
        guard let terminalData = OrcaCommandRunner.run(["terminal", "list", "--json"]),
              let terminalObject = try? JSONSerialization.jsonObject(with: terminalData) as? [String: Any],
              terminalObject["ok"] as? Bool == true,
              let result = terminalObject["result"] as? [String: Any],
              let terminals = result["terminals"] as? [[String: Any]] else {
            return nil
        }

        var terminalByPane: [String: [String: Any]] = [:]
        for terminal in terminals {
            guard terminal["orphaned"] as? Bool != true,
                  terminal["connected"] as? Bool != false else { continue }
            guard let tabId = terminal["tabId"] as? String,
                  let leafId = terminal["leafId"] as? String else { continue }
            terminalByPane["\(tabId):\(leafId)"] = terminal
        }
        let statusURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/orca/agent-hooks/last-status.json")
        guard let statusData = try? Data(contentsOf: statusURL),
              let statusObject = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
              let entries = statusObject["entries"] as? [String: [String: Any]] else {
            return nil
        }

        let events = entries.compactMap { _, entry -> IslandEvent? in
            guard let paneKey = entry["paneKey"] as? String,
                  let terminal = terminalByPane[paneKey],
                  let payload = entry["payload"] as? [String: Any],
                  let state = payload["state"] as? String else { return nil }

            let mainAgent: MainAgentPayload?
            if let rawMain = payload["mainAgent"] as? [String: Any],
               let mainState = rawMain["state"] as? String {
                mainAgent = MainAgentPayload(
                    state: mainState,
                    stateStartedAt: rawMain["stateStartedAt"] as? Double
                )
            } else {
                mainAgent = nil
            }

            let title = [terminal["paneTitle"], terminal["title"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return IslandEvent(
                type: "orca.poll",
                workspaceId: entry["worktreeId"] as? String,
                paneKey: paneKey,
                state: state,
                combinedState: state,
                mainAgent: mainAgent,
                receivedAt: entry["receivedAt"] as? Double,
                terminalTitle: title
            )
        }

        return OrcaPollSnapshot(events: events, livePaneKeys: Set(terminalByPane.keys), startedAt: startedAt)
    }

    private func currentDeliveryGeneration() -> Int {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return deliveryGeneration
    }

    private func deliver(generation: Int, _ action: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentDeliveryGeneration() == generation else { return }
            action()
        }
    }
}
