import Foundation

/// Anonymous public-CLI fixtures. No Orca calls occur unless --live is explicitly passed.
private final class CLIFixture {
    private let lock = NSLock()
    var remoteIDs: [String] = ["remote"]
    var failCatalog = false
    var catalogOverride: [String: Any]?
    var unavailable: Set<String> = []
    var overrides: [String: [String: Any]] = [:]
    var delay: TimeInterval = 0
    private(set) var calls: [[String]] = []
    private(set) var timeouts: [TimeInterval] = []
    private var active = 0
    private(set) var peak = 0

    static let scope: [String: Any] = ["hostIds": ["local"], "omittedHostIds": []]
    static let agent: [String: Any] = ["paneKey": "tab:leaf", "state": "working", "stateStartedAt": 1000,
        "updatedAt": 2000, "mainAgent": ["state": "working", "stateStartedAt": 1000], "agentType": "codex"]
    static let workspace: [String: Any] = ["worktreeId": "workspace", "repo": "Fixture", "hostId": "local",
        "isArchived": false, "agents": [agent]]
    static let terminal: [String: Any] = ["handle": "term_fixture", "tabId": "tab", "leafId": "leaf",
        "worktreeId": "workspace", "executionHostId": "local", "title": "Fixture Conversation", "connected": true,
        "orphaned": false]
    static var listedAgent: [String: Any] {
        var value = agent
        value["worktreeId"] = "workspace"; value["hostId"] = "local"; value["kind"] = "terminal"
        value["orcaSessionId"] = "orca_session_id:never-a-reveal-id"
        value["lastAssistantMessage"] = "must not enter Island state"
        return value
    }
    static func result(_ command: String) -> [String: Any] {
        switch command {
        case "worktree ps": return ["worktrees": [workspace], "truncated": false, "hostScope": scope]
        case "terminal list": return ["terminals": [terminal], "truncated": false]
        case "agent list": return ["agents": [listedAgent], "truncated": false, "hostScope": scope]
        default: preconditionFailure("Unsupported fixture command")
        }
    }
    func execute(_ arguments: [String], timeout: TimeInterval) -> Data? {
        lock.lock()
        calls.append(arguments); timeouts.append(timeout); active += 1; peak = max(peak, active)
        let catalog = arguments.prefix(2) == ["environment", "list"]
        let selector = arguments.firstIndex(of: "--environment").map { arguments[$0 + 1] } ?? "local"
        let command = arguments.prefix(2).joined(separator: " ")
        let fails = catalog ? failCatalog : unavailable.contains(selector)
        let result = catalog
            ? catalogOverride ?? ["environments": remoteIDs.map { ["id": $0, "name": "Fixture Remote \($0)"] }]
            : overrides["\(selector):\(command)"] ?? Self.result(command)
        let pause = delay
        lock.unlock()
        if pause > 0 { Thread.sleep(forTimeInterval: min(pause, timeout)) }
        defer { lock.lock(); active -= 1; lock.unlock() }
        guard !fails else { return nil }
        return try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
    }
}

@main
@MainActor
enum PublicCLITests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    private static func reader(_ fixture: CLIFixture, timeout: TimeInterval = 12) -> OrcaSnapshotReader {
        OrcaSnapshotReader(executor: fixture.execute, commandTimeout: 0.3, snapshotTimeout: timeout)
    }
    static let start = Date(timeIntervalSince1970: 12345)
    static func main() {
        if CommandLine.arguments.contains("--live") {
            let began = ProcessInfo.processInfo.systemUptime
            let reader = OrcaSnapshotReader()
            guard let snapshot = reader.read(startedAt: Date()) else {
                print("Public CLI live read failed: \(reader.lastFailure ?? "unknown")")
                exit(1)
            }
            let hosts = Set(snapshot.events.compactMap(\.hostId))
            let liveRoutes = snapshot.events.filter { $0.terminalId != nil }.count
            print("Public CLI live read: \(snapshot.events.count) events, \(hosts.count) represented hosts, \(liveRoutes) live terminal routes, \(snapshot.unavailableHostIDs.count) unavailable hosts, \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - began))s")
            return
        }

        let fixture = CLIFixture()
        let liveReader = reader(fixture)
        let snapshot = liveReader.read(startedAt: start)!
        expect(snapshot.events.count == 2, "Local and paired host inventories are both projected")
        expect(Set(snapshot.events.compactMap(\.hostId)) == ["local", "runtime:remote"], "Host identity survives identical pane IDs")
        expect(snapshot.livePaneKeys.count == 2, "Host-scoped live keys never collide")
        expect(snapshot.events.allSatisfy { $0.receivedAt == 2000 && $0.stateStartedAt == 1000 }, "Source clocks, not poll time, determine completion order")
        expect(snapshot.events.allSatisfy { $0.terminalId == "term_fixture" && $0.tabId == "tab" && $0.leafId == "leaf" }, "Exact public terminal identity joins remain clickable")
        expect(snapshot.events.allSatisfy { $0.structuredSessionId == nil }, "Provider or Orca session IDs are never private chat reveal IDs")
        expect(fixture.calls.count == 7, "One local catalog and three public reads per host")
        expect(fixture.calls.allSatisfy { ["environment list", "worktree ps", "terminal list", "agent list"].contains($0.prefix(2).joined(separator: " ")) }, "No private RPC, helper or conversation read is executed")
        expect(fixture.calls.dropFirst().allSatisfy { $0.contains("--environment") }, "Even local inventory explicitly selects its execution host")
        expect(fixture.timeouts.allSatisfy { $0 > 0 && $0 <= 0.3 }, "Every command has a bounded timeout")

        fixture.unavailable = ["remote"]
        let partial = liveReader.read(startedAt: start)!
        expect(partial.events.count == 2, "A failed remote read cannot erase its last known state")
        expect(partial.events.first { $0.hostId == "runtime:remote" }?.isStale == true, "Retained remote rows are marked stale")
        expect(partial.unavailableHostIDs == ["runtime:remote"], "Unavailable host diagnostics retain exact scope")
        fixture.failCatalog = true
        expect(liveReader.read(startedAt: start) == nil, "A catalog failure does not become successful local-only inventory")
        expect(liveReader.lastFailure == "orca_runtime_unreachable", "Catalog execution failure has a public transport reason")
        fixture.failCatalog = false; fixture.unavailable = []
        expect(liveReader.read(startedAt: start)!.events.count == 2, "Catalog failure leaves previous host state recoverable")
        fixture.remoteIDs = []
        expect(liveReader.read(startedAt: start)!.events.count == 1, "Only a successful catalog removes a deleted environment")

        let truncated = CLIFixture(); let truncatedReader = reader(truncated)
        _ = truncatedReader.read(startedAt: start)
        var bad = CLIFixture.result("agent list"); bad["truncated"] = true
        truncated.overrides["remote:agent list"] = bad
        expect(truncatedReader.read(startedAt: start)!.events.first { $0.hostId == "runtime:remote" }?.isStale == false,
               "Truncated optional supplement cannot hide complete live primary inventory")
        bad = CLIFixture.result("worktree ps"); bad["hostScope"] = ["hostIds": [], "omittedHostIds": ["local"]]
        truncated.overrides["local:worktree ps"] = bad
        expect(truncatedReader.read(startedAt: start)!.unavailableHostIDs.contains("local"), "Omitted local coverage is not an empty success")

        let malformed = CLIFixture(); malformed.catalogOverride = ["environments": [["id": "duplicate"], ["id": "duplicate"]]]
        expect(reader(malformed).read(startedAt: start) == nil, "Duplicate environment identities invalidate the catalog")
        malformed.catalogOverride = ["unexpected": []]
        expect(reader(malformed).read(startedAt: start) == nil, "Unknown public response shape is non-authoritative")

        let chat = CLIFixture(); chat.remoteIDs = []
        var listedChat = CLIFixture.listedAgent; listedChat["kind"] = "chat"
        chat.overrides["local:agent list"] = ["agents": [listedChat], "truncated": false, "hostScope": CLIFixture.scope]
        let chatEvent = reader(chat).read(startedAt: start)!.events[0]
        expect(chatEvent.state == "working" && chatEvent.terminalId == nil, "Structured chat is visible but cannot borrow a matching terminal route")
        expect(chatEvent.structuredSessionId == nil && chatEvent.tabId == nil, "Chat-only rows have no invented reveal identity")

        let sleeping = CLIFixture(); sleeping.remoteIDs = []
        var workspace = CLIFixture.workspace; workspace["agents"] = []
        sleeping.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        sleeping.overrides["local:terminal list"] = ["terminals": [], "truncated": false]
        var completion = CLIFixture.listedAgent; completion["state"] = "done"; completion["updatedAt"] = 3000
        sleeping.overrides["local:agent list"] = ["agents": [completion], "truncated": false, "hostScope": CLIFixture.scope]
        let sleepingReader = reader(sleeping)
        let sleepingEvent = sleepingReader.read(startedAt: start)!.events[0]
        expect(sleepingEvent.state == "done" && sleepingEvent.receivedAt == 3000, "Documented retained sleeping completions are included")
        expect(sleepingEvent.terminalId == nil, "A sleeping completion cannot borrow a stale PTY route")
        sleeping.overrides["local:agent list"] = ["agents": [], "truncated": true, "hostScope": CLIFixture.scope]
        let retainedSupplement = sleepingReader.read(startedAt: start)!
        expect(retainedSupplement.events.count == 1 && retainedSupplement.events[0].isStale == true,
               "A failed or truncated supplement retains its previous agent-only completion")
        expect(retainedSupplement.unavailableHostIDs == ["local"], "Only retained uncertain supplement rows mark partial coverage")
        sleeping.overrides["local:agent list"] = ["agents": [], "truncated": false, "hostScope": CLIFixture.scope]
        expect(sleepingReader.read(startedAt: start)!.events.isEmpty, "Only a complete supplement can confirm deletion of an agent-only row")

        let hidden = CLIFixture(); hidden.remoteIDs = []
        var idle = CLIFixture.agent; idle["state"] = "idle"
        workspace = CLIFixture.workspace; workspace["agents"] = [idle]
        hidden.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        hidden.overrides["local:agent list"] = ["agents": [], "truncated": false, "hostScope": CLIFixture.scope]
        let idleSnapshot = reader(hidden).read(startedAt: start)!
        expect(idleSnapshot.events[0].isHidden == true && idleSnapshot.livePaneKeys.isEmpty, "Idle remains explicitly hidden by default")

        let ambiguous = CLIFixture(); ambiguous.remoteIDs = []
        var another = CLIFixture.terminal; another["handle"] = "term_other"
        ambiguous.overrides["local:terminal list"] = ["terminals": [CLIFixture.terminal, another], "truncated": false]
        expect(reader(ambiguous).read(startedAt: start)!.events[0].terminalId == nil, "Ambiguous terminal joins stay non-clickable")
        another["worktreeId"] = "other-workspace"
        ambiguous.overrides["local:terminal list"] = ["terminals": [another], "truncated": false]
        expect(reader(ambiguous).read(startedAt: start)!.events[0].terminalId == nil, "Same pane in another workspace never contributes a route")

        let missingTime = CLIFixture(); missingTime.remoteIDs = []
        var unclocked = CLIFixture.agent
        unclocked.removeValue(forKey: "updatedAt"); unclocked.removeValue(forKey: "stateStartedAt"); unclocked.removeValue(forKey: "mainAgent")
        workspace = CLIFixture.workspace; workspace["agents"] = [unclocked]
        missingTime.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        expect(reader(missingTime).read(startedAt: start)!.unavailableHostIDs == ["local"], "Missing source timestamps cannot manufacture a new completion")

        let concurrent = CLIFixture(); concurrent.remoteIDs = (1...7).map { "remote-\($0)" }; concurrent.delay = 0.015
        let began = ProcessInfo.processInfo.systemUptime
        let fleet = reader(concurrent).read(startedAt: start)!
        expect(fleet.events.count == 8, "Seven remote environments plus local all reconcile")
        expect(concurrent.peak > 1 && concurrent.peak <= 4, "Fleet reads are concurrent and capped at four commands")
        expect(ProcessInfo.processInfo.systemUptime - began < 0.6, "Seven hosts are not serialized")
        let bounded = CLIFixture(); bounded.remoteIDs = (1...7).map { "remote-\($0)" }; bounded.delay = 0.05
        let expired = reader(bounded, timeout: 0.12).read(startedAt: start)!
        expect(!expired.unavailableHostIDs.isEmpty, "An exhausted round budget leaves unread hosts unavailable")
        expect(bounded.calls.count < 25, "The deadline prevents running every queued remote command")

        let turns = CLIFixture(); turns.remoteIDs = []
        var donePrimary = CLIFixture.agent; donePrimary["state"] = "done"
        donePrimary["mainAgent"] = ["state": "done", "stateStartedAt": 1000]
        workspace = CLIFixture.workspace; workspace["agents"] = [donePrimary]
        turns.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        var newerList = CLIFixture.listedAgent; newerList["state"] = "done"; newerList["updatedAt"] = 9000
        newerList.removeValue(forKey: "stateStartedAt"); newerList.removeValue(forKey: "mainAgent")
        turns.overrides["local:agent list"] = ["agents": [newerList], "truncated": false, "hostScope": CLIFixture.scope]
        let turnReader = reader(turns)
        let beforeRefresh = turnReader.read(startedAt: start)!.events[0]
        expect(beforeRefresh.receivedAt == 2000 && beforeRefresh.stateStartedAt == 1000,
               "A later agent-list metadata timestamp cannot override the main inventory turn")
        workspace["agents"] = []
        turns.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        let afterRefresh = turnReader.read(startedAt: start)!.events[0]
        expect(afterRefresh.receivedAt == 9000 && afterRefresh.stateStartedAt == 1000,
               "A now agent-only same-state row inherits the known turn, not its metadata refresh")
        newerList["state"] = "working"; newerList["updatedAt"] = 10000
        turns.overrides["local:agent list"] = ["agents": [newerList], "truncated": false, "hostScope": CLIFixture.scope]
        expect(turnReader.read(startedAt: start)!.events[0].stateStartedAt == 10000, "A real observed state change starts another inferred turn")
        let encoded = String(data: try! JSONEncoder().encode(snapshot.events), encoding: .utf8)!
        expect(!encoded.contains("must not enter Island state") && !encoded.contains("lastAssistantMessage"),
               "Conversation bodies never enter projected or persisted events")

        let optionalFailure = CLIFixture(); optionalFailure.remoteIDs = []
        var unknownAgent = CLIFixture.listedAgent; unknownAgent["paneKey"] = "future:state"; unknownAgent["state"] = "future-state"
        optionalFailure.overrides["local:agent list"] = ["agents": [unknownAgent], "truncated": false, "hostScope": CLIFixture.scope]
        let withUnknownSupplement = reader(optionalFailure).read(startedAt: start)!
        expect(withUnknownSupplement.events.count == 1 && withUnknownSupplement.unavailableHostIDs.isEmpty,
               "An unknown supplemental state cannot disable a complete primary terminal inventory")
        workspace = CLIFixture.workspace; workspace["agents"] = []
        sleeping.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        sleeping.overrides["local:agent list"] = ["agents": [completion], "truncated": false, "hostScope": CLIFixture.scope]
        expect(sleepingReader.read(startedAt: start)!.events.count == 1, "A recovered supplement restores the retained completion")
        workspace = CLIFixture.workspace; workspace["agents"] = []; workspace["isArchived"] = true
        sleeping.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        sleeping.overrides["local:agent list"] = ["agents": [], "truncated": true, "hostScope": CLIFixture.scope]
        expect(sleepingReader.read(startedAt: start)!.events.isEmpty,
               "An authoritatively archived workspace cannot retain supplemental ghost cards")

        let nested = CLIFixture(); nested.remoteIDs = []
        workspace = CLIFixture.workspace; workspace["hostId"] = "ssh:another-host"
        nested.overrides["local:worktree ps"] = ["worktrees": [workspace], "truncated": false, "hostScope": CLIFixture.scope]
        expect(reader(nested).read(startedAt: start)!.events.isEmpty,
               "Nested SSH workspace rows cannot be relabelled as this invocation's host")
        nested.overrides["local:worktree ps"] = CLIFixture.result("worktree ps")
        var nestedTerminal = CLIFixture.terminal; nestedTerminal["executionHostId"] = "ssh:another-host"
        nested.overrides["local:terminal list"] = ["terminals": [nestedTerminal], "truncated": false]
        expect(reader(nested).read(startedAt: start)!.events[0].terminalId == nil,
               "A terminal on another execution host cannot lend this host a click route")

        let environment = OrcaCommandRunner.commandEnvironment(["ORCA_ENVIRONMENT": "wrong", "ORCA_PROFILE": "wrong",
            "ORCA_TERMINAL_HANDLE": "wrong", "NODE_OPTIONS": "wrong", "NODE_REPL_EXTERNAL_MODULE": "wrong",
            "ELECTRON_RUN_AS_NODE": "1", "PATH": "/fixture/bin", "HOME": "/fixture/home"])
        expect(environment.keys.allSatisfy { !$0.hasPrefix("ORCA_") }, "Inherited Orca selectors are stripped")
        expect(environment["NODE_OPTIONS"] == nil && environment["ELECTRON_RUN_AS_NODE"] == nil,
               "The helper cannot inject a Node runtime into the public CLI launcher")
        expect(environment["HOME"] == "/fixture/home" && environment["PATH"]!.contains("/usr/bin"), "CLI preserves HOME and gets a GUI-safe PATH")
        print("Public CLI sync passed (\(checks) assertions); anonymous fixtures, no runtime writes.")
    }
}
