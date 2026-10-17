#if os(iOS)
import SwiftUI

/// The Frame.io mark every app's delivery popup shows for the remote destination, drawn as a
/// vector so it follows the popup's foreground style and size.
public struct FrameioMark: View {
    public init() {}
    public var body: some View {
        FrameioMarkShape().fill(.foreground).aspectRatio(1, contentMode: .fit)
    }
}

private struct FrameioMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: point(7.5, 4))
        path.addArc(center: point(7.5, 6.5), radius: 2.5 * s, startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
        path.addLine(to: point(5, 17.5))
        path.addArc(center: point(7.5, 17.5), radius: 2.5 * s, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: point(9.5, 20))
        path.addArc(center: point(9.5, 17.5), radius: 2.5 * s, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: point(12, 14))
        path.addLine(to: point(15.5, 14))
        path.addArc(center: point(15.5, 11.5), radius: 2.5 * s, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        path.addLine(to: point(12, 9))
        path.addLine(to: point(12, 6.5))
        path.addArc(center: point(9.5, 6.5), radius: 2.5 * s, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        path.closeSubpath()
        return path
    }
}
#endif
