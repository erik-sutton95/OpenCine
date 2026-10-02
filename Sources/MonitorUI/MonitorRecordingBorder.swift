#if os(iOS)
import MonitorPresentation
import SwiftUI
import UIKit

/// REC tally on the physical screen bezel.
public struct MonitorRecordingBorder: View {
    private let cornerRadius: CGFloat
    public init(cornerRadius: CGFloat = 52) { self.cornerRadius = cornerRadius }
    @Environment(\.monitorPresentationIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    public var body: some View {
        // Core Animation owns the pulse: the render server animates opacity with
        // no per-step app or SwiftUI work for the whole take (a SwiftUI timeline
        // here cost about a third of the app's CPU while recording).
        MonitorRecordingBorderLayer(
            cornerRadius: cornerRadius, color: UIColor(MonitorTheme.recording),
            pulsing: isVisible && scenePhase == .active && !reduceMotion
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static let lineWidth: CGFloat = 4
    /// Approximate display corner. No public API; decorative, tuned to modern iPhones.
    static let displayCornerRadius: CGFloat = 52
}

/// Full-screen REC border: stroke plus glow on a precomputed shadow path, with a
/// render-server opacity pulse (same period and floor as `monitorPulse`).
private struct MonitorRecordingBorderLayer: UIViewRepresentable {
    let cornerRadius: CGFloat
    let color: UIColor
    let pulsing: Bool

    func makeUIView(context: Context) -> TallyView { TallyView() }

    func updateUIView(_ view: TallyView, context: Context) {
        view.configure(cornerRadius: cornerRadius, color: color, pulsing: pulsing)
    }

    final class TallyView: UIView {
        private let border = CAShapeLayer()
        private var cornerRadius: CGFloat = 0
        private var pulsing = false
        private static let pulseKey = "rec-pulse"

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            border.fillColor = nil
            border.lineWidth = MonitorRecordingBorder.lineWidth
            border.shadowOpacity = 0.55
            border.shadowRadius = 14
            border.shadowOffset = .zero
            layer.addSublayer(border)
        }

        required init?(coder: NSCoder) { nil }

        func configure(cornerRadius: CGFloat, color: UIColor, pulsing: Bool) {
            self.cornerRadius = cornerRadius
            border.strokeColor = color.cgColor
            border.shadowColor = color.cgColor
            self.pulsing = pulsing
            applyPulse()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            border.frame = bounds
            // strokeBorder: the stroke sits inside the bounds.
            let inset = MonitorRecordingBorder.lineWidth / 2
            let path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                cornerRadius: max(0, cornerRadius - inset)
            ).cgPath
            border.path = path
            border.shadowPath = path.copy(
                strokingWithWidth: MonitorRecordingBorder.lineWidth, lineCap: .butt,
                lineJoin: .miter, miterLimit: 10)
            CATransaction.commit()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Core Animation drops animations when a layer leaves the window.
            applyPulse()
        }

        private func applyPulse() {
            let active = pulsing && window != nil
            guard active != (border.animation(forKey: Self.pulseKey) != nil) else { return }
            guard active else {
                border.removeAnimation(forKey: Self.pulseKey)
                return
            }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = MonitorMotion.recPulseFloor
            pulse.duration = MonitorMotion.recPulseDuration / 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            pulse.isRemovedOnCompletion = false
            border.add(pulse, forKey: Self.pulseKey)
        }
    }
}

#endif
