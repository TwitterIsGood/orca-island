import AppKit

private final class EventProbe: NSView {
    var downCount = 0
    var upCount = 0
    var dragCount = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downCount += 1 }
    override func mouseUp(with event: NSEvent) { upCount += 1 }
    override func mouseDragged(with event: NSEvent) { dragCount += 1 }
}

@main
@MainActor
enum NotchPanelInputTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let panel = NotchPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 364, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let probe = EventProbe(frame: NSRect(x: 0, y: 0, width: 364, height: 38))
        panel.contentView = probe
        defer { panel.close() }
        var actions = 0
        panel.onHeaderClick = { actions += 1 }
        var eventNumber = 0

        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            eventNumber += 1
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            panel.sendEvent(event(type, point))
        }
        func click(_ point: NSPoint) {
            let countBefore = actions
            send(.leftMouseDown, point)
            expect(actions == countBefore, "Pointer down must not toggle the island")
            send(.leftMouseUp, point)
            expect(actions == countBefore + 1, "A header pointer sequence toggles exactly once")
        }
        func headerPoint(_ x: CGFloat) -> NSPoint {
            NSPoint(x: x, y: panel.frame.height - panel.headerHeight / 2)
        }

        click(headerPoint(28))
        click(headerPoint(336))
        expect(panel.headerClickCount == 2 && panel.pointerDownCount == 2,
               "Both wings must record real pointer clicks")
        expect(probe.downCount == 0 && probe.upCount == 0,
               "Header events must not also reach the SwiftUI/content view")

        send(.leftMouseDown, headerPoint(28))
        send(.leftMouseDragged, NSPoint(x: -20, y: 18))
        send(.leftMouseUp, NSPoint(x: -20, y: 18))
        expect(actions == 2, "Releasing outside the header cancels the click")
        send(.leftMouseDown, headerPoint(336))
        send(.leftMouseDragged, NSPoint(x: 400, y: 18))
        send(.leftMouseDragged, headerPoint(336))
        send(.leftMouseUp, headerPoint(336))
        expect(actions == 3, "Dragging out and back in keeps native button semantics")
        send(.leftMouseUp, headerPoint(28))
        expect(actions == 3, "An unmatched pointer up must never toggle")

        // The window can live on any screen; header tests use window-local coordinates.
        panel.setFrame(NSRect(x: -2_300, y: 1_200, width: 440, height: 220), display: false)
        click(headerPoint(30))
        click(headerPoint(410))
        expect(actions == 5, "Expanded clicks remain valid on a displaced screen")

        let bodyPoint = NSPoint(x: 40, y: 40)
        // AppKit does not dispatch into content views of an unordered window.
        // Test the exact routing decision used by sendEvent without displaying it.
        expect(!panel.handleHeaderPointerEvent(event(.leftMouseDown, bodyPoint)),
               "Body pointer down must pass through to AppKit")
        expect(!panel.handleHeaderPointerEvent(event(.leftMouseDragged, NSPoint(x: 42, y: 42))),
               "Body drag must pass through to AppKit")
        expect(!panel.handleHeaderPointerEvent(event(.leftMouseUp, bodyPoint)),
               "Body pointer up must pass through to AppKit")
        expect(actions == 5, "Body clicks must not toggle the header")

        send(.leftMouseDown, headerPoint(30))
        expect(panel.handleHeaderPointerEvent(event(.leftMouseDragged, bodyPoint)),
               "A header drag must be consumed even outside the header")
        expect(panel.handleHeaderPointerEvent(event(.leftMouseUp, bodyPoint)),
               "A header release must not leak an unmatched up into the body")
        expect(actions == 5, "Dragging from the header into the body cancels without activating a row")
        expect(!panel.handleHeaderPointerEvent(event(.leftMouseUp, bodyPoint)),
               "Tracking must end after a consumed release")

        send(.leftMouseDown, headerPoint(30))
        panel.setFrame(NSRect(x: -2_310, y: 1_200, width: 460, height: 240), display: false)
        send(.leftMouseUp, headerPoint(30))
        expect(actions == 5, "An automatic layout change while held cancels the stale click")
        send(.leftMouseDown, headerPoint(30))
        panel.headerHeight = 32
        send(.leftMouseUp, headerPoint(30))
        expect(actions == 5, "A header-height change while held cancels the stale click")
        click(headerPoint(30))
        expect(actions == 6 && panel.headerClickCount == actions,
               "Subsequent clicks recover after cancellation")
        expect(panel.pointerDownCount == 11,
               "Pointer diagnostics include every left down, including canceled and body presses")
        expect(!panel.handleHeaderPointerEvent(event(.rightMouseDown, headerPoint(30))),
               "Right pointer down must retain AppKit's normal routing")
        expect(!panel.handleHeaderPointerEvent(event(.rightMouseUp, headerPoint(30))),
               "Right pointer up must retain AppKit's normal routing")
        expect(!panel.isVisible && !panel.isKeyWindow && !panel.isMainWindow && !app.isActive,
               "The input harness must never display or activate a window")
        expect(foregroundBefore == NSWorkspace.shared.frontmostApplication?.processIdentifier,
               "Pointer handling must preserve the foreground application")
        print("Notch panel input checks passed: both wings, single-toggle, drag cancellation, body routing, local coordinates, layout changes, no activation.")
    }

    private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
}
