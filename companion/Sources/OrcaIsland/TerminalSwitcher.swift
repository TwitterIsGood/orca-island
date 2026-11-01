import Foundation

enum TerminalSwitcher {
    private static let queue = DispatchQueue(label: "com.orca-island.terminal-switch")

    static func switchTo(_ session: AgentSession) {
        guard let paneKey = session.paneKey else { return }
        queue.async { switchTo(paneKey: paneKey, workspaceId: session.workspaceId) }
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

    private static func switchTo(paneKey: String, workspaceId: String?) {
        guard let data = OrcaCommandRunner.run(["terminal", "list", "--json"]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              let result = object["result"] as? [String: Any],
              let terminals = result["terminals"] as? [[String: Any]],
              let handle = terminalHandle(paneKey: paneKey, workspaceId: workspaceId, terminals: terminals) else {
            return
        }

        _ = OrcaCommandRunner.run(["terminal", "switch", "--terminal", handle])
    }
}
