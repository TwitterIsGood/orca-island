import Foundation

// This harness never navigates or sends input to a real Orca terminal.
enum OrcaCommandRunner {
    static func run(_ arguments: [String]) -> Data? {
        preconditionFailure("CLI commands are unavailable in sync tests")
    }
}

@main
@MainActor
enum SyncConsistencyTests {
    static var checks = 0

    static func event(_ state: String, time: Double, title: String? = nil) -> IslandEvent {
        IslandEvent(type: "test", workspaceId: "/project", paneKey: "tab:leaf", state: state,
                    combinedState: state, mainAgent: nil, receivedAt: time, terminalTitle: title)
    }

    static func main() {
        let store = IslandStore()
        let snapshotStart = Date(timeIntervalSince1970: 10)
        store.ingest(event("working", time: 1000), arrivedAt: snapshotStart.addingTimeInterval(1))
        store.replaceFromPoll([], snapshotStartedAt: snapshotStart, livePaneKeys: [])
        expect(store.sessions.count == 1, "An older inventory cannot erase an event received during polling")
        store.replaceFromPoll([event("done", time: 500)], snapshotStartedAt: snapshotStart, livePaneKeys: ["tab:leaf"])
        expect(store.sessions.values.first?.state == "working", "The retained timestamp rejects an old completion")
        expect(!store.expanded, "Old completion does not alert")
        store.replaceFromPoll([], snapshotStartedAt: snapshotStart.addingTimeInterval(2), livePaneKeys: ["tab:leaf"])
        expect(store.sessions.count == 1, "A live terminal missing from the hook file keeps its known state")
        store.replaceFromPoll([event("done", time: 2000, title: "New title")], snapshotStartedAt: snapshotStart.addingTimeInterval(3), livePaneKeys: ["tab:leaf"])
        expect(store.expanded && store.sessions.values.first?.title == "New title", "A newer completion and title still apply")
        store.expanded = false
        store.markSyncUnavailable()
        expect(store.syncUnavailable && store.sessions.count == 1, "Failure marks retained data as unavailable instead of deleting it")
        expect(!store.expanded, "An offline mark cannot create completion alerts")
        store.replaceFromPoll([event("done", time: 2000)], snapshotStartedAt: snapshotStart.addingTimeInterval(4), livePaneKeys: ["tab:leaf"])
        expect(!store.syncUnavailable && store.lastSyncedAt != nil, "A complete successful poll clears the offline mark")
        expect(!store.expanded, "Reconnection does not replay an unchanged completion")
        store.replaceFromPoll([], snapshotStartedAt: snapshotStart.addingTimeInterval(5), livePaneKeys: [])
        expect(store.sessions.isEmpty && store.recentCompletionID == nil, "A later inventory confirms the terminal was closed")

        let row: [String: Any] = ["tabId": "remote:tab", "leafId": "leaf:one", "worktreeId": "/project",
                                  "connected": true, "orphaned": false, "handle": "term_current"]
        let key = "remote:tab:leaf:one"
        func target(_ rows: [[String: Any]], workspace: String? = "/project") -> String? {
            TerminalSwitcher.terminalHandle(paneKey: key, workspaceId: workspace, terminals: rows)
        }
        expect(target([row]) == "term_current", "Match the complete pane key without splitting colon-containing identifiers")
        expect(target([row], workspace: "/other") == nil, "Never jump into a different workspace")
        expect(target([row, row]) == nil, "Ambiguous matches do not choose the first terminal")
        expect(target([]) == nil, "A closed terminal cannot be selected")
        var disconnected = row; disconnected["connected"] = false
        expect(target([disconnected]) == nil, "Disconnected terminals cannot be selected")
        var orphaned = row; orphaned["orphaned"] = true
        expect(target([orphaned]) == nil, "Orphaned terminals cannot be selected")
        var wrongPane = row; wrongPane["leafId"] = "other"
        expect(target([wrongPane]) == nil, "A similar title or workspace cannot replace an exact pane match")
        print("Sync consistency checks passed (\(checks) assertions); no live Orca actions.")
    }

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
}
