import AppKit
import SwiftUI

// Layout tests must never issue an Orca command, even if a view action is triggered.
enum TerminalSwitcher {
    static func switchTo(_ session: AgentSession) {
        preconditionFailure("Terminal navigation is unavailable in the layout harness")
    }
}

@main
@MainActor
enum OverlayLayoutTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = IslandStore()
        store.notchGeometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            cameraWidth: 220,
            cameraHeight: 38
        )
        let hosting = NSHostingView(rootView: OverlayView(store: store))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: -10_000, y: -10_000, width: 364, height: 38),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Do not order this window on screen, activate the app, or run an Orca poller.
        defer { window.close() }

        func settle() {
            let deadline = Date().addingTimeInterval(0.25)
            repeat {
                let geometry = store.notchGeometry
                let frame = geometry.panelFrame(expanded: store.expanded, bodyHeight: store.measuredBodyHeight)
                window.setContentSize(frame.size)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
        }

        func populate(_ count: Int, groups: Int = 1, longTitles: Bool = false) {
            let events = (0..<count).map { index in
                IslandEvent(
                    type: "test", workspaceId: "/test/workspace-\(index % groups)",
                    paneKey: "test:\(index)", state: "working", combinedState: nil,
                    mainAgent: nil, receivedAt: Double(index),
                    terminalTitle: longTitles
                        ? "对话 \(index)：这是用于验证两行标题换行高度的长会话标题，要求列表完整展示并能够滚动查看最后一项"
                        : "Conversation \(index)"
                )
            }
            store.replaceFromPoll(events)
            settle()
        }

        settle()
        let emptyHeight = store.measuredBodyHeight
        expect(emptyHeight > 44, "The hidden empty-state content must report a real measured height")
        populate(1)
        let singleHeight = store.measuredBodyHeight
        expect(singleHeight > emptyHeight, "One conversation adds its workspace header and row")
        populate(4)
        let fourHeight = store.measuredBodyHeight
        expect(fourHeight > singleHeight, "Four conversations are taller than one")
        populate(4, groups: 4)
        let groupedHeight = store.measuredBodyHeight
        expect(groupedHeight > fourHeight, "Additional workspace headers contribute to measured height")
        populate(4, groups: 4, longTitles: true)
        let longTitleHeight = store.measuredBodyHeight
        expect(longTitleHeight > groupedHeight, "Wrapped terminal titles increase row height")

        store.expanded = true
        settle()
        expect(abs(store.measuredBodyHeight - longTitleHeight) <= 1,
               "Opening must preserve the hidden measurement at the same content width")
        populate(50, groups: 5, longTitles: true)
        let manyHeight = store.measuredBodyHeight
        expect(manyHeight > store.notchGeometry.maximumBodyHeight,
               "The natural content height must remain available above the scrolling limit")
        expect(store.visibleBodyHeight == store.notchGeometry.maximumBodyHeight,
               "Only the visible scrolling body is capped")
        expect(abs(hosting.frame.height - (38 + store.visibleBodyHeight)) <= 1,
               "The hosting view must contain one camera bar plus the capped scroll body")

        store.expanded = false
        populate(1)
        expect(abs(store.measuredBodyHeight - singleHeight) <= 1,
               "Content changes while closed must refresh the hidden measurement")
        store.expanded = true
        settle()
        expect(abs(hosting.frame.height - (38 + singleHeight)) <= 1,
               "Reopening after sessions disappear must shrink to the new content")
        populate(0)
        expect(abs(store.measuredBodyHeight - emptyHeight) <= 1,
               "Removing all conversations must restore the empty-state height")

        print("Overlay layout checks passed (body pt): empty=\(emptyHeight), one=\(singleHeight), four=\(fourHeight), grouped=\(groupedHeight), wrapped=\(longTitleHeight), many=\(manyHeight); scroll cap=\(store.notchGeometry.maximumBodyHeight).")
    }

    private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
}
