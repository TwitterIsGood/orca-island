import Foundation

final class OrcaStatusPoller {
    private let queue = DispatchQueue(label: "com.orca-island.poller")
    private let onEvents: ([IslandEvent]) -> Void
    private var timer: DispatchSourceTimer?

    init(onEvents: @escaping ([IslandEvent]) -> Void) {
        self.onEvents = onEvents
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let terminalData = OrcaCommandRunner.run(["terminal", "list", "--json"]),
              let terminalObject = try? JSONSerialization.jsonObject(with: terminalData) as? [String: Any],
              let result = terminalObject["result"] as? [String: Any],
              let terminals = result["terminals"] as? [[String: Any]] else {
            return
        }

        var terminalByPane: [String: [String: Any]] = [:]
        for terminal in terminals {
            guard let tabId = terminal["tabId"] as? String,
                  let leafId = terminal["leafId"] as? String else { continue }
            terminalByPane["\(tabId):\(leafId)"] = terminal
        }
        let statusURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/orca/agent-hooks/last-status.json")
        guard let statusData = try? Data(contentsOf: statusURL),
              let statusObject = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
              let entries = statusObject["entries"] as? [String: [String: Any]] else {
            return
        }

        let events = entries.compactMap { _, entry -> IslandEvent? in
            guard let paneKey = entry["paneKey"] as? String,
                  let terminal = terminalByPane[paneKey],
                  let payload = entry["payload"] as? [String: Any],
                  let state = payload["state"] as? String else { return nil }

            let mainAgent: MainAgentPayload?
            if let rawMain = payload["mainAgent"] as? [String: Any],
               let mainState = rawMain["state"] as? String {
                mainAgent = MainAgentPayload(
                    state: mainState,
                    stateStartedAt: rawMain["stateStartedAt"] as? Double
                )
            } else {
                mainAgent = nil
            }

            let title = [terminal["paneTitle"], terminal["title"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return IslandEvent(
                type: "orca.poll",
                workspaceId: entry["worktreeId"] as? String,
                paneKey: paneKey,
                state: state,
                combinedState: state,
                mainAgent: mainAgent,
                receivedAt: entry["receivedAt"] as? Double,
                terminalTitle: title
            )
        }

        DispatchQueue.main.async { [onEvents] in
            onEvents(events)
        }
    }

}
