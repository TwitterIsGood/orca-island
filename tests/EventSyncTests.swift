import Foundation

// This harness injects its reader and never invokes a real Orca CLI or service.
struct MainAgentPayload {
    let state: String
    let stateStartedAt: Double?
}

struct IslandEvent {
    let type: String?
    let workspaceId: String?
    let paneKey: String?
    let state: String?
    let combinedState: String?
    let mainAgent: MainAgentPayload?
    let receivedAt: Double?
    let terminalTitle: String?
}

enum OrcaCommandRunner {
    static func run(_ arguments: [String]) -> Data? {
        preconditionFailure("Live CLI access is prohibited in scheduler tests")
    }
}

final class OrcaSnapshotReader {
    func read(startedAt: Date) -> OrcaPollSnapshot? {
        preconditionFailure("The schedule harness must inject its reader")
    }
}

@main
enum EventSyncTests {
    static var checks = 0

    static func main() {
        testCompatibilityAndConfirmation()
        testRefreshDebounce()
        testFailureRecovery()
        testStopAndWakeup()
        testInjectedReader()
        testStopDuringRead()
        print("Event sync checks passed (\(checks) assertions); virtual time, no live Orca actions.")
    }

    static func testCompatibilityAndConfirmation() {
        var schedule = PollSchedule()
        expect(schedule.nextPollAt == nil, "An unstarted poller schedules no work")
        schedule.start(at: 100)
        expect(schedule.nextPollAt == 100, "Startup reads the complete inventory immediately")
        schedule.start(at: 101)
        expect(schedule.nextPollAt == 100, "Repeated start does not delay the first poll")
        expect(schedule.beginPoll(at: 100), "The initial read can begin")
        expect(!schedule.beginPoll(at: 100), "Only one read can be in flight")
        schedule.finishPoll(at: 100.1, succeeded: true)
        expect(near(schedule.nextPollAt, 102.1), "An unconfirmed bridge retains the two-second compatibility cadence")
        expect(schedule.confirmBridge(at: 101), "The first valid bridge event confirms event transport")
        expect(schedule.mode == .event && schedule.nextPollAt == 101, "Bridge confirmation requests immediate calibration")
        expect(schedule.beginPoll(at: 101), "Confirmation calibration can begin immediately")
        schedule.finishPoll(at: 101.1, succeeded: true)
        expect(near(schedule.nextPollAt, 146.1), "Confirmed transport calibrates after 45 seconds")
        expect(!schedule.confirmBridge(at: 110), "Subsequent bridge events do not reconfirm the transport")
        expect(near(schedule.nextPollAt, 146.1), "Ordinary status messages do not trigger full inventory reads")
        expect(schedule.beginPoll(at: 146.1), "A quiet bridge still gets a calibration")
        schedule.finishPoll(at: 146.2, succeeded: true)
        expect(schedule.mode == .event && near(schedule.nextPollAt, 191.2), "Silence does not revert to high-frequency polling")
        expect(schedule.pollCount == 3, "Diagnostics count only actual inventory attempts")
    }

    static func testRefreshDebounce() {
        var schedule = calibratedSchedule()
        schedule.requestRefresh(at: 10)
        expect(near(schedule.nextPollAt, 10.3), "Unknown panes schedule metadata refresh after 300 ms")
        schedule.requestRefresh(at: 10.2)
        expect(near(schedule.nextPollAt, 10.5), "A burst is combined on its trailing edge")
        for index in 3...9 { schedule.requestRefresh(at: 10 + Double(index) / 10) }
        expect(schedule.nextPollAt == 11, "A continuous event stream cannot starve refresh beyond one second")
        expect(!schedule.beginPoll(at: 10.99), "A debounced refresh does not begin early")
        expect(schedule.beginPoll(at: 11), "A coalesced refresh runs once")
        schedule.finishPoll(at: 11.1, succeeded: true)
        schedule.requestRefresh(at: 11.15)
        expect(schedule.nextPollAt == 13, "Repeated unknown-pane bursts cannot launch a CLI per event")
        schedule.requestRefresh(at: 11.2, immediate: true)
        schedule.requestRefresh(at: 11.21)
        expect(schedule.nextPollAt == 11.2, "Immediate refresh bypasses cooldown and cannot be delayed by an ordinary event")
        expect(schedule.beginPoll(at: 11.21), "An explicit reconnect can read immediately")
        schedule.requestRefresh(at: 11.22, immediate: true)
        expect(schedule.nextPollAt == nil, "Events received during a read cannot overlap it")
        schedule.finishPoll(at: 11.3, succeeded: true)
        expect(schedule.nextPollAt == 11.22, "Changes during the read request one subsequent inventory")
    }

    static func testFailureRecovery() {
        var schedule = calibratedSchedule()
        schedule.requestRefresh(at: 2, immediate: true)
        expect(schedule.beginPoll(at: 2), "A requested event-mode inventory starts")
        schedule.finishPoll(at: 2.1, succeeded: false)
        expect(near(schedule.nextPollAt, 7.1), "A failed read retries after five seconds")
        expect(schedule.mode == .event, "A read failure cannot imply the confirmed event transport disappeared")
        schedule.requestRefresh(at: 3)
        expect(near(schedule.nextPollAt, 7.1), "Event bursts cannot bypass failure backoff")
        expect(!schedule.beginPoll(at: 7), "Recovery does not execute before the backoff")
        expect(schedule.beginPoll(at: 7.1), "Recovery retries after the backoff")
        schedule.finishPoll(at: 7.2, succeeded: true)
        expect(near(schedule.nextPollAt, 52.2), "A successful recovery restores event-mode cadence")

        var compatibility = PollSchedule()
        compatibility.start(at: 0)
        _ = compatibility.beginPoll(at: 0)
        compatibility.finishPoll(at: 0.1, succeeded: false)
        _ = compatibility.beginPoll(at: 5.1)
        compatibility.finishPoll(at: 5.2, succeeded: true)
        expect(near(compatibility.nextPollAt, 7.2), "An unconfirmed bridge recovers to compatibility cadence")
    }

    static func testStopAndWakeup() {
        var schedule = calibratedSchedule()
        schedule.requestRefresh(at: 3)
        schedule.stop()
        expect(schedule.nextPollAt == nil, "Stop cancels a pending debounce and cadence")
        schedule.requestRefresh(at: 100, immediate: true)
        schedule.finishPoll(at: 100, succeeded: true)
        expect(schedule.nextPollAt == nil, "Late reads and wake notifications cannot restart a stopped poller")
        schedule.start(at: 101)
        expect(schedule.nextPollAt == 101, "An explicit restart requests a new complete inventory")
        _ = schedule.beginPoll(at: 101)
        schedule.finishPoll(at: 101.1, succeeded: false)
        schedule.requestRefresh(at: 102, immediate: true)
        expect(schedule.nextPollAt == 102, "Wake/reconnect bypasses a previously scheduled failure retry")
        _ = schedule.beginPoll(at: 102)
        schedule.finishPoll(at: 102.1, succeeded: true)
        schedule.requestRefresh(at: 500, immediate: true)
        expect(schedule.beginPoll(at: 500), "Wake after long sleep requests immediate calibration")
        expect(!schedule.beginPoll(at: 500), "Missed sleep-time ticks do not produce overlapping reads")
    }

    static func testInjectedReader() {
        var snapshots: [OrcaPollSnapshot] = []
        var modeChanges: [SyncTransportMode] = []
        let poller = OrcaStatusPoller(onEvents: { snapshot in
            expect(Thread.isMainThread, "Snapshots are delivered on the main thread")
            if let snapshot { snapshots.append(snapshot) }
        }, onModeChange: { mode in
            expect(Thread.isMainThread, "Mode changes are delivered on the main thread")
            modeChanges.append(mode)
        }, readSnapshot: { startedAt in
            OrcaPollSnapshot(events: [], livePaneKeys: ["fixture:one"], startedAt: startedAt)
        })
        poller.start()
        pumpUntil { snapshots.count == 1 }
        expect(snapshots[0].mode == .compatibility && snapshots[0].pollCount == 1, "The injected startup read has compatibility diagnostics")
        poller.confirmBridge()
        poller.confirmBridge()
        pumpUntil { snapshots.count == 2 && modeChanges.count == 1 }
        expect(snapshots[1].mode == .event && snapshots[1].pollCount == 2, "A single confirmation read publishes event diagnostics")
        expect(snapshots[1].livePaneKeys == ["fixture:one"], "The scheduler preserves inventory data")
        poller.requestRefresh(immediate: true)
        pumpUntil { snapshots.count == 3 }
        expect(snapshots[2].pollCount == 3, "An injected reconnect requests a fresh read")
        poller.stop()
    }

    static func testStopDuringRead() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        var deliveries = 0
        let poller = OrcaStatusPoller(onEvents: { _ in deliveries += 1 }, readSnapshot: { startedAt in
            entered.signal()
            precondition(release.wait(timeout: .now() + 2) == .success)
            exited.signal()
            return OrcaPollSnapshot(events: [], livePaneKeys: [], startedAt: startedAt)
        })
        poller.start()
        expect(entered.wait(timeout: .now() + 1) == .success, "The injected blocking read starts")
        poller.requestRefresh(immediate: true)
        poller.stop()
        release.signal()
        expect(exited.wait(timeout: .now() + 1) == .success, "The in-flight read can finish after stop")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(deliveries == 0, "Stop suppresses the in-flight result and pending follow-up")
    }

    static func calibratedSchedule() -> PollSchedule {
        var schedule = PollSchedule()
        schedule.start(at: 0)
        _ = schedule.confirmBridge(at: 0)
        _ = schedule.beginPoll(at: 0)
        schedule.finishPoll(at: 0.1, succeeded: true)
        return schedule
    }

    static func near(_ actual: TimeInterval?, _ expected: TimeInterval) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 0.00001
    }

    static func pumpUntil(_ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !ready(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        expect(ready(), "The asynchronous reader delivered its expected result")
    }

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
}
