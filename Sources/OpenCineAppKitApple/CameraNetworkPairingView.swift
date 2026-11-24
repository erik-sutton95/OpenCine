#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCore
    import SwiftUI

    /// The pair page's camera network on a computer: "Cameras join <network>" with Change network,
    /// and the network page whenever `pairing` asks. The page offers the computer's current
    /// network, the saved ones and Other network; never the camera's Wi-Fi or a hotspot.
    @available(macOS 14, *)
    public struct CameraNetworkPairingView: View {
        let pairing: CameraNetworkPairing
        let model: CamerasModel
        let brand: StationNetworkBrand
        let services: StationNetworkServices

        public init(
            pairing: CameraNetworkPairing, model: CamerasModel, brand: StationNetworkBrand,
            services: StationNetworkServices
        ) {
            self.pairing = pairing
            self.model = model
            self.brand = brand
            self.services = services
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let network = pairing.network, model.attempts.isEmpty {
                    HStack(spacing: 10) {
                        MonitorIcon.wifi.frame(width: 16, height: 16).foregroundStyle(MonitorTheme.accent)
                        Text("Cameras join \(network)").font(MonitorTheme.font(13)).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Change network") { pairing.change() }
                            .font(MonitorTheme.font(13, weight: .semibold))
                            .accessibilityIdentifier("pair.cameraNetwork.change")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("pair.cameraNetwork")
                }
            }
            .sheet(
                item: Binding(
                    get: { pairing.asking },
                    set: { if $0 == nil, pairing.asking != nil { pairing.cancel() } })
            ) { ask in
                StationNetworkSetupView(
                    context: .multiview, brand: brand, services: services, scan: nil,
                    save: { network in
                        pairing.chose(network, in: model)
                        return true
                    },
                    close: { pairing.cancel() },
                    path: ask.suggested.map { [.password($0)] } ?? [],
                    complete: { pairing.cancel() }
                )
                .presentationBackground(MonitorTheme.background)
            }
        }
    }
#endif
