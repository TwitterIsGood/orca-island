import Foundation

enum TerminalSwitcher {
    private static let queue = DispatchQueue(label: "com.orca-island.terminal-switch")

    static func switchTo(_ session: AgentSession) {
        guard session.canNavigate else { return }
        queue.async {
            guard navigate(session, run: { OrcaCommandRunner.run($0) }) else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: IslandNavigationFailure.notification, object: nil,
                        userInfo: ["message": "未能确认终端跳转：终端已关闭、位置已变化或暂时不可用。"])
                }
                return
            }
        }
    }

    /// Revalidate on every click; cached handles, titles and pane prefixes never
    /// become fallback routes. The injected runner keeps tests offline.
    static func navigate(_ session: AgentSession, run: ([String]) -> Data?) -> Bool {
        guard session.canNavigate, let paneKey = session.paneKey,
              let workspaceId = session.workspaceId,
              let originalHandle = session.terminalId else { return false }
        let environment = session.hostId == "local" ? "local" : session.environmentId!
        let selection = ["--environment", environment, "--json"]
        guard let listing = run(["terminal", "list", "--limit", "10000"] + selection),
              let envelope = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any],
              result["truncated"] as? Bool == false,
              let scope = result["hostScope"] as? [String: Any],
              (scope["hostIds"] as? [String])?.contains("local") == true,
              let omitted = scope["omittedHostIds"] as? [String], !omitted.contains("local"),
              let terminals = result["terminals"] as? [[String: Any]],
              let handle = terminalHandle(paneKey: paneKey, workspaceId: workspaceId,
                  terminals: terminals.filter { $0["executionHostId"] as? String == "local" }),
              handle == originalHandle,
              let switched = run(["terminal", "switch", "--terminal", handle] + selection),
              let response = try? JSONSerialization.jsonObject(with: switched) as? [String: Any],
              response["ok"] as? Bool == true,
              let switchResult = response["result"] as? [String: Any] else { return false }
        // With --environment the public command targets this desktop, never a
        // window on the remote execution host. Refused desktop routes stay refused.
        return switchResult["navigated"] as? Bool != false
    }

    static func terminalHandle(paneKey: String, workspaceId: String?, terminals: [[String: Any]]) -> String? {
        let matches = terminals.filter { terminal in
            guard let tab = terminal["tabId"] as? String,
                  let leaf = terminal["leafId"] as? String,
                  terminal["orphaned"] as? Bool == false,
                  terminal["connected"] as? Bool == true,
                  (terminal["executionHostId"] as? String ?? terminal["hostId"] as? String ?? "local") == "local"
            else { return false }
            return "\(tab):\(leaf)" == paneKey
                && (workspaceId == nil || terminal["worktreeId"] as? String == workspaceId)
        }
        guard matches.count == 1, let handle = matches[0]["handle"] as? String,
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return handle
    }

}
