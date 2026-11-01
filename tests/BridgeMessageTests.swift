import Foundation

@main
@MainActor
enum BridgeMessageTests {
    static func decode(_ text: String) -> BridgeMessage? { BridgeMessage.decode(Data(text.utf8)) }
    static func main() {
        guard case .hello? = decode(#"{"type":"orca.bridge.hello","protocol":1}"#) else { fatalError("Handshake rejected") }
        precondition(decode(#"{"type":"orca.bridge.hello","protocol":2}"#) == nil)
        precondition(decode(#"{"type":"unknown"}"#) == nil)
        precondition(decode(#"{"type":"orca.agent.status","state":"done"}"#) == nil)
        guard case .status(let event)? = decode(#"{"type":"orca.agent.status","paneKey":"tab:leaf","state":"working","receivedAt":1000,"terminalTitle":"A title","terminalId":"term_1"}"#) else { fatalError("Status rejected") }
        precondition(event.terminalTitle == "A title" && event.terminalId == "term_1")
        precondition(decode(#"{"type":"orca.agent.status","paneKey":"tab:leaf","state":"complete","receivedAt":1000}"#) == nil)
        guard case .workspace? = decode(#"{"type":"orca.workspace.removed","workspaceId":"workspace"}"#) else { fatalError("Workspace event rejected") }
        guard case .test? = decode(#"{"type":"orca.test"}"#) else { fatalError("Test rejected") }
        let store = IslandStore()
        precondition(store.synchronizationDiagnostics["mode"] as? String == "compatibility")
        store.recordBridgeMessage(isStatus: true)
        store.recordPollCount(3)
        precondition(store.synchronizationDiagnostics["mode"] as? String == "event")
        precondition(store.synchronizationDiagnostics["reconciliationSeconds"] as? Int == 45)
        precondition(store.pushedStatusCount == 1 && store.pollCount == 3 && store.sessions.isEmpty)
        _ = try! JSONSerialization.data(withJSONObject: store.synchronizationDiagnostics)
        print("Bridge protocol and diagnostics checks passed; no live events injected.")
    }
}
