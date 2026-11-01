import AppKit
import Combine
import SwiftUI

@MainActor
private final class ExpansionRenderProbe {
    var lastExpanded: Bool?
    var firstExpandedAt: TimeInterval?
    func record(_ expanded: Bool) {
        lastExpanded = expanded
        if expanded && firstExpandedAt == nil {
            firstExpandedAt = ProcessInfo.processInfo.systemUptime
        }
    }
}

private struct ProbedOverlay: View {
    @ObservedObject var store: IslandStore
    let probe: ExpansionRenderProbe

    var body: some View {
        let _ = probe.record(store.expanded)
        return OverlayView(store: store)
    }
}

@main
@MainActor
enum ExpansionLatencyTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = IslandStore()
        store.notchGeometry = NotchGeometry(
            screenFrame: CGRect(x: -10_000, y: -10_000, width: 1512, height: 982),
            cameraWidth: 220, cameraHeight: 38
        )
        let probe = ExpansionRenderProbe()
        let panel = NotchPanel(
            contentRect: store.notchGeometry.panelFrame(expanded: false, bodyHeight: 0),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let hosting = NotchHostingView(rootView: ProbedOverlay(store: store, probe: probe))
        hosting.sizingOptions = []
        panel.contentView = hosting
        defer { panel.close() }
        var resizes = [Bool]()
        var refreshes = 0
        var preparedBeforeExpansion = false
        // Exercise the production subscriber and real AppKit/SwiftUI re-entrant
        // layout, without launching AppDelegate, HTTP, polling, or a visible app.
        let subscription = AppDelegate.observeExpansion(in: store, resize: { expanded in
            if expanded && !store.expanded { preparedBeforeExpansion = true }
            resizes.append(expanded)
            panel.setFrame(store.notchGeometry.panelFrame(
                expanded: expanded, bodyHeight: store.measuredBodyHeight
            ), display: true, animate: false)
        }, requestRefresh: {
            refreshes += 1
        })
        defer { subscription.cancel() }
        panel.onHeaderClick = {
            DispatchQueue.main.async { store.expanded.toggle() }
        }

        func settle(_ seconds: TimeInterval = 0.12) {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            repeat {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            } while ProcessInfo.processInfo.systemUptime < deadline
        }

        func clickHeader() {
            let point = NSPoint(x: 28, y: panel.frame.height - panel.headerHeight / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
                )!
                expect(panel.handleHeaderPointerEvent(event), "The native header must own the pointer sequence")
            }
        }

        settle()
        var latencies = [Double]()
        for count in [4, 6, 100] {
            store.expanded = false
            let events = (0..<count).map { index in
                IslandEvent(type: "test", workspaceId: "/test/workspace-\(index % 3)",
                            paneKey: "test:\(index)", state: "working", combinedState: nil,
                            mainAgent: nil, receivedAt: Double(index),
                            terminalTitle: "Conversation \(index)")
            }
            store.replaceFromPoll(events)
            settle()
            expect(probe.lastExpanded == false, "The initial view must be collapsed")
            probe.firstExpandedAt = nil
            preparedBeforeExpansion = false
            let refreshesBefore = refreshes
            let start = ProcessInfo.processInfo.systemUptime
            clickHeader()
            // Crucially, publish no status, title, poll, or heartbeat after the
            // click. The old synchronous resize only refreshed after such input.
            settle(0.25)
            expect(store.expanded && probe.lastExpanded == true && probe.firstExpandedAt != nil,
                   "Opening must render without waiting for another Orca status update")
            expect(refreshes == refreshesBefore + 1,
                   "Opening must schedule exactly one background refresh")
            expect(preparedBeforeExpansion,
                   "The native canvas must be ready before SwiftUI starts the expansion transition")
            expect(panel.frame.maxY == store.notchGeometry.screenFrame.maxY,
                   "Expansion must keep the top edge anchored")
            latencies.append((probe.firstExpandedAt! - start) * 1000)

            clickHeader()
            settle()
            expect(!store.expanded && probe.lastExpanded == false,
                   "A second native header click must render the collapsed state")
            expect(refreshes == refreshesBefore + 1, "Collapsing must not request another refresh")
        }

        let refreshesBefore = refreshes
        store.expanded = true
        store.expanded = false
        store.expanded = true
        settle()
        expect(resizes.last == true && probe.lastExpanded == true,
               "Rapid toggles must finish with the final expanded state rendered")
        expect(refreshes == refreshesBefore + 1, "Superseded expansions must not trigger refreshes")
        expect(!panel.isVisible && !NSApp.isActive,
               "The regression harness must never show or activate a window")
        print("Expansion regression passed: 4/6/100 sessions render without follow-up events, canvas preflight before animation, rapid-toggle refresh coalescing, top anchoring. First body ms: \(latencies.map { String(format: "%.2f", $0) }.joined(separator: ", ")).")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
}
