#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// The monitor while "1080p from camera" runs: the camera's own picture as it is relayed, fit to
/// the screen on black, with the live stream controls and the camera status line on top. Assists,
/// scopes and camera controls are off in this mode; the app shows this in place of its monitor
/// while `LiveStreamCoordinator.cameraStreamActive` is true.
public struct LiveStreamCameraMonitor: View {
    let coordinator: LiveStreamCoordinator

    public init(coordinator: LiveStreamCoordinator) { self.coordinator = coordinator }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let display = coordinator.cameraDisplay {
                CameraDisplayView(display: display)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("monitor.livestream.cameraPicture")
                    .accessibilityLabel("Camera picture")
            }
            LiveStreamMonitorOverlay(coordinator: coordinator)
        }
    }
}

private struct CameraDisplayView: UIViewRepresentable {
    let display: LiveStreamCameraDisplay

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.attach(display.layer)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) { view.attach(display.layer) }

    final class HostView: UIView {
        private weak var hosted: CALayer?

        func attach(_ layer: CALayer) {
            guard hosted !== layer else { return }
            hosted?.removeFromSuperlayer()
            self.layer.addSublayer(layer)
            hosted = layer
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
#endif
