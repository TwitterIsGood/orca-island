import AppKit

private final class VisibilityProbePanel: NSPanel {
    var simulatedVisibility = false
    override var isVisible: Bool { simulatedVisibility }
}

@main
@MainActor
enum OutsideClickMonitorTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        checkGeometry()
        checkLifecycleAndRouting()
        expect(!app.isActive, "The test must not activate the application")
        expect(foregroundBefore == NSWorkspace.shared.frontmostApplication?.processIdentifier,
               "Outside-click handling must preserve the foreground application")
        print("Outside click checks passed: primary/negative/above-screen coordinates, inside/header clicks, visible animation bounds, collapsed/hidden guards, unchanged event delivery, monitor cleanup and no activation.")
    }

    private static func checkGeometry() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        expect(OutsideClickGeometry.appKitPoint(fromQuartz: CGPoint(x: 800, y: 22), primaryScreenFrame: primary)
               == CGPoint(x: 800, y: 960), "Primary display coordinates must flip around the screen's top")
        expect(OutsideClickGeometry.appKitPoint(fromQuartz: CGPoint(x: -1400, y: 1100), primaryScreenFrame: primary)
               == CGPoint(x: -1400, y: -118), "Left/below displays retain negative coordinates")
        expect(OutsideClickGeometry.appKitPoint(fromQuartz: CGPoint(x: 100, y: -400), primaryScreenFrame: primary)
               == CGPoint(x: 100, y: 1382), "Displays above the primary retain their positive AppKit height")

        let frame = CGRect(x: -1800, y: -120, width: 440, height: 220)
        func outside(_ point: CGPoint, visible: Bool = true, expanded: Bool = true) -> Bool {
            OutsideClickGeometry.shouldCollapse(at: point, visibleFrame: frame,
                                                isVisible: visible, isExpanded: expanded)
        }
        expect(!outside(CGPoint(x: -1780, y: 82)), "Header click must remain inside on a negative-coordinate display")
        expect(!outside(CGPoint(x: frame.maxX, y: frame.maxY)), "The top edge belongs to the panel")
        expect(!outside(CGPoint(x: -1500, y: -60)), "Body click must not collapse the panel")
        for point in [CGPoint(x: -1801, y: 0), CGPoint(x: -1359, y: 0),
                      CGPoint(x: -1500, y: 101), CGPoint(x: -1500, y: -121)] {
            expect(outside(point), "Every side outside the visible panel must dismiss")
        }
        expect(!outside(.zero, visible: false), "Hidden panels must ignore outside clicks")
        expect(!outside(.zero, expanded: false), "Collapsed panels must ignore outside clicks")
        expect(!OutsideClickGeometry.shouldCollapse(at: .zero, visibleFrame: .zero,
                                                    isVisible: true, isExpanded: true),
               "Missing layout geometry must not collapse the panel")
    }

    private static func checkLifecycleAndRouting() {
        let panel = VisibilityProbePanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 420),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let primary = NSScreen.screens.first!.frame
        let visible = NSRect(x: primary.midX - 220, y: primary.maxY - 200, width: 440, height: 200)
        var expanded = true
        var collapseCount = 0
        var registrations = 0
        var removed: [Int] = []
        var global: ((NSEvent) -> Void)?
        var local: ((NSEvent) -> NSEvent?)?
        let monitors = OutsideClickEventMonitors(
            addGlobal: { callback in registrations += 1; global = callback; return registrations },
            addLocal: { callback in registrations += 1; local = callback; return registrations },
            remove: { removed.append($0 as! Int) }
        )
        func event(at appKitPoint: CGPoint, type: CGEventType = .leftMouseDown) -> NSEvent {
            let quartz = CGPoint(x: appKitPoint.x, y: primary.maxY - appKitPoint.y)
            let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: quartz,
                                  mouseButton: type == .rightMouseDown ? .right : .left)!
            return NSEvent(cgEvent: cgEvent)!
        }
        var monitor: OutsideClickMonitor? = OutsideClickMonitor(
            panel: panel, isExpanded: { expanded },
            collapse: { collapseCount += 1; expanded = false },
            visibleFrame: { visible }, monitors: monitors
        )
        monitor!.start()
        monitor!.start()
        expect(registrations == 2 && monitor!.isRunning, "Repeated start must register only one monitor pair")
        let outside = event(at: CGPoint(x: visible.minX - 10, y: visible.midY))
        global!(outside)
        expect(collapseCount == 0, "An unordered/hidden panel ignores global events")
        panel.simulatedVisibility = true
        let header = event(at: CGPoint(x: visible.minX + 30, y: visible.maxY - 16))
        expect(local!(header) === header, "Local header events must pass through unchanged")
        expect(collapseCount == 0 && expanded, "Local header down must not dismiss before its native toggle")
        let body = event(at: CGPoint(x: visible.midX, y: visible.midY))
        global!(body)
        expect(collapseCount == 0, "Inside events use visible geometry, not the offscreen window frame")
        global!(outside)
        expect(collapseCount == 1 && !expanded, "An outside global click collapses synchronously")
        expect(local!(outside) === outside, "Outside local clicks still reach the originally clicked view")
        expect(collapseCount == 1, "Collapsed state prevents duplicate dismissal")
        expanded = true
        let right = event(at: CGPoint(x: visible.midX, y: visible.minY - 2), type: .rightMouseDown)
        expect(local!(right) === right && collapseCount == 2, "A right click outside dismisses without swallowing context-menu input")
        expanded = true
        global!(event(at: CGPoint(x: visible.minX - 2, y: visible.midY), type: .leftMouseUp))
        expect(collapseCount == 2, "Only mouse-down events may dismiss")
        monitor!.stop()
        monitor!.stop()
        expect(!monitor!.isRunning && removed == [1, 2], "Stop must remove both monitors exactly once")
        global!(outside)
        expect(collapseCount == 2, "Stale callbacks after stop cannot dismiss")
        monitor!.start()
        expect(registrations == 4, "A stopped monitor can restart with a fresh pair")
        monitor = nil
        expect(removed == [1, 2, 3, 4], "Deallocation must also remove any active monitor pair")
        global!(outside)
        expect(collapseCount == 2, "Callbacks must not retain the monitor")
        panel.simulatedVisibility = false
        expect(!panel.isKeyWindow && !panel.isMainWindow,
               "The harness must never order or focus the panel")
    }

    private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
}
