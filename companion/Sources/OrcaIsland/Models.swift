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
    var workspaceListId: String? = nil
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
    var stateStartedAt: Double? = nil
    var workspaceListId: String? = nil

    var navigationUnavailableReason: String? {
        if isStale { return "暂未连接，不能跳转" }
        if structuredSessionId != nil { return "原生聊天暂不支持跳转" }
        guard let terminalId, !terminalId.isEmpty else { return "休眠或无活动终端，不能跳转" }
        guard let paneKey, !paneKey.isEmpty, let workspaceId, !workspaceId.isEmpty else {
            return "缺少精确终端位置，不能跳转"
        }
        if hostId != "local" {
            guard hostId.hasPrefix("runtime:"), let environmentId,
                  hostId == "runtime:\(environmentId)", !environmentId.isEmpty else {
                return "此执行主机暂不支持跳转"
            }
        }
        return nil
    }

    var canNavigate: Bool { navigationUnavailableReason == nil }

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
        if isStale { return 3 }
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

/// Island owns this small ledger; it never reads or changes Orca's unread state.
protocol IslandAcknowledgementStorage {
    func load() -> [String: Double]
    func save(_ turns: [String: Double])
}

final class MemoryIslandAcknowledgementStorage: IslandAcknowledgementStorage {
    private var turns: [String: Double] = [:]
    func load() -> [String: Double] { turns }
    func save(_ turns: [String: Double]) { self.turns = turns }
}

struct UserDefaultsIslandAcknowledgementStorage: IslandAcknowledgementStorage {
    let defaults: UserDefaults
    var key = "dev.orca.island.acknowledgedCompletionTurns.v1"
    func load() -> [String: Double] { defaults.dictionary(forKey: key) as? [String: Double] ?? [:] }
    func save(_ turns: [String: Double]) { defaults.set(turns, forKey: key) }
}

enum IslandNavigationFailure {
    static let notification = Notification.Name("dev.orca.island.navigationFailure")
}

@MainActor
final class IslandStore: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published private(set) var recentCompletionID: String?
    @Published var expanded = false
    @Published var notchGeometry = NotchGeometry.fallback
    @Published var measuredBodyHeight: CGFloat = 44
    @Published private(set) var syncUnavailable = false
    @Published private(set) var syncFailure: String?
    @Published var navigationFailure: String?
    private(set) var unavailableHostIDs: Set<String> = []
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var usingEventBridge = false
    private(set) var lastBridgeAt: Date?
    private(set) var pushedStatusCount = 0
    private(set) var pollCount = 0
    private var eventArrivalByID: [String: Date] = [:]
    private var hiddenByID: [String: IslandEvent] = [:]
    private let acknowledgementStorage: IslandAcknowledgementStorage
    private var acknowledgedTurns: [String: Double]

    init(acknowledgementStorage: IslandAcknowledgementStorage = MemoryIslandAcknowledgementStorage()) {
        self.acknowledgementStorage = acknowledgementStorage
        acknowledgedTurns = acknowledgementStorage.load().filter { $0.value.isFinite }
    }

    var completedCount: Int { sessions.values.filter { $0.state == "done" }.count }

    func markAsRead(_ session: AgentSession) {
        if acknowledgeCompletion(session) { acknowledgementStorage.save(acknowledgedTurns) }
    }

    func markAllCompletedAsRead() {
        var changed = false
        for session in Array(sessions.values) where session.state == "done" {
            if acknowledgeCompletion(session) { changed = true }
        }
        if changed { acknowledgementStorage.save(acknowledgedTurns) }
    }

    private func acknowledgeCompletion(_ session: AgentSession) -> Bool {
        guard let current = sessions[session.id], current.state == "done",
              session.state == "done", completionTurn(current) == completionTurn(session) else { return false }
        let turn = completionTurn(current)
        acknowledgedTurns[current.id] = max(acknowledgedTurns[current.id] ?? -.infinity, turn)
        hiddenByID[current.id] = event(from: current)
        sessions.removeValue(forKey: current.id)
        eventArrivalByID.removeValue(forKey: current.id)
        if recentCompletionID == current.id { recentCompletionID = nil }
        return true
    }

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
        let event = original
        // Official remote events carry desktop receipt time, not the source's
        // monotonic turn evidence. They are refresh hints, never remote authority.
        // A hostless hook cannot be assigned by a currently unique raw path or
        // pane: an undiscovered remote may own exactly the same identifiers.
        if event.type == "orca.agent.status", event.hostId != "local" { return false }
        let id = eventIdentity(event)
        if let hidden = hiddenByID[id], acknowledgedTurns[id] == nil {
            let incoming = event.combinedState ?? event.state ?? event.mainAgent?.state
            // Repeated done pings after acknowledgment must never resurrect a completed turn.
            guard incoming != "done", incoming != "idle",
                  (event.receivedAt ?? 0) > (hidden.receivedAt ?? 0) else { return true }
            hiddenByID.removeValue(forKey: id)
        }
        let previous = previousSession(for: event, in: sessions)
            ?? hiddenByID[id].map { makeSession(from: $0, previous: nil) }
        let session = makeSession(from: event, previous: previous)
        if isAcknowledged(session) {
            hiddenByID[id] = self.event(from: session)
            return true
        }
        hiddenByID.removeValue(forKey: id)
        sessions[session.id] = session
        if previous == nil || session.receivedAt > previous!.receivedAt {
            eventArrivalByID[session.id] = arrivedAt
        }
        acknowledgeUpdates(completions: isNewCompletion(session, after: previous) ? [session] : [])
        return true
    }

    func replaceFromPoll(_ events: [IslandEvent], snapshotStartedAt: Date? = nil,
                         livePaneKeys: Set<String>? = nil,
                         unavailableHostIDs: Set<String> = []) {
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
            let previous = previousSession(for: event, in: snapshot)
                ?? previousSession(for: event, in: sessions)
                ?? hiddenByID[id].map { makeSession(from: $0, previous: nil) }
            let session = makeSession(from: event, previous: previous)
            if isAcknowledged(session) {
                hiddenByID[id] = self.event(from: session)
                explicitlyHidden.insert(id)
                continue
            }
            hiddenByID.removeValue(forKey: id)
            snapshot[session.id] = session
        }

        // A missing hook is not a closed terminal. A snapshot also cannot delete
        // an event received after its terminal inventory was requested.
        for (id, previous) in sessions where snapshot[id] == nil {
            if explicitlyHidden.contains(id) { continue }
            // The reader only caches its last CLI inventory. A newer bridge
            // row may not be in that cache yet; failed/truncated host coverage
            // is never evidence that its pane was removed.
            if unavailableHostIDs.contains(previous.hostId) {
                var retained = previous
                retained.isStale = true
                snapshot[id] = retained
                continue
            }
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
        self.unavailableHostIDs = unavailableHostIDs
        if unavailableHostIDs.contains("local") {
            syncUnavailable = true
            syncFailure = "orca_snapshot_failed"
        } else {
            // An unused offline remote environment has no stale rows and must not raise a false alarm.
            syncUnavailable = sessions.values.contains { $0.isStale }
            syncFailure = syncUnavailable ? "remote_unreachable" : nil
        }
        acknowledgeUpdates(completions: completions)
    }

    func markSyncUnavailable(reason: String? = nil) {
        syncUnavailable = true
        if let reason { syncFailure = reason } else if syncFailure == nil { syncFailure = "orca_snapshot_failed" }
    }

    var staleEnvironmentNames: [String] {
        Array(Set(sessions.values.filter(\.isStale).map { $0.environmentName ?? "远程环境" })).sorted()
    }

    /// Short, user-facing explanation of `syncFailure`.
    var syncFailureDescription: String? {
        guard syncUnavailable else { return nil }
        switch syncFailure {
        case "orca_api_incompatible": return "Orca 已更新，接口不兼容，请更新 Orca Island"
        case "orca_runtime_unreachable": return "Orca 未运行或无响应"
        case "helper_failed": return "读取 Orca 状态超时或失败"
        case "remote_unreachable":
            let names = staleEnvironmentNames
            return names.isEmpty
                ? "部分远程环境未连接 · 显示上次状态"
                : "\(names.joined(separator: "、")) 未连接 · 显示上次状态"
        default: return "读取 Orca 状态失败"
        }
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
         "readStateOwner": "island", "acknowledgedCompletionCount": acknowledgedTurns.count,
         "syncFailure": (syncUnavailable ? syncFailure : nil) as Any? ?? NSNull(),
         "syncFailureDescription": syncFailureDescription as Any? ?? NSNull(),
         "unavailableHosts": Array(unavailableHostIDs).sorted(),
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

    private func completionTurn(_ session: AgentSession) -> Double {
        session.stateStartedAt ?? session.receivedAt.timeIntervalSince1970 * 1000
    }

    private func isAcknowledged(_ session: AgentSession) -> Bool {
        session.state == "done" && acknowledgedTurns[session.id].map { completionTurn(session) <= $0 } == true
    }

    private func event(from session: AgentSession) -> IslandEvent {
        IslandEvent(type: "orca.snapshot", workspaceId: session.workspaceId, paneKey: session.paneKey,
                    state: session.state, combinedState: session.combinedState, mainAgent: nil,
                    receivedAt: session.receivedAt.timeIntervalSince1970 * 1000,
                    terminalTitle: session.terminalTitle, terminalId: session.terminalId,
                    hostId: session.hostId, environmentId: session.environmentId,
                    environmentName: session.environmentName, workspaceLabel: session.workspaceLabel,
                    tabId: session.tabId, leafId: session.leafId, structuredSessionId: session.structuredSessionId,
                    stateStartedAt: session.stateStartedAt, isStale: session.isStale,
                    workspaceListId: session.workspaceListId)
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
        let stateStartedAt: Double?
        if isNewer || projectsSameTimestamp {
            stateStartedAt = event.stateStartedAt ?? event.mainAgent?.stateStartedAt
                ?? (state == previous?.state ? previous?.stateStartedAt : nil)
                ?? receivedAt.timeIntervalSince1970 * 1000
        } else {
            stateStartedAt = previous?.stateStartedAt
        }
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
            tabId: event.type == "orca.snapshot" ? event.tabId : (event.tabId ?? previous?.tabId),
            leafId: event.type == "orca.snapshot" ? event.leafId : (event.leafId ?? previous?.leafId),
            // Public snapshots own liveness. A disappeared handle must not keep
            // a previously clickable terminal alive through metadata fallback.
            terminalId: event.type == "orca.agent.status" ? previous?.terminalId :
                (event.type == "orca.snapshot" ? event.terminalId : (event.terminalId ?? previous?.terminalId)),
            structuredSessionId: event.type == "orca.snapshot" ? event.structuredSessionId : (event.structuredSessionId ?? previous?.structuredSessionId),
            isStale: event.isStale ?? previous?.isStale ?? false,
            stateStartedAt: stateStartedAt,
            workspaceListId: event.workspaceListId ?? previous?.workspaceListId
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
