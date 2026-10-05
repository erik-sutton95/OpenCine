#if os(iOS)
    import CoreImage.CIFilterBuiltins
    import MonitorUI
    import SwiftUI

    /// Reveals credentials only while the operator has this sheet open: the camera Wi-Fi join code as
    /// a QR code, dismissed when the app leaves the foreground, the network changes or live ends.
    /// `appName` names the app the watching device returns to.
    public struct WatcherWiFiCodeView: View {
        public var appName: String
        public var ssid: String?
        public var joinCode: String?
        public var isLive: Bool
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        @State private var code: CGImage?

        public init(appName: String, ssid: String?, joinCode: String?, isLive: Bool) {
            self.appName = appName
            self.ssid = ssid
            self.joinCode = joinCode
            self.isLive = isLive
        }

        public var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        Text("Join camera Wi-Fi")
                            .font(MonitorTheme.font(22, weight: .bold))
                        Text(ssid ?? "Camera Wi-Fi")
                            .font(MonitorTheme.font(16, weight: .medium))
                        if scenePhase == .active, isLive, let code {
                            Image(decorative: code, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(maxWidth: 280)
                                .padding(24)
                                .background(.white)
                                .privacySensitive()
                        } else {
                            Text(
                                "Wi-Fi code unavailable. Reconnect the camera or join its Wi-Fi in Settings."
                            )
                        }
                        Text(
                            "On the watching device, open Camera and scan this code. Tap Join Network, then return to \(appName) → Watch a feed."
                        )
                        Text(
                            "This code shares the camera’s Wi-Fi password. Keep this phone connected to the camera; watching devices only join the shared feed."
                        )
                        .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                }
                .monitorScrollFade()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .task {
                guard let payload = joinCode else { return }
                let filter = CIFilter.qrCodeGenerator()
                filter.message = Data(payload.utf8)
                filter.correctionLevel = "M"
                guard let output = filter.outputImage else { return }
                let bounds = output.extent.insetBy(dx: -4, dy: -4)
                let white = CIImage(color: CIColor.white).cropped(to: bounds)
                code = CIContext().createCGImage(output.composited(over: white), from: bounds)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    code = nil
                    dismiss()
                }
            }
            .onChange(of: ssid) { _, _ in
                code = nil
                dismiss()
            }
            .onChange(of: isLive) { _, live in
                if !live {
                    code = nil
                    dismiss()
                }
            }
        }
    }
#endif
