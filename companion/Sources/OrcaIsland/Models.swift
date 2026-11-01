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

    var workspaceName: String {
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
        Dictionary(grouping: sortedSessions, by: { $0.workspaceId ?? "unknown" })
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

    func ingest(_ event: IslandEvent) {
        let previous = previousSession(for: event, in: sessions)
        let session = makeSession(from: event, previous: previous)
        sessions[session.id] = session
        acknowledgeUpdates(completions: isNewCompletion(session, after: previous) ? [session] : [])
    }

    func replaceFromPoll(_ events: [IslandEvent]) {
        var snapshot: [String: AgentSession] = [:]
        for event in events {
            let previous = previousSession(for: event, in: snapshot)
                ?? previousSession(for: event, in: sessions)
            let session = makeSession(from: event, previous: previous)
            snapshot[session.id] = session
        }

        // Compare the final snapshot, not intermediate duplicate records. Loading
        // historical working/done entries must not manufacture a new completion.
        let completions = snapshot.values.filter { isNewCompletion($0, after: sessions[$0.id]) }
        sessions = snapshot
        acknowledgeUpdates(completions: completions)
    }

    private func previousSession(for event: IslandEvent, in candidates: [String: AgentSession]) -> AgentSession? {
        if let paneKey = nonempty(event.paneKey) {
            return candidates.values.first { $0.paneKey == paneKey }
        }
        return candidates[sessionKey(workspaceId: nonempty(event.workspaceId), paneKey: nil)]
    }

    private func sessionKey(workspaceId: String?, paneKey: String?) -> String {
        "\(workspaceId ?? "unknown"): \(paneKey ?? "unknown")"
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
        let key = previous?.id ?? sessionKey(workspaceId: workspaceId, paneKey: paneKey)
        let eventTime = Date(timeIntervalSince1970: (event.receivedAt ?? Date().timeIntervalSince1970 * 1000) / 1000)
        let isNewer = previous.map { eventTime > $0.receivedAt } ?? true
        let incomingState = event.combinedState ?? event.state
            ?? previous?.combinedState ?? event.mainAgent?.state ?? "unknown"
        let state = isNewer ? incomingState : (previous?.state ?? incomingState)
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
            terminalTitle: nonempty(event.terminalTitle) ?? previous?.terminalTitle
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
