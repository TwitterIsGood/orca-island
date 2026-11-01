import AppKit

/// Layout in AppKit screen coordinates, where the top edge is `frame.maxY`.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat

    init(screenFrame: CGRect, cameraWidth: CGFloat, cameraHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.cameraWidth = min(max(0, cameraWidth), screenFrame.width)
        self.cameraHeight = min(max(0, cameraHeight), screenFrame.height)
    }

    init(screen: NSScreen) {
        let cameraHeight = screen.safeAreaInsets.top
        let cameraWidth: CGFloat
        if cameraHeight > 0 {
            if let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea,
               right.minX > left.maxX {
                cameraWidth = right.minX - left.maxX
            } else {
                // Some display configurations omit the auxiliary rectangles.
                cameraWidth = 220
            }
        } else {
            cameraWidth = 0
        }
        self.init(screenFrame: screen.frame, cameraWidth: cameraWidth, cameraHeight: cameraHeight)
    }

    static let fallback = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        cameraWidth: 0,
        cameraHeight: 0
    )

    var hasNotch: Bool { cameraWidth > 0 && cameraHeight > 0 }

    var topBarHeight: CGFloat {
        min(hasNotch ? cameraHeight : 32, screenFrame.height)
    }

    var collapsedWidth: CGFloat {
        min(hasNotch ? cameraWidth + 144 : 240, screenFrame.width)
    }

    var expandedWidth: CGFloat {
        min(max(440, collapsedWidth + 40), screenFrame.width)
    }

    var maximumBodyHeight: CGFloat {
        max(0, min(420, screenFrame.height * 0.6 - topBarHeight))
    }

    func panelFrame(expanded: Bool, bodyHeight: CGFloat) -> CGRect {
        let width = expanded ? expandedWidth : collapsedWidth
        let measuredHeight = bodyHeight.isNaN ? 44 : bodyHeight
        let visibleBodyHeight = expanded ? min(max(44, measuredHeight), maximumBodyHeight) : 0
        let height = topBarHeight + visibleBodyHeight
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }
}
