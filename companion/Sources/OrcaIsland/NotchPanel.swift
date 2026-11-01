import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    var headerHeight: CGFloat = 38
    var onHeaderClick: (() -> Void)?
    private(set) var headerClickCount = 0
    private(set) var pointerDownCount = 0
    private var headerPress: (frame: NSRect, height: CGFloat)?

    override func sendEvent(_ event: NSEvent) {
        if !handleHeaderPointerEvent(event) {
            super.sendEvent(event)
        }
    }

    // Return true only for a pointer sequence owned by the header. Keeping this
    // routing decision separate also permits testing without showing a window.
    func handleHeaderPointerEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pointerDownCount += 1
            headerPress = nil
            if isInsideHeader(event.locationInWindow) {
                headerPress = (frame, headerHeight)
                return true
            }
        case .leftMouseDragged:
            if headerPress != nil { return true }
        case .leftMouseUp:
            if let press = headerPress {
                headerPress = nil
                // Own the complete pointer sequence so SwiftUI cannot also toggle.
                // A completion or screen change while held cancels the old click.
                if press.frame == frame, press.height == headerHeight,
                   isInsideHeader(event.locationInWindow) {
                    headerClickCount += 1
                    onHeaderClick?()
                }
                return true
            }
        default:
            break
        }
        return false
    }

    private func isInsideHeader(_ point: NSPoint) -> Bool {
        let size = contentRect(forFrameRect: frame).size
        guard headerHeight.isFinite, headerHeight > 0 else { return false }
        let height = min(headerHeight, size.height)
        return NSRect(x: 0, y: size.height - height, width: size.width, height: height)
            .contains(point)
    }

    // AppKit normally keeps floating panels below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
