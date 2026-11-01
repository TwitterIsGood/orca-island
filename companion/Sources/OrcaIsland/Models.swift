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
    @Published var expanded = false

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
        let session = makeSession(from: event)
        sessions = sessions.filter { $0.value.paneKey != session.paneKey || $0.key == session.id }
        sessions[session.id] = session
    }

    func replaceFromPoll(_ events: [IslandEvent]) {
        sessions = Dictionary(uniqueKeysWithValues: events.map { event in
            let session = makeSession(from: event)
            return (session.id, session)
        })
    }

    private func makeSession(from event: IslandEvent) -> AgentSession {
        let previous = sessions.values.first { $0.paneKey == event.paneKey && event.paneKey != nil }
        let workspaceId = event.workspaceId ?? previous?.workspaceId
        let key = "\(workspaceId ?? "unknown"): \(event.paneKey ?? "unknown")"
        let state = event.state ?? event.combinedState ?? event.mainAgent?.state ?? "unknown"
        let combinedState = event.combinedState ?? event.state ?? state
        let receivedAt = Date(timeIntervalSince1970: (event.receivedAt ?? Date().timeIntervalSince1970 * 1000) / 1000)
        return AgentSession(
            id: key,
            workspaceId: workspaceId,
            paneKey: event.paneKey,
            state: state,
            combinedState: combinedState,
            mainAgentState: event.mainAgent?.state,
            receivedAt: receivedAt,
            terminalTitle: event.terminalTitle ?? previous?.terminalTitle
        )
    }
}
