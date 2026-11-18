import Foundation

/// Each host is reconciled independently. One unreachable machine cannot erase its last known rows.
final class OrcaSnapshotReader {
    struct Host: Decodable {
        let hostId: String
        let available: Bool
        let events: [IslandEvent]
        // Optional coverage metadata keeps existing reconcile fixtures source-compatible.
        var supplementalPaneKeys: [String]? = nil
        var supplementalUnavailableWorkspaceIDs: [String]? = nil
    }
    struct Response: Decodable {
        let ok: Bool
        let hosts: [Host]
    }
    typealias Executor = ([String], TimeInterval) -> Data?

    private let executor: Executor
    private let commandTimeout: TimeInterval
    private let snapshotTimeout: TimeInterval
    private let maximumConcurrentHosts: Int
    private var lastByHost: [String: [IslandEvent]] = [:]
    private var lastSupplementalKeysByHost: [String: Set<String>] = [:]
    /// Why the most recent read failed; read on the poller's reader queue only.
    private(set) var lastFailure: String?

    init(executor: @escaping Executor = { OrcaCommandRunner.run($0, timeout: $1) },
         commandTimeout: TimeInterval = 3, snapshotTimeout: TimeInterval = 12,
         maximumConcurrentHosts: Int = 4) {
        self.executor = executor
        self.commandTimeout = max(0.1, commandTimeout)
        self.snapshotTimeout = max(0.1, snapshotTimeout)
        self.maximumConcurrentHosts = max(1, min(4, maximumConcurrentHosts))
    }

    private final class HostResults {
        private let lock = NSLock()
        private var hosts: [String: Host] = [:]
        func insert(_ host: Host) { lock.lock(); defer { lock.unlock() }; hosts[host.hostId] = host }
        func ordered(_ descriptors: [OrcaPublicCLI.HostDescriptor]) -> [Host] {
            lock.lock(); defer { lock.unlock() }
            return descriptors.map { hosts[$0.hostId] ?? Host(hostId: $0.hostId, available: false, events: []) }
        }
    }

    func read(startedAt: Date) -> OrcaPollSnapshot? {
        let deadline = ProcessInfo.processInfo.systemUptime + snapshotTimeout
        // The catalog is local-only by CLI contract. Its failure must never look
        // like removal of every paired environment from the authoritative fleet.
        guard let data = executor(["environment", "list", "--json"], min(commandTimeout, snapshotTimeout)) else {
            lastFailure = "orca_runtime_unreachable"
            return nil
        }
        let catalog: OrcaPublicCLI.EnvironmentCatalog
        do { catalog = try OrcaPublicCLI.decode(data, as: OrcaPublicCLI.EnvironmentCatalog.self) }
        catch { lastFailure = "orca_snapshot_failed"; return nil }
        let ids = catalog.environments.map(\.id)
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "local" }),
              Set(ids).count == ids.count else { lastFailure = "orca_snapshot_failed"; return nil }
        let descriptors = [OrcaPublicCLI.HostDescriptor(hostId: "local", environmentId: nil, environmentName: nil)]
            + catalog.environments.map { OrcaPublicCLI.HostDescriptor(hostId: "runtime:\($0.id)",
                environmentId: $0.id, environmentName: $0.name) }
        let results = HostResults()
        let workers = OperationQueue()
        workers.name = "com.orca-island.public-cli-hosts"
        workers.maxConcurrentOperationCount = maximumConcurrentHosts
        for descriptor in descriptors {
            let previousEvents = lastByHost[descriptor.hostId] ?? []
            workers.addOperation { [self] in
                let host = readHost(descriptor, deadline: deadline, previousEvents: previousEvents)
                results.insert(host)
            }
        }
        // Every command has its own bound plus this shared monotonic deadline.
        // Waiting hosts become unavailable once the budget is spent, not serial
        // three-command timeouts for every saved remote machine.
        workers.waitUntilAllOperationsAreFinished()
        lastFailure = nil
        return reconcile(Response(ok: true, hosts: results.ordered(descriptors)), startedAt: startedAt)
    }

    private func readHost(_ host: OrcaPublicCLI.HostDescriptor, deadline: TimeInterval, previousEvents: [IslandEvent]) -> Host {
        func read<Result: Decodable>(_ arguments: [String], as type: Result.Type) throws -> Result {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, let data = executor(arguments + ["--environment", host.selector, "--json"],
                                                     min(commandTimeout, remaining)) else {
                throw OrcaPublicCLI.ReadError.invalidResponse
            }
            return try OrcaPublicCLI.decode(data, as: type)
        }
        do {
            let workspaces = try read(["worktree", "ps", "--limit", "10000"], as: OrcaPublicCLI.WorkspaceInventory.self)
            let terminals = try read(["terminal", "list", "--limit", "10000"], as: OrcaPublicCLI.TerminalInventory.self)
            let emptySupplement = OrcaPublicCLI.AgentInventory(agents: [], truncated: false, hostScope: workspaces.hostScope)
            var events = try OrcaPublicCLI.project(host: host, workspaces: workspaces, terminals: terminals,
                                                   agents: emptySupplement, previousEvents: previousEvents)
            // agent list is newer than the primary public inventories. Older paired
            // servers can serve current terminal status while rejecting this supplement.
            let supplement = try? read(["agent", "list"], as: OrcaPublicCLI.AgentInventory.self)
            var supplementComplete = false
            if let supplement, !supplement.truncated, supplement.hostScope.coversLocal,
               let supplemented = try? OrcaPublicCLI.project(host: host, workspaces: workspaces, terminals: terminals,
                                                             agents: supplement, previousEvents: previousEvents) {
                events = supplemented
                supplementComplete = true
            }
            let visibleWorkspaces = workspaces.worktrees.filter { $0.isArchived != true && ($0.hostId == nil || $0.hostId == "local") }
            let primaryKeys = Set(visibleWorkspaces.flatMap { workspace in
                (workspace.agents ?? []).compactMap { agent in
                    agent.paneKey.map { OrcaPublicCLI.paneIdentity(workspace: workspace.worktreeId, pane: $0) }
                }
            })
            var result = Host(hostId: host.hostId, available: true, events: events)
            result.supplementalPaneKeys = events.compactMap(OrcaPublicCLI.eventIdentity).filter { !primaryKeys.contains($0) }
            if !supplementComplete {
                result.supplementalUnavailableWorkspaceIDs = visibleWorkspaces.map(\.worktreeId)
            }
            return result
        } catch { return Host(hostId: host.hostId, available: false, events: []) }
    }

    func reconcile(_ response: Response, startedAt: Date) -> OrcaPollSnapshot? {
        guard response.ok, !response.hosts.isEmpty else { return nil }
        // An environment removed from Orca's catalog is different from a temporarily unreachable one.
        let knownHosts = Set(response.hosts.map(\.hostId))
        lastByHost = lastByHost.filter { knownHosts.contains($0.key) }
        lastSupplementalKeysByHost = lastSupplementalKeysByHost.filter { knownHosts.contains($0.key) }
        var events: [IslandEvent] = []
        var unavailableHosts = Set(response.hosts.filter { !$0.available }.map(\.hostId))
        for host in response.hosts {
            if host.available {
                var retained: [IslandEvent] = []
                if let workspaceIDs = host.supplementalUnavailableWorkspaceIDs {
                    let workspaces = Set(workspaceIDs)
                    let freshKeys = Set(host.events.compactMap(OrcaPublicCLI.eventIdentity))
                    let oldSupplemental = lastSupplementalKeysByHost[host.hostId] ?? []
                    retained = (lastByHost[host.hostId] ?? []).filter { event in
                        guard let identity = OrcaPublicCLI.eventIdentity(event), let workspace = event.workspaceId else { return false }
                        return oldSupplemental.contains(identity) && !freshKeys.contains(identity) && workspaces.contains(workspace)
                    }.map { event in
                        var stale = event
                        stale.isStale = true
                        stale.terminalId = nil; stale.tabId = nil; stale.leafId = nil
                        return stale
                    }
                    if !retained.isEmpty { unavailableHosts.insert(host.hostId) }
                }
                let combined = host.events + retained
                lastByHost[host.hostId] = combined
                lastSupplementalKeysByHost[host.hostId] = Set(host.supplementalPaneKeys ?? [])
                    .union(retained.compactMap(OrcaPublicCLI.eventIdentity))
                events += combined
            } else {
                events += (lastByHost[host.hostId] ?? []).map { event in
                    var event = event
                    event.isStale = true
                    return event
                }
            }
        }
        let keys = Set(events.filter { $0.isHidden != true }.compactMap { event in
            event.paneKey.map { AgentSession.identity(hostId: event.hostId ?? "local", paneKey: $0) }
        })
        return OrcaPollSnapshot(events: events, livePaneKeys: keys, startedAt: startedAt,
                                unavailableHostIDs: unavailableHosts)
    }
}
