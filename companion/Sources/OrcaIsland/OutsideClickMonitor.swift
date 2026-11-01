import AppKit

enum OutsideClickGeometry {
    /// CGEvent uses a top-left origin on the primary screen; AppKit uses bottom-left.
    /// The primary screen's top is the reference for every display, including those
    /// placed above or to the left of it. NSScreen.main can instead be a secondary display.
    static func appKitPoint(fromQuartz point: CGPoint, primaryScreenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }

    static func shouldCollapse(at point: CGPoint, visibleFrame: CGRect,
                               isVisible: Bool, isExpanded: Bool) -> Bool {
        guard isVisible, isExpanded, !visibleFrame.isEmpty,
              point.x.isFinite, point.y.isFinite,
              visibleFrame.minX.isFinite, visibleFrame.minY.isFinite,
              visibleFrame.maxX.isFinite, visibleFrame.maxY.isFinite else { return false }
        // Include the border: a click exactly on the top edge belongs to the island.
        return point.x < visibleFrame.minX || point.x > visibleFrame.maxX
            || point.y < visibleFrame.minY || point.y > visibleFrame.maxY
    }
}

/// Registration is injectable so lifecycle and event forwarding can be tested
/// without displaying a panel or installing a real desktop mouse monitor.
struct OutsideClickEventMonitors {
    var addGlobal: (@escaping (NSEvent) -> Void) -> Any?
    var addLocal: (@escaping (NSEvent) -> NSEvent?) -> Any?
    var remove: (Any) -> Void

    static let live = OutsideClickEventMonitors(
        addGlobal: { NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: $0) },
        addLocal: { NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: $0) },
        remove: { NSEvent.removeMonitor($0) }
    )
}

@MainActor
final class OutsideClickMonitor {
    private weak var panel: NSPanel?
    private let isExpanded: () -> Bool
    private let collapse: () -> Void
    private let visibleFrame: (() -> NSRect)?
    private let monitors: OutsideClickEventMonitors
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isRunning = false

    init(panel: NSPanel, isExpanded: @escaping () -> Bool, collapse: @escaping () -> Void,
         visibleFrame: (() -> NSRect)? = nil,
         monitors: OutsideClickEventMonitors = .live) {
        self.panel = panel
        self.isExpanded = isExpanded
        self.collapse = collapse
        self.visibleFrame = visibleFrame
        self.monitors = monitors
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // AppKit guarantees both monitor handlers run on the main thread. Handle
        // synchronously so a queued outside click cannot close a later expansion.
        globalMonitor = monitors.addGlobal { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseDown(event) }
        }
        localMonitor = monitors.addLocal { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseDown(event) }
            // Observing a click must never swallow or repost it. Inside clicks
            // continue to the panel's native header/row handlers exactly once.
            return event
        }
    }

    func stop() {
        isRunning = false
        if let token = globalMonitor { monitors.remove(token) }
        if let token = localMonitor { monitors.remove(token) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit {
        if let token = globalMonitor { monitors.remove(token) }
        if let token = localMonitor { monitors.remove(token) }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard isRunning, let panel, panel.isVisible, isExpanded(),
              event.type == .leftMouseDown || event.type == .rightMouseDown else { return }
        let point: CGPoint
        if let cgEvent = event.cgEvent, let primaryScreen = NSScreen.screens.first {
            point = OutsideClickGeometry.appKitPoint(
                fromQuartz: cgEvent.location, primaryScreenFrame: primaryScreen.frame
            )
        } else if let window = event.window {
            point = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            // NSEvent locations without an associated window are already global.
            point = event.locationInWindow
        }
        let frame = visibleFrame?() ?? panel.contentRect(forFrameRect: panel.frame)
        if OutsideClickGeometry.shouldCollapse(at: point, visibleFrame: frame,
                                               isVisible: panel.isVisible, isExpanded: isExpanded()) {
            collapse()
        }
    }
}
