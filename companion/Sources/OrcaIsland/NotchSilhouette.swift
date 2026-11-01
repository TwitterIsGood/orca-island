import SwiftUI

struct NotchSilhouette: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = 6
        let radius = min(bottomRadius, rect.height / 2)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + shoulder),
                              control: CGPoint(x: right, y: rect.minY))
            path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: right - radius, y: rect.maxY),
                              control: CGPoint(x: right, y: rect.maxY))
            path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - radius),
                              control: CGPoint(x: left, y: rect.maxY))
            path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: left, y: rect.minY))
            path.closeSubpath()
        }
    }
}
