import Foundation

enum TerminalSwitcher {
    private static let queue = DispatchQueue(label: "com.orca-island.terminal-switch")

    static func switchTo(_ session: AgentSession) {
        guard let paneKey = session.paneKey, let workspaceId = session.workspaceId, !session.isStale else { return }
        let target: [String: String] = ["hostId": session.hostId, "paneKey": paneKey, "workspaceId": workspaceId]
        guard let data = try? JSONSerialization.data(withJSONObject: target),
              let argument = String(data: data, encoding: .utf8) else { return }
        queue.async { _ = OrcaCommandRunner.runHelper(["reveal", argument]) }
    }

    static func terminalHandle(paneKey: String, workspaceId: String?, terminals: [[String: Any]]) -> String? {
        let matches = terminals.filter { terminal in
            guard let tab = terminal["tabId"] as? String,
                  let leaf = terminal["leafId"] as? String,
                  terminal["orphaned"] as? Bool != true,
                  terminal["connected"] as? Bool != false else { return false }
            return "\(tab):\(leaf)" == paneKey
                && (workspaceId == nil || terminal["worktreeId"] as? String == workspaceId)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]["handle"] as? String
    }

}
