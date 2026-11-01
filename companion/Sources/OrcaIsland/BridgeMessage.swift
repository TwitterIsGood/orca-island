import Foundation

enum BridgeMessage {
    case hello
    case status(IslandEvent)
    case workspace
    case test

    static func decode(_ data: Data) -> BridgeMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "orca.bridge.hello":
            guard object["protocol"] as? Int == 1 else { return nil }
            return .hello
        case "orca.agent.status":
            guard let event = try? JSONDecoder().decode(IslandEvent.self, from: data),
                  let pane = event.paneKey, !pane.isEmpty, pane.count <= 2048,
                  let state = event.combinedState ?? event.state,
                  ["working", "waiting", "blocked", "done"].contains(state),
                  let time = event.receivedAt, time.isFinite, time > 0 else { return nil }
            return .status(event)
        case "orca.workspace.created", "orca.workspace.removed":
            guard let id = object["workspaceId"] as? String, !id.isEmpty else { return nil }
            return .workspace
        case "orca.test":
            return .test
        default:
            return nil
        }
    }
}
