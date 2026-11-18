import Foundation

// The injected runner and storage never contact a live Orca or the user's defaults.
enum OrcaCommandRunner {
    static func run(_ arguments: [String]) -> Data? { preconditionFailure("No real CLI in acknowledgement tests") }
}

@main
@MainActor
enum IslandAcknowledgementTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func event(_ state: String, time: Double, turn: Double,
                      host: String = "local", pane: String = "tab:leaf", type: String = "orca.snapshot") -> IslandEvent {
        var event = IslandEvent(type: type, workspaceId: "/project", paneKey: pane,
            state: state, combinedState: state, mainAgent: nil, receivedAt: time,
            terminalTitle: "Conversation", terminalId: "term_opaque:real", hostId: host,
            tabId: "tab", leafId: "leaf", stateStartedAt: turn)
        if host.hasPrefix("runtime:") { event.environmentId = String(host.dropFirst("runtime:".count)) }
        return event
    }

    static func only(_ store: IslandStore) -> AgentSession { store.sessions.values.first! }

    static func main() {
        persistentTurnAcknowledgements()
        independentHostsAndBulkRead()
        navigationRevalidation()
        publicRouteDegradation()
        print("Island acknowledgement and public terminal routing passed (\(checks) assertions); isolated storage and CLI fixtures only.")
    }

    static func persistentTurnAcknowledgements() {
        let memory = MemoryIslandAcknowledgementStorage()
        let store = IslandStore(acknowledgementStorage: memory)
        store.replaceFromPoll([event("done", time: 200, turn: 180)])
        expect(!store.expanded, "Bootstrapped done stays historical")
        let read = only(store)
        store.markAsRead(read)
        expect(store.sessions.isEmpty && store.recentCompletionID == nil, "An explicit read hides this Island row")
        expect(memory.load()[read.id] == 180, "Ledger stores the completed source turn, not desktop receipt time")
        store.replaceFromPoll([event("done", time: 500, turn: 180)], livePaneKeys: [read.id])
        expect(store.sessions.isEmpty, "New receipt evidence for the acknowledged turn cannot resurrect it")
        let ping = event("done", time: 600, turn: 180, type: "orca.agent.status")
        expect(store.ingest(ping) && store.sessions.isEmpty, "A duplicate local bridge ping also stays hidden")

        let restarted = IslandStore(acknowledgementStorage: memory)
        restarted.replaceFromPoll([event("done", time: 700, turn: 180)])
        expect(restarted.sessions.isEmpty, "A new store instance honors persisted completed-turn identity")
        restarted.replaceFromPoll([event("done", time: 900, turn: 880)])
        expect(only(restarted).stateStartedAt == 880, "A later completed source turn reappears even if working was missed")
        expect(!restarted.expanded, "A newly observed completed turn is not fabricated working-to-done")
        restarted.markAsRead(read)
        expect(restarted.sessions.count == 1, "A stale clicked row cannot mark a newer completion read")
        restarted.markAsRead(only(restarted))
        restarted.replaceFromPoll([event("working", time: 100, turn: 90)])
        expect(restarted.sessions.isEmpty, "Old working history cannot roll back a retained acknowledged completion")
        restarted.replaceFromPoll([event("working", time: 1000, turn: 990)])
        expect(only(restarted).state == "working", "Genuinely new working evidence becomes visible")
        restarted.replaceFromPoll([event("done", time: 1100, turn: 1090)])
        expect(restarted.expanded, "A later working-to-done transition still opens Island")
        restarted.markAsRead(only(restarted))
        expect(restarted.recentCompletionID == nil, "Reading a highlighted completion clears the highlight")

        let untouchedDefault = IslandStore()
        untouchedDefault.replaceFromPoll([event("done", time: 200, turn: 180)])
        expect(untouchedDefault.sessions.count == 1, "Default test stores use independent memory, not user preferences")

        let suite = "dev.orca.island.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let durable = UserDefaultsIslandAcknowledgementStorage(defaults: defaults)
        let first = IslandStore(acknowledgementStorage: durable)
        first.replaceFromPoll([event("done", time: 200, turn: 180)])
        first.markAsRead(only(first))
        let second = IslandStore(acknowledgementStorage: UserDefaultsIslandAcknowledgementStorage(defaults: defaults))
        second.replaceFromPoll([event("done", time: 300, turn: 180)])
        expect(second.sessions.isEmpty, "UserDefaults-backed storage survives reconstruction")
        expect(defaults.dictionaryRepresentation().keys.contains(durable.key), "Persistence uses an Island-owned key")
    }

    static func independentHostsAndBulkRead() {
        let store = IslandStore()
        store.replaceFromPoll([event("done", time: 200, turn: 180),
            event("done", time: 200, turn: 180, host: "runtime:remote"),
            event("working", time: 200, turn: 180, pane: "other:leaf")])
        let local = store.sessions.values.first { $0.hostId == "local" && $0.state == "done" }!
        store.markAsRead(local)
        expect(store.completedCount == 1 && store.sessions.count == 2, "Equal pane and source turn on another host remain unread")
        store.markAllCompletedAsRead()
        expect(store.sessions.count == 1 && only(store).state == "working", "Clear completed never removes active work")
        let remotePing = event("done", time: 9_999_999, turn: 900, host: "runtime:remote", type: "orca.agent.status")
        expect(!store.ingest(remotePing) && store.sessions.count == 1,
               "Explicit remote bridge events are refresh hints, never desktop/source clock comparisons")
        store.replaceFromPoll([event("done", time: 300, turn: 280, host: "runtime:remote")])
        expect(store.sessions.count == 1 && only(store).hostId == "runtime:remote", "A remote public snapshot owns the next completed turn")
        let localOnly = IslandStore()
        localOnly.replaceFromPoll([event("working", time: 100, turn: 90)])
        var unknown = event("done", time: 9_999_999, turn: 900, type: "orca.agent.status")
        unknown.hostId = nil; unknown.workspaceListId = "identity:wt2:unmatched-remote"
        expect(!localOnly.ingest(unknown) && only(localOnly).state == "working" && !localOnly.expanded,
               "An unmatched hostless hook cannot borrow a uniquely visible local pane or raw workspace")
        let newlyObserved = IslandStore()
        _ = newlyObserved.ingest(event("working", time: 100, turn: 90,
                                      type: "orca.agent.status"), arrivedAt: Date(timeIntervalSince1970: 1))
        newlyObserved.replaceFromPoll([], snapshotStartedAt: Date(timeIntervalSince1970: 2),
                                      livePaneKeys: [], unavailableHostIDs: ["local"])
        expect(newlyObserved.sessions.count == 1 && only(newlyObserved).isStale && !only(newlyObserved).canNavigate,
               "A failed host retains post-last-inventory bridge rows as stale even when received before this poll")
    }

    static func data(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    static func navigationRevalidation() {
        let store = IslandStore()
        store.replaceFromPoll([event("working", time: 100, turn: 90, host: "runtime:remote")])
        let session = only(store)
        let row: [String: Any] = ["tabId": "tab", "leafId": "leaf", "worktreeId": "/project",
            "executionHostId": "local", "handle": "term_opaque:real", "connected": true, "orphaned": false]
        func listing(_ rows: [[String: Any]], ok: Bool = true, truncated: Bool = false,
                     hosts: [String] = ["local"], omitted: [String] = []) -> Data {
            data(["ok": ok, "result": ["terminals": rows, "truncated": truncated,
                "hostScope": ["hostIds": hosts, "omittedHostIds": omitted]]])
        }
        var calls: [[String]] = []
        func navigate(_ candidate: AgentSession = session, response: Data? = nil, switchOK: Bool = true) -> Bool {
            calls = []
            return TerminalSwitcher.navigate(candidate) { arguments in
                calls.append(arguments)
                return calls.count == 1 ? (response ?? listing([row])) : data(["ok": switchOK, "result": ["navigated": switchOK]])
            }
        }
        expect(navigate(), "A fresh exact remote terminal can be switched through the public CLI")
        expect(calls == [["terminal", "list", "--limit", "10000", "--environment", "remote", "--json"],
                         ["terminal", "switch", "--terminal", "term_opaque:real", "--environment", "remote", "--json"]],
               "The opaque handle is preserved and both commands explicitly bind the same execution host")
        expect(!navigate(response: listing([row, row])) && calls.count == 1, "Ambiguity never selects the first row")
        expect(!navigate(response: listing([], truncated: false)) && calls.count == 1, "A disappeared terminal never triggers switch")
        expect(!navigate(response: listing([row], truncated: true)) && calls.count == 1, "Truncated inventory is refused")
        expect(!navigate(response: listing([row], ok: false)) && calls.count == 1, "A failed JSON envelope is refused")
        expect(!navigate(response: listing([row], hosts: [])) && calls.count == 1, "Missing selected-host coverage is refused")
        expect(!navigate(response: listing([row], omitted: ["local"])) && calls.count == 1, "An omitted selected host is refused")
        var other = row; other["worktreeId"] = "/other"
        expect(!navigate(response: listing([other])) && calls.count == 1, "Workspace equality is required")
        other = row; other["executionHostId"] = "ssh:nested"
        expect(!navigate(response: listing([other])) && calls.count == 1, "Nested host rows are not relabeled as the selected host")
        other = row; other.removeValue(forKey: "executionHostId")
        expect(!navigate(response: listing([other])) && calls.count == 1, "Missing per-row execution host evidence cannot enable a route")
        other = row; other["handle"] = "term_reused"
        expect(!navigate(response: listing([other])) && calls.count == 1, "A reused pane with a different PTY is refused")
        other = row; other["connected"] = false
        expect(!navigate(response: listing([other])) && calls.count == 1, "Disconnected terminals cannot be navigated")
        other = row; other.removeValue(forKey: "connected")
        expect(!navigate(response: listing([other])) && calls.count == 1, "Missing live-connection evidence is refused")
        expect(!navigate(switchOK: false), "Refused desktop navigation is surfaced as failure")
        var routed = session; routed.workspaceListId = "identity:wt2:opaque-host-api-token"
        expect(navigate(routed, response: listing([row])), "HostAPI workspace tokens never replace raw CLI worktree identity")
    }

    static func publicRouteDegradation() {
        let store = IslandStore()
        store.replaceFromPoll([event("done", time: 100, turn: 90)])
        var session = only(store)
        expect(session.canNavigate, "A live terminal exposes navigation")
        session.isStale = true
        expect(!session.canNavigate && session.navigationUnavailableReason != nil, "Offline rows explicitly disable navigation")
        session.isStale = false; session.terminalId = nil
        expect(!session.canNavigate, "Sleeping or closed terminals never fall back to resume")
        session.terminalId = "term_chat"; session.structuredSessionId = "chat_session"
        expect(!session.canNavigate, "Native chats are display-only without a public exact reveal route")
        session.structuredSessionId = nil; session.hostId = "runtime:remote"; session.environmentId = "other"
        expect(!session.canNavigate, "A mismatched explicit host/environment pair is refused")
        var commands = 0
        expect(!TerminalSwitcher.navigate(session, run: { _ in commands += 1; return nil }) && commands == 0,
               "An unsupported session executes no CLI command")
        var official = event("working", time: 110, turn: 105, type: "orca.agent.status")
        official.terminalId = "opaque-host-api-terminal-token"
        _ = store.ingest(official)
        expect(only(store).terminalId == "term_opaque:real", "Opaque official terminal tokens never overwrite a public CLI handle")
        let fresh = IslandStore()
        expect(fresh.ingest(official) && only(fresh).terminalId == nil && !only(fresh).canNavigate,
               "An official hook alone cannot create a CLI route before public reconciliation")
        var sleeping = event("done", time: 120, turn: 115); sleeping.terminalId = nil
        sleeping.tabId = nil; sleeping.leafId = nil
        store.replaceFromPoll([sleeping])
        expect(!only(store).canNavigate, "Authoritative absence clears a previously cached live terminal handle")
        expect(only(store).tabId == nil && only(store).leafId == nil, "Authoritative absence clears stale tab and leaf metadata too")
        store.markAsRead(only(store))
        expect(store.sessions.isEmpty, "Unavailable completed rows can still be marked read")
    }
}
