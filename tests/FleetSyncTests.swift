import Foundation

enum OrcaCommandRunner {
    static func runHelper(_ arguments: [String]) -> Data? { preconditionFailure("No live runtime in fixtures") }
}

@main
@MainActor
enum FleetSyncTests {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func event(_ state: String, host: String = "local", time: Double = 1000,
                      hidden: Bool = false, type: String = "orca.snapshot") -> IslandEvent {
        var e = IslandEvent(type: type, workspaceId: "/project", paneKey: "tab:leaf",
                            state: state, combinedState: state, mainAgent: nil, receivedAt: time,
                            terminalTitle: "Conversation")
        e.hostId = host; e.isHidden = hidden; e.isStale = false
        return e
    }
    static func main() {
        let store = IslandStore()
        store.replaceFromPoll([event("working"), event("working", host: "runtime:remote")])
        expect(store.sessions.count == 2 && store.workspaceGroups.count == 2, "Same pane/workspace on two hosts remains separate")
        var plugin = event("done", time: 2000, type: "orca.agent.status"); plugin.hostId = nil
        expect(!store.ingest(plugin), "An ambiguous hostless event requests reconciliation")
        expect(store.sessions.values.allSatisfy { $0.state == "working" }, "Ambiguous event alters neither host")

        let remoteOnly = IslandStore()
        remoteOnly.replaceFromPoll([event("working", host: "runtime:remote")])
        expect(!remoteOnly.ingest(plugin), "Remote clock is reconciled instead of comparing desktop receipt")
        expect(remoteOnly.sessions.count == 1, "No phantom local row is created for remote event")

        let ack = IslandStore()
        ack.replaceFromPoll([event("done", time: 2000)])
        ack.replaceFromPoll([event("idle", time: 2000, hidden: true)], livePaneKeys: ["tab:leaf"])
        expect(ack.sessions.isEmpty, "Explicit acknowledgment cannot be undone by broad live-pane retention")
        plugin = event("done", time: 3000, type: "orca.agent.status"); plugin.hostId = nil
        expect(ack.ingest(plugin) && ack.sessions.isEmpty, "Repeated done after ack stays hidden")
        plugin = event("working", time: 1000, type: "orca.agent.status"); plugin.hostId = nil
        _ = ack.ingest(plugin)
        expect(ack.sessions.isEmpty, "An old working event cannot revive acknowledged history")
        plugin = event("working", time: 4000, type: "orca.agent.status"); plugin.hostId = nil; _ = ack.ingest(plugin)
        expect(ack.sessions.values.first?.state == "working", "A genuinely later working event starts a new turn")
        ack.replaceFromPoll([event("done", time: 3000)])
        expect(ack.sessions.values.first?.state == "working", "Older snapshot cannot finish new work")
        ack.replaceFromPoll([event("done", time: 5000)])
        ack.replaceFromPoll([event("idle", time: 5000)])
        expect(ack.sessions.values.first?.state == "idle", "Same agent timestamp can receive a fresh read/idle projection")
        ack.replaceFromPoll([event("idle", time: 5000, hidden: true)])
        ack.replaceFromPoll([event("done", time: 7000)])
        expect(ack.sessions.values.first?.state == "done", "Authoritative snapshot restores a new done even if its working event was missed")

        let reader = OrcaSnapshotReader()
        let start = Date(timeIntervalSince1970: 1)
        func response(_ local: [IslandEvent], _ remote: [IslandEvent], available: Bool = true) -> OrcaSnapshotReader.Response {
            OrcaSnapshotReader.Response(ok: true, hosts: [
                .init(hostId: "local", available: true, events: local),
                .init(hostId: "runtime:remote", available: available, events: remote)])
        }
        _ = reader.reconcile(response([event("working")], [event("working", host: "runtime:remote")]), startedAt: start)
        let failed = reader.reconcile(response([], [], available: false), startedAt: start)!
        expect(failed.events.count == 1 && failed.events.first?.hostId == "runtime:remote", "Local closed rows disappear while remote failure preserves only remote rows")
        expect(failed.events.first?.isStale == true && failed.unavailableHostIDs == ["runtime:remote"], "Retained remote data is visibly stale")
        let recovered = reader.reconcile(response([], []), startedAt: start)!
        expect(recovered.events.isEmpty && recovered.livePaneKeys.isEmpty, "Only a successful empty remote snapshot confirms removal")
        let cold = OrcaSnapshotReader().reconcile(response([], [], available: false), startedAt: start)!
        expect(!cold.unavailableHostIDs.isEmpty, "A cold-start remote failure is reported even without cached sessions")
        print("Fleet sync passed (\(checks) assertions); anonymous fixtures, no runtime writes.")
    }
}
