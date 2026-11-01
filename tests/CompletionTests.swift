import Foundation

// Pure store checks: no app, windows, Orca commands, HTTP server, or live polling.
@main
@MainActor
enum CompletionTests {
    private static var checks = 0

    static func main() {
        firstSeenCompletedDoesNotExpand()
        pluginCompletionsOnlyExpandOncePerTurn()
        pollCompletionsRespectEventOrdering()
        aggregateStateWaitsForSubagents()
        metadataKeepsSessionIdentity()
        duplicateSnapshotsAndConcurrentCompletions()
        removedAndWaitingSessionsDoNotMisfire()
        print("Completion store checks passed (\(checks) assertions). No windows or live Orca sessions were used.")
    }

    private static func event(
        _ state: String?, at timestamp: Double, pane: String = "tab:one",
        workspace: String? = "/test/workspace", combined: String? = nil,
        main: String? = nil, title: String? = nil
    ) -> IslandEvent {
        IslandEvent(
            type: "test", workspaceId: workspace, paneKey: pane,
            state: state, combinedState: combined,
            mainAgent: main.map { MainAgentPayload(state: $0, stateStartedAt: nil) },
            receivedAt: timestamp, terminalTitle: title
        )
    }

    private static func session(_ store: IslandStore, pane: String = "tab:one") -> AgentSession {
        guard let session = store.sessions.values.first(where: { $0.paneKey == pane }) else {
            preconditionFailure("Expected session for \(pane)")
        }
        return session
    }

    private static func firstSeenCompletedDoesNotExpand() {
        let plugin = IslandStore()
        plugin.ingest(event("done", at: 10))
        expect(!plugin.expanded && plugin.recentCompletionID == nil, "First plugin done is historical, not a transition")

        let poll = IslandStore()
        poll.replaceFromPoll([event("done", at: 20)])
        expect(!poll.expanded && poll.recentCompletionID == nil, "Initial polling done must not expand")

        let duplicates = IslandStore()
        duplicates.replaceFromPoll([event("working", at: 10), event("done", at: 20)])
        expect(session(duplicates).state == "done", "Duplicate bootstrap records retain the newest status")
        expect(!duplicates.expanded, "Historical duplicates in one initial snapshot must not manufacture a completion")
    }

    private static func pluginCompletionsOnlyExpandOncePerTurn() {
        let store = IslandStore()
        store.ingest(event("working", at: 10))
        expect(!store.expanded, "Starting work does not auto-expand")
        store.ingest(event("done", at: 20))
        expect(store.expanded, "Plugin working to done expands")
        expect(store.recentCompletionID == session(store).id, "The completed row is identified")

        store.expanded = false
        store.ingest(event("done", at: 20))
        store.ingest(event("done", at: 30))
        expect(!store.expanded, "Duplicate or newer unchanged done does not reopen after manual close")
        store.ingest(event("working", at: 40))
        expect(store.recentCompletionID == nil, "A new turn removes the previous completion highlight")
        store.ingest(event("done", at: 50))
        expect(store.expanded, "The next completed turn opens again")
        expect(store.recentCompletionID == session(store).id, "The same row can be highlighted in a later turn")
    }

    private static func pollCompletionsRespectEventOrdering() {
        let store = IslandStore()
        store.ingest(event("working", at: 10))
        store.replaceFromPoll([event("done", at: 20, title: "Current terminal")])
        expect(store.expanded, "Polling can complete a turn first observed by the plugin")
        store.expanded = false
        store.ingest(event("working", at: 15))
        store.replaceFromPoll([event("working", at: 20, title: "Renamed terminal")])
        expect(session(store).state == "done", "Older and equal timestamps cannot roll back a completed state")
        expect(abs(session(store).receivedAt.timeIntervalSince1970 - 0.020) < 0.000001, "Stale events retain the accepted event time")
        expect(session(store).title == "Renamed terminal", "An equal-time poll may still refresh terminal metadata")
        store.ingest(event("done", at: 20))
        store.replaceFromPoll([event("done", at: 20)])
        expect(!store.expanded, "Cross-channel duplicates cannot reopen the island")

        store.ingest(event("working", at: 30))
        store.replaceFromPoll([event("done", at: 20, title: "Poll title")])
        expect(session(store).state == "working", "Old poll completion cannot finish a new plugin turn")
        expect(!store.expanded && store.recentCompletionID == nil, "Stale completion does not alert")
        store.ingest(event("done", at: 30))
        expect(session(store).state == "working" && !store.expanded, "Equal-time conflicting completion is ignored")
        store.ingest(event("done", at: 40))
        expect(store.expanded, "New plugin completion after poll state expands")

        store.expanded = false
        store.replaceFromPoll([event("working", at: 50)])
        store.replaceFromPoll([event("done", at: 60)])
        expect(store.expanded, "Pure polling working to done also expands")
    }

    private static func aggregateStateWaitsForSubagents() {
        let store = IslandStore()
        store.ingest(event("working", at: 10))
        store.ingest(event("working", at: 20, main: "done"))
        expect(session(store).state == "working" && !store.expanded, "A completed main agent must not hide live subagents")
        store.ingest(event("done", at: 30, combined: "working", main: "done"))
        expect(session(store).state == "working" && !store.expanded, "Explicit combined state takes precedence")
        store.ingest(event(nil, at: 40, main: "done"))
        expect(session(store).state == "working" && !store.expanded, "Partial main-agent events cannot replace a known aggregate state")
        store.ingest(event("done", at: 50, combined: "done", main: "done"))
        expect(store.expanded, "Completion waits for the aggregate to become done")
    }

    private static func metadataKeepsSessionIdentity() {
        let store = IslandStore()
        store.ingest(event("working", at: 10, workspace: nil))
        let initialID = session(store).id
        store.replaceFromPoll([event("working", at: 10, workspace: "/test/project", title: "Real title")])
        expect(store.sessions.count == 1 && session(store).id == initialID, "Workspace resolution preserves pane identity")
        expect(session(store).workspaceName == "project" && session(store).title == "Real title", "Polling fills workspace and terminal title")
        store.ingest(event("done", at: 20, workspace: nil))
        expect(store.expanded && store.recentCompletionID == initialID, "Completion matches a pane after its workspace was resolved")
        expect(session(store).workspaceName == "project" && session(store).title == "Real title", "Partial plugin events preserve poll metadata")

        store.expanded = false
        store.replaceFromPoll([event("working", at: 5, workspace: "/test/project", title: "New display title")])
        expect(session(store).state == "done" && !store.expanded, "Metadata refresh does not revive stale state")
        expect(session(store).title == "New display title", "An old status poll can provide a fresh terminal title")
        store.replaceFromPoll([event("done", at: 20, title: "  ")])
        expect(session(store).title == "New display title", "An empty title does not erase a known title")
    }

    private static func duplicateSnapshotsAndConcurrentCompletions() {
        let store = IslandStore()
        store.replaceFromPoll([
            event("working", at: 10),
            event("working", at: 10, pane: "tab:two", workspace: "/test/second")
        ])
        store.replaceFromPoll([
            event("done", at: 30), event("working", at: 20), event("done", at: 30),
            event("working", at: 20, pane: "tab:two", workspace: "/test/second"),
            event("done", at: 40, pane: "tab:two", workspace: "/test/second")
        ])
        expect(store.sessions.count == 2, "Repeated poll keys are merged without a dictionary trap")
        expect(store.sessions.values.allSatisfy { $0.state == "done" }, "Duplicate snapshots retain each pane's newest status")
        expect(store.expanded, "A batch of completions expands the island")
        expect(store.recentCompletionID == session(store, pane: "tab:two").id, "The newest completion is selected deterministically")
        expect(store.workspaceGroups.count == 2, "Completion handling preserves workspace grouping")

        store.expanded = false
        store.replaceFromPoll([
            event("done", at: 30), event("done", at: 30),
            event("done", at: 40, pane: "tab:two", workspace: "/test/second")
        ])
        expect(!store.expanded, "A repeated multi-completion snapshot does not reopen")

        let reversed = IslandStore()
        reversed.replaceFromPoll([event("working", at: 10)])
        reversed.replaceFromPoll([event("working", at: 20), event("done", at: 30)])
        expect(reversed.expanded && session(reversed).state == "done", "Duplicate merge also works with oldest records first")
    }

    private static func removedAndWaitingSessionsDoNotMisfire() {
        let store = IslandStore()
        store.ingest(event("working", at: 10))
        store.ingest(event("done", at: 20))
        store.expanded = false
        store.replaceFromPoll([])
        expect(store.sessions.isEmpty && store.recentCompletionID == nil, "Removing a session clears its completion highlight")
        store.replaceFromPoll([event("done", at: 20)])
        expect(!store.expanded, "A historical completed session reappearing is not a new completion")
        store.ingest(event("waiting", at: 30))
        store.ingest(event("done", at: 40))
        expect(!store.expanded, "Only working to done triggers the requested completion behavior")
        store.expanded = true
        store.ingest(event("working", at: 50))
        store.ingest(event("done", at: 60))
        expect(store.expanded, "A completion never collapses an already open island")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
}
