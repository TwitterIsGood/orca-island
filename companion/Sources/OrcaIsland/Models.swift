import Foundation
import SwiftUI

struct MainAgentPayload: Codable {
    let state: String
    let stateStartedAt: Double?
}

struct IslandEvent: Codable {
    let type: String?
    let workspaceId: String?
    let paneKey: String?
    let state: String?
    let combinedState: String?
    let mainAgent: MainAgentPayload?
    let receivedAt: Double?
    var terminalTitle: String? = nil
    var terminalId: String? = nil
    var hostId: String? = nil
    var environmentId: String? = nil
    var environmentName: String? = nil
    var workspaceLabel: String? = nil
    var tabId: String? = nil
    var leafId: String? = nil
    var structuredSessionId: String? = nil
    var stateStartedAt: Double? = nil
    var isStale: Bool? = nil
    var isHidden: Bool? = nil
}

struct AgentSession: Identifiable {
    let id: String
    let workspaceId: String?
    let paneKey: String?
    let state: String
    let combinedState: String
    let mainAgentState: String?
    let receivedAt: Date
    let terminalTitle: String?
    var hostId: String = "local"
    var environmentId: String? = nil
    var environmentName: String? = nil
    var workspaceLabel: String? = nil
    var tabId: String? = nil
    var leafId: String? = nil
    var terminalId: String? = nil
    var structuredSessionId: String? = nil
    var isStale: Bool = false

    static func identity(hostId: String, paneKey: String) -> String {
        // Length prefixes keep arbitrary host and pane identifiers collision-free.
        "\(hostId.utf8.count):\(hostId)\(paneKey)"
    }

    var workspaceName: String {
        if let workspaceLabel, !workspaceLabel.isEmpty { return workspaceLabel }
        if let workspaceId, !workspaceId.isEmpty {
            return URL(fileURLWithPath: workspaceId).lastPathComponent
        }
        return "未命名工作区"
    }

    var title: String {
        guard var title = terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "未命名对话 · \(paneKey?.suffix(6) ?? "未知")"
        }
        if let first = title.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let suffix = " | \(workspaceName)"
        if title.hasSuffix(suffix) { title.removeLast(suffix.count) }
        return title.isEmpty ? "未命名对话" : title
    }

    var priority: Int {
        switch state {
        case "blocked", "waiting": return 0
        case "working": return 1
        default: return 2
        }
    }

    var displayState: String {
        switch state {
        case "idle": return "空闲"
        case "working": return "工作中"
        case "waiting": return "等待输入"
        case "blocked": return "已阻塞"
        case "done": return "已完成"
        default: return state
        }
    }

    var tint: Color {
        switch state {
        case "working": return .blue
        case "waiting": return .yellow
        case "blocked": return .orange
        case "done": return .green
        default: return .gray
        }
    }
}

struct WorkspaceGroup: Identifiable {
    let id: String
    let name: String
    let sessions: [AgentSession]
    var priority: Int { sessions.map(\.priority).min() ?? 2 }
}

@MainActor
final class IslandStore: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published private(set) var recentCompletionID: String?
    @Published var expanded = false
    @Published var notchGeometry = NotchGeometry.fallback
    @Published var measuredBodyHeight: CGFloat = 44
    @Published private(set) var syncUnavailable = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var usingEventBridge = false
    private(set) var lastBridgeAt: Date?
    private(set) var pushedStatusCount = 0
    private(set) var pollCount = 0
    private var eventArrivalByID: [String: Date] = [:]
    private var hiddenByID: [String: IslandEvent] = [:]

    var visibleBodyHeight: CGFloat {
        min(max(44, measuredBodyHeight), notchGeometry.maximumBodyHeight)
    }

    var sortedSessions: [AgentSession] {
        sessions.values.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
            return $0.id < $1.id
        }
    }

    var workspaceGroups: [WorkspaceGroup] {
        Dictionary(grouping: sortedSessions, by: { AgentSession.identity(hostId: $0.hostId, paneKey: $0.workspaceId ?? "unknown") })
            .map { key, sessions in
                WorkspaceGroup(id: key, name: sessions.first?.workspaceName ?? "未命名工作区", sessions: sessions)
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.id < $1.id
            }
    }

    var currentSession: AgentSession? {
        sortedSessions.first
    }

    @discardableResult
    func ingest(_ original: IslandEvent, arrivedAt: Date = Date()) -> Bool {
        var event = original
        if event.hostId == nil && event.type == "orca.agent.status" {
            let candidates = sessions.values.filter {
                $0.paneKey == event.paneKey && (event.workspaceId == nil || $0.workspaceId == event.workspaceId)
            }
            let hidden = hiddenByID.values.filter {
                $0.paneKey == event.paneKey && (event.workspaceId == nil || $0.workspaceId == event.workspaceId)
            }
            let hosts = Set(candidates.map(\.hostId) + hidden.map { $0.hostId ?? "local" })
            guard hosts.count == 1, let host = hosts.first else { return false }
            // The plugin stamps receipt on this desktop; remote authorities have their own clock.
            // Reconcile remote events from their source instead of comparing unrelated clocks.
            guard host == "local" else { return false }
            event.hostId = host
        }
        let id = eventIdentity(event)
        if let hidden = hiddenByID[id] {
            let incoming = event.combinedState ?? event.state ?? event.mainAgent?.state
            // Repeated done pings after acknowledgment must never resurrect a completed turn.
            guard incoming != "done", incoming != "idle",
                  (event.receivedAt ?? 0) > (hidden.receivedAt ?? 0) else { return true }
            hiddenByID.removeValue(forKey: id)
        }
        let previous = previousSession(for: event, in: sessions)
        let session = makeSession(from: event, previous: previous)
        sessions[session.id] = session
        if previous == nil || session.receivedAt > previous!.receivedAt {
            eventArrivalByID[session.id] = arrivedAt
        }
        acknowledgeUpdates(completions: isNewCompletion(session, after: previous) ? [session] : [])
        return true
    }

    func replaceFromPoll(_ events: [IslandEvent], snapshotStartedAt: Date? = nil,
                         livePaneKeys: Set<String>? = nil) {
        let observedIDs = Set(events.map(eventIdentity))
        hiddenByID = hiddenByID.filter { observedIDs.contains($0.key) }
        var snapshot: [String: AgentSession] = [:]
        var explicitlyHidden = Set<String>()
        for event in events {
            let id = eventIdentity(event)
            if event.isHidden == true {
                let previous = sessions[id]
                let newerWorking = previous?.state == "working"
                    && previous!.receivedAt.timeIntervalSince1970 * 1000 > (event.receivedAt ?? 0)
                if newerWorking { snapshot[id] = previous; continue }
                hiddenByID[id] = event
                explicitlyHidden.insert(id)
                continue
            }
            hiddenByID.removeValue(forKey: id)
            let previous = previousSession(for: event, in: snapshot)
                ?? previousSession(for: event, in: sessions)
            let session = makeSession(from: event, previous: previous)
            snapshot[session.id] = session
        }

        // A missing hook is not a closed terminal. A snapshot also cannot delete
        // an event received after its terminal inventory was requested.
        for (id, previous) in sessions where snapshot[id] == nil {
            if explicitlyHidden.contains(id) { continue }
            let stillLive = livePaneKeys?.contains(id) == true
                || (previous.hostId == "local" && previous.paneKey.map { livePaneKeys?.contains($0) == true } == true)
            let arrivedDuringPoll = snapshotStartedAt.map { start in
                eventArrivalByID[id].map { $0 > start } ?? false
            } ?? false
            if stillLive || arrivedDuringPoll { snapshot[id] = previous }
        }

        // Compare the final snapshot, not intermediate duplicate records. Loading
        // historical working/done entries must not manufacture a new completion.
        let completions = snapshot.values.filter { isNewCompletion($0, after: sessions[$0.id]) }
        sessions = snapshot
        eventArrivalByID = eventArrivalByID.filter { snapshot[$0.key] != nil }
        lastSyncedAt = Date()
        syncUnavailable = sessions.values.contains { $0.isStale }
        acknowledgeUpdates(completions: completions)
    }

    func markSyncUnavailable() {
        syncUnavailable = true
    }

    func recordBridgeMessage(isStatus: Bool = false) {
        usingEventBridge = true
        lastBridgeAt = Date()
        if isStatus { pushedStatusCount += 1 }
    }

    func recordPollCount(_ count: Int) {
        pollCount = count
    }

    var synchronizationDiagnostics: [String: Any] {
        ["mode": usingEventBridge ? "event" : "compatibility",
         "reconciliationSeconds": usingEventBridge ? 45 : 2,
         "pollCount": pollCount, "pushedStatusCount": pushedStatusCount,
         "sessionCount": sessions.count, "syncUnavailable": syncUnavailable,
         "lastBridgeAt": lastBridgeAt.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? NSNull(),
         "lastReconciledAt": lastSyncedAt.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? NSNull()]
            .merging(["sessions": sortedSessions.map { session -> [String: Any] in
                ["hostId": session.hostId, "environment": session.environmentName ?? "Local Mac",
                 "workspaceId": session.workspaceId ?? "", "paneKey": session.paneKey ?? "",
                 "state": session.state, "title": session.title, "stale": session.isStale]
            }]) { _, new in new }
    }

    private func previousSession(for event: IslandEvent, in candidates: [String: AgentSession]) -> AgentSession? {
        if let paneKey = nonempty(event.paneKey) {
            return candidates[AgentSession.identity(hostId: event.hostId ?? "local", paneKey: paneKey)]
        }
        return candidates[eventIdentity(event)]
    }

    private func eventIdentity(_ event: IslandEvent) -> String {
        AgentSession.identity(hostId: event.hostId ?? "local", paneKey: event.paneKey ?? event.workspaceId ?? "unknown")
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func makeSession(from event: IslandEvent, previous: AgentSession?) -> AgentSession {
        let workspaceId = nonempty(event.workspaceId) ?? previous?.workspaceId
        let paneKey = nonempty(event.paneKey) ?? previous?.paneKey
        // Workspace metadata can arrive after a plugin event. Keep the pane's
        // identity stable so completion highlights and list identity survive.
        let key = previous?.id ?? eventIdentity(event)
        let eventTime = Date(timeIntervalSince1970: (event.receivedAt ?? Date().timeIntervalSince1970 * 1000) / 1000)
        let isNewer = previous.map { eventTime > $0.receivedAt } ?? true
        let incomingState = event.combinedState ?? event.state
            ?? previous?.combinedState ?? event.mainAgent?.state ?? "unknown"
        // Read/idle projection may change without a new agent timestamp.
        let projectsSameTimestamp = event.type == "orca.snapshot" && previous?.receivedAt == eventTime
        let state = isNewer || projectsSameTimestamp ? incomingState : (previous?.state ?? incomingState)
        let receivedAt = isNewer ? eventTime : (previous?.receivedAt ?? eventTime)
        return AgentSession(
            id: key,
            workspaceId: workspaceId,
            paneKey: paneKey,
            state: state,
            combinedState: state,
            mainAgentState: isNewer ? (event.mainAgent?.state ?? previous?.mainAgentState) : previous?.mainAgentState,
            receivedAt: receivedAt,
            // Poll titles come from the live terminal list, independently of the
            // hook timestamp, so even an old status snapshot can refresh a title.
            terminalTitle: nonempty(event.terminalTitle) ?? previous?.terminalTitle,
            hostId: event.hostId ?? previous?.hostId ?? "local",
            environmentId: event.environmentId ?? previous?.environmentId,
            environmentName: event.environmentName ?? previous?.environmentName,
            workspaceLabel: event.workspaceLabel ?? previous?.workspaceLabel,
            tabId: event.tabId ?? previous?.tabId,
            leafId: event.leafId ?? previous?.leafId,
            terminalId: event.terminalId ?? previous?.terminalId,
            structuredSessionId: event.structuredSessionId ?? previous?.structuredSessionId,
            isStale: event.isStale ?? previous?.isStale ?? false
        )
    }

    private func isNewCompletion(_ session: AgentSession, after previous: AgentSession?) -> Bool {
        guard let previous else { return false }
        return previous.state == "working" && session.state == "done"
            && session.receivedAt > previous.receivedAt
    }

    private func acknowledgeUpdates(completions: [AgentSession]) {
        if let recentCompletionID, sessions[recentCompletionID]?.state != "done" {
            self.recentCompletionID = nil
        }
        guard let latest = completions.sorted(by: {
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
            return $0.id < $1.id
        }).first else { return }
        recentCompletionID = latest.id
        expanded = true
    }
}
