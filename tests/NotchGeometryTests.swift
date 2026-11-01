// Run from the repository root:
// swiftc companion/Sources/OrcaIsland/NotchGeometry.swift tests/NotchGeometryTests.swift -o .validation/notch-geometry-tests
// .validation/notch-geometry-tests
import AppKit

@main
enum NotchGeometryTests {
    static func main() {
        let builtin = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            cameraWidth: 220,
            cameraHeight: 38
        )
        expect(builtin.hasNotch, "The physical camera must be detected")
        equal(builtin.collapsedWidth, 364, "The camera has 72pt of content on each side")
        equal(builtin.topBarHeight, 38, "The closed island follows the camera height")
        equal(builtin.expandedWidth, 440, "The conversation list has readable width")
        equal(builtin.maximumBodyHeight, 420, "Large screens cap body height at 420pt")
        let closed = builtin.panelFrame(expanded: false, bodyHeight: 1_000)
        equal(closed.height, 38, "Collapsed geometry must ignore the list height")
        checkFrame(closed, on: builtin)

        // 0, 1, 4 and many conversations: the view supplies its measured body height.
        for (body, expected) in [(CGFloat(0), CGFloat(44)), (84, 84), (240, 240), (2_000, 420)] {
            let frame = builtin.panelFrame(expanded: true, bodyHeight: body)
            equal(frame.height, 38 + expected, "Expanded height follows content and then caps")
            checkFrame(frame, on: builtin)
        }

        let external = NotchGeometry(
            screenFrame: CGRect(x: -1920, y: -400, width: 1920, height: 1080),
            cameraWidth: 0,
            cameraHeight: 0
        )
        expect(!external.hasNotch, "An external screen must not reserve a physical camera")
        equal(external.topBarHeight, 32, "External displays use a 32pt header")
        equal(external.collapsedWidth, 240, "External displays use a compact closed island")
        checkFrame(external.panelFrame(expanded: false, bodyHeight: 0), on: external)
        checkFrame(external.panelFrame(expanded: true, bodyHeight: 120), on: external)

        let small = NotchGeometry(
            screenFrame: CGRect(x: -320, y: 120, width: 320, height: 400),
            cameraWidth: 0,
            cameraHeight: 0
        )
        equal(small.expandedWidth, 320, "The panel must not exceed a narrow screen")
        equal(small.maximumBodyHeight, 208, "Small screens cap the panel at 60% height")
        checkFrame(small.panelFrame(expanded: true, bodyHeight: 2_000), on: small)

        let wideCamera = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            cameraWidth: 300,
            cameraHeight: 38
        )
        equal(wideCamera.expandedWidth, wideCamera.collapsedWidth + 40, "Wide notches still expand")
        checkFrame(wideCamera.panelFrame(expanded: true, bodyHeight: 44), on: wideCamera)
        print("Notch geometry checks passed: built-in camera, external screen, measured list heights, screen bounds and top anchoring.")
    }

    private static func checkFrame(_ frame: CGRect, on geometry: NotchGeometry) {
        equal(frame.maxY, geometry.screenFrame.maxY, "The island must touch the screen's top edge")
        equal(frame.midX, geometry.screenFrame.midX, "The island must remain centered on its screen")
        expect(frame.minX >= geometry.screenFrame.minX, "The panel must stay inside the left edge")
        expect(frame.maxX <= geometry.screenFrame.maxX, "The panel must stay inside the right edge")
        expect(frame.minY >= geometry.screenFrame.minY, "The panel must stay inside the bottom edge")
    }

    private static func equal(_ value: CGFloat, _ expected: CGFloat, _ message: String) {
        expect(abs(value - expected) < 0.001, "\(message): expected \(expected), received \(value)")
    }

    private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
}
