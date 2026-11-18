import Foundation

/// Only documented CLI JSON fields are decoded. Conversation bodies, prompts,
/// pairing endpoints and provider session identifiers never enter Island's state.
enum OrcaPublicCLI {
    enum ReadError: Error { case invalidResponse, incompleteInventory, invalidTimestamp }

    struct Envelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
    }
    static func decode<Result: Decodable>(_ data: Data, as type: Result.Type) throws -> Result {
        let envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data)
        guard envelope.ok, let result = envelope.result else { throw ReadError.invalidResponse }
        return result
    }

    struct Environment: Decodable {
        let id: String
        let name: String?
    }
    struct EnvironmentCatalog: Decodable { let environments: [Environment] }
    struct HostDescriptor {
        let hostId: String
        let environmentId: String?
        let environmentName: String?
        var selector: String { environmentId ?? "local" }
    }
    struct HostScope: Decodable {
        let hostIds: [String]
        let omittedHostIds: [String]?
        var coversLocal: Bool { hostIds.contains("local") && !(omittedHostIds ?? []).contains("local") }
    }
    struct WorkspaceInventory: Decodable {
        let worktrees: [Workspace]
        let truncated: Bool
        let hostScope: HostScope
    }
    struct Workspace: Decodable {
        let worktreeId: String
        let repo: String?
        let displayName: String?
        let hostId: String?
        let isArchived: Bool?
        let agents: [Agent]?
    }
    struct TerminalInventory: Decodable {
        let terminals: [Terminal]
        let truncated: Bool
    }
    struct Terminal: Decodable {
        let handle: String
        let tabId: String?
        let leafId: String?
        let worktreeId: String?
        let executionHostId: String?
        let title: String?
        let paneTitle: String?
        let connected: Bool?
        let orphaned: Bool?
    }
    struct AgentInventory: Decodable {
        let agents: [Agent]
        let truncated: Bool
        let hostScope: HostScope
    }
    struct Agent: Decodable {
        let paneKey: String?
        let worktreeId: String?
        let hostId: String?
        let kind: String?
        let state: String?
        let stateStartedAt: Double?
        let updatedAt: Double?
        let mainAgent: MainAgentPayload?
        let title: String?
        let displayName: String?
        let conversationName: String?
        let agentType: String?
        let agent: String?
    }

    static func paneIdentity(workspace: String, pane: String) -> String {
        "\(workspace.utf8.count):\(workspace)\(pane)"
    }
    static func eventIdentity(_ event: IslandEvent) -> String? {
        guard let workspace = event.workspaceId, let pane = event.paneKey else { return nil }
        return paneIdentity(workspace: workspace, pane: pane)
    }

    private struct Pane: Hashable { let workspace: String; let pane: String }
    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func project(host: HostDescriptor, workspaces: WorkspaceInventory,
                        terminals: TerminalInventory, agents: AgentInventory, previousEvents: [IslandEvent] = []) throws -> [IslandEvent] {
        guard !workspaces.truncated, !terminals.truncated, !agents.truncated,
              workspaces.hostScope.coversLocal, agents.hostScope.coversLocal else {
            throw ReadError.incompleteInventory
        }
        // Each CLI invocation owns one host. Nested SSH rows must not be relabelled
        // as that host, and archived workspaces must not return as clickable ghosts.
        var workspaceByID: [String: Workspace] = [:]
        for workspace in workspaces.worktrees where workspace.isArchived != true
            && (workspace.hostId == nil || workspace.hostId == "local") {
            guard text(workspace.worktreeId) != nil, workspaceByID[workspace.worktreeId] == nil else {
                throw ReadError.incompleteInventory
            }
            workspaceByID[workspace.worktreeId] = workspace
        }
        var terminalsByPane: [Pane: [Terminal]] = [:]
        for terminal in terminals.terminals where terminal.connected != false && terminal.orphaned != true
            && (terminal.executionHostId == nil || terminal.executionHostId == "local") {
            guard let workspace = text(terminal.worktreeId), let tab = text(terminal.tabId),
                  let leaf = text(terminal.leafId), text(terminal.handle) != nil else { continue }
            terminalsByPane[Pane(workspace: workspace, pane: "\(tab):\(leaf)"), default: []].append(terminal)
        }
        // agent list adds structured chats and documented retained sleeping completions.
        // It does not expose dashboard acknowledgement or a public chat reveal route.
        let localAgents = agents.agents.filter { $0.hostId == nil || $0.hostId == "local" }
        let chatPanes = Set(localAgents.compactMap { agent -> Pane? in
            guard agent.kind == "chat", let workspace = text(agent.worktreeId), let pane = text(agent.paneKey) else { return nil }
            return Pane(workspace: workspace, pane: pane)
        })
        var previousByPane: [Pane: IslandEvent] = [:]
        for event in previousEvents {
            guard let workspace = event.workspaceId, let pane = event.paneKey else { continue }
            previousByPane[Pane(workspace: workspace, pane: pane)] = event
        }
        var events: [Pane: IslandEvent] = [:]
        func put(_ agent: Agent, workspace: Workspace) throws {
            guard let pane = text(agent.paneKey) else { return }
            guard let state = agent.state, ["working", "waiting", "blocked", "done", "idle"].contains(state) else {
                throw ReadError.incompleteInventory
            }
            let sourceTime = agent.updatedAt ?? agent.stateStartedAt ?? agent.mainAgent?.stateStartedAt
            guard let sourceTime, sourceTime.isFinite, sourceTime >= 0 else { throw ReadError.invalidTimestamp }
            let key = Pane(workspace: workspace.worktreeId, pane: pane)
            let previous = previousByPane[key]
            // agent list may only provide updatedAt. A title/metadata refresh is
            // not proof of another completed turn and must not undo acknowledgement.
            let inheritedTurn = previous?.state == state ? previous?.stateStartedAt : nil
            let stateTime = agent.stateStartedAt ?? agent.mainAgent?.stateStartedAt ?? inheritedTurn ?? sourceTime
            guard stateTime.isFinite, stateTime >= 0 else { throw ReadError.invalidTimestamp }
            if let previous = events[key], (previous.receivedAt ?? 0) >= sourceTime { return }
            let matches = terminalsByPane[key] ?? []
            // A title is not an identity. Ambiguous, closed and chat-only rows stay
            // visible but have no route; never turn a provider session ID into a reveal ID.
            let terminal = !chatPanes.contains(key) && matches.count == 1 ? matches[0] : nil
            var event = IslandEvent(type: "orca.snapshot", workspaceId: workspace.worktreeId, paneKey: pane,
                                    state: state, combinedState: state, mainAgent: agent.mainAgent,
                                    receivedAt: sourceTime)
            event.terminalTitle = text(terminal?.paneTitle) ?? text(terminal?.title) ?? text(agent.displayName)
                ?? text(agent.conversationName) ?? text(agent.title) ?? text(agent.agentType) ?? text(agent.agent)
            event.terminalId = terminal?.handle
            event.tabId = terminal?.tabId
            event.leafId = terminal?.leafId
            event.hostId = host.hostId
            event.environmentId = host.environmentId
            event.environmentName = host.environmentName
            event.workspaceLabel = text(workspace.repo) ?? text(workspace.displayName)
            event.stateStartedAt = stateTime
            event.isStale = false
            event.isHidden = state == "idle"
            events[key] = event
        }
        for workspace in workspaceByID.values {
            for agent in workspace.agents ?? [] { try put(agent, workspace: workspace) }
        }
        let primaryPanes = Set(events.keys)
        for agent in localAgents {
            guard let workspaceID = text(agent.worktreeId), let pane = text(agent.paneKey),
                  let workspace = workspaceByID[workspaceID],
                  !primaryPanes.contains(Pane(workspace: workspaceID, pane: pane)) else { continue }
            // Main inventory wins even if the later supplement has a newer receipt.
            // Otherwise sequential sampling can manufacture a state transition.
            try put(agent, workspace: workspace)
        }
        return events.values.sorted {
            if $0.workspaceId != $1.workspaceId { return ($0.workspaceId ?? "") < ($1.workspaceId ?? "") }
            return ($0.paneKey ?? "") < ($1.paneKey ?? "")
        }
    }
}
