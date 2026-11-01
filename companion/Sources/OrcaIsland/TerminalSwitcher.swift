import Foundation

enum TerminalSwitcher {
    private static let queue = DispatchQueue(label: "com.orca-island.terminal-switch")

    static func switchTo(_ session: AgentSession) {
        guard let paneKey = session.paneKey else { return }
        let parts = paneKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }

        queue.async { switchTo(tabId: parts[0], leafId: parts[1]) }
    }

    private static func switchTo(tabId: String, leafId: String) {
        guard let data = OrcaCommandRunner.run(["terminal", "list", "--json"]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let terminals = result["terminals"] as? [[String: Any]],
              let terminal = terminals.first(where: {
                  ($0["tabId"] as? String) == tabId && ($0["leafId"] as? String) == leafId
              }),
              let handle = terminal["handle"] as? String else {
            return
        }

        _ = OrcaCommandRunner.run(["terminal", "switch", "--terminal", handle])
    }
}
