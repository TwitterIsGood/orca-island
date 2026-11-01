import Foundation

/// Each host is reconciled independently. One unreachable machine cannot erase its last known rows.
final class OrcaSnapshotReader {
    struct Host: Decodable {
        let hostId: String
        let available: Bool
        let events: [IslandEvent]
    }
    struct Response: Decodable {
        let ok: Bool
        let hosts: [Host]
    }
    private var lastByHost: [String: [IslandEvent]] = [:]

    func read(startedAt: Date) -> OrcaPollSnapshot? {
        guard let data = OrcaCommandRunner.runHelper(["snapshot"]),
              let response = try? JSONDecoder().decode(Response.self, from: data), response.ok else { return nil }
        return reconcile(response, startedAt: startedAt)
    }

    func reconcile(_ response: Response, startedAt: Date) -> OrcaPollSnapshot? {
        guard response.ok, !response.hosts.isEmpty else { return nil }
        // An environment removed from Orca's catalog is different from a temporarily unreachable one.
        let knownHosts = Set(response.hosts.map(\.hostId))
        lastByHost = lastByHost.filter { knownHosts.contains($0.key) }
        var events: [IslandEvent] = []
        for host in response.hosts {
            if host.available {
                lastByHost[host.hostId] = host.events
                events += host.events
            } else {
                events += (lastByHost[host.hostId] ?? []).map { event in
                    var event = event
                    event.isStale = true
                    return event
                }
            }
        }
        // Only rows actually retained by this projection count as live, never the broader terminal inventory.
        let keys = Set(events.filter { $0.isHidden != true }.compactMap { event in
            event.paneKey.map { AgentSession.identity(hostId: event.hostId ?? "local", paneKey: $0) }
        })
        return OrcaPollSnapshot(events: events, livePaneKeys: keys, startedAt: startedAt,
                                unavailableHostIDs: Set(response.hosts.filter { !$0.available }.map(\.hostId)))
    }
}
