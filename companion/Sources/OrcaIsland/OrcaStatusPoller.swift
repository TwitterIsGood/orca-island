import Foundation

struct OrcaPollSnapshot {
    let events: [IslandEvent]
    let livePaneKeys: Set<String>
    let startedAt: Date
    let mode: SyncTransportMode
    let pollCount: Int
    let unavailableHostIDs: Set<String>

    init(events: [IslandEvent], livePaneKeys: Set<String>, startedAt: Date,
         mode: SyncTransportMode = .compatibility, pollCount: Int = 0,
         unavailableHostIDs: Set<String> = []) {
        self.events = events
        self.livePaneKeys = livePaneKeys
        self.startedAt = startedAt
        self.mode = mode
        self.pollCount = pollCount
        self.unavailableHostIDs = unavailableHostIDs
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
        let reader = OrcaSnapshotReader()
        self.readSnapshot = readSnapshot ?? { reader.read(startedAt: $0) }
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
                self.schedule.finishPoll(at: self.clock(), succeeded: snapshot != nil && snapshot!.unavailableHostIDs.isEmpty)
                let annotated = snapshot.map {
                    OrcaPollSnapshot(events: $0.events, livePaneKeys: $0.livePaneKeys,
                                     startedAt: $0.startedAt, mode: self.schedule.mode,
                                     pollCount: self.schedule.pollCount, unavailableHostIDs: $0.unavailableHostIDs)
                }
                self.deliver(generation: deliveryToken) { [onEvents = self.onEvents] in
                    onEvents(annotated)
                }
                self.scheduleNextPoll()
            }
        }
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
