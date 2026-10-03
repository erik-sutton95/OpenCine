#if os(iOS)
import SwiftUI

/// Connection facts are already interpreted by the source; these rows own only presentation.
public struct MonitorConnectionSettings: View {
    private let transport: String
    private let transportHelp: String
    private let phase: String
    private let phaseHelp: String
    private let network: String?
    private let networkHelp: String

    public init(transport: String, transportHelp: String, phase: String, phaseHelp: String,
        network: String? = nil, networkHelp: String = "") {
        self.transport = transport; self.transportHelp = transportHelp
        self.phase = phase; self.phaseHelp = phaseHelp
        self.network = network; self.networkHelp = networkHelp
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "Connection") {
            MonitorSettingsInlineRow(title: "Current Transport", help: transportHelp, showTopDivider: false) {
                MonitorSettingsValueText(value: transport)
            }
            MonitorSettingsInlineRow(title: "Phase", help: phaseHelp) {
                MonitorSettingsValueText(value: phase)
            }
            if let network {
                MonitorSettingsInlineRow(title: "Camera Wi-Fi", help: networkHelp) {
                    MonitorSettingsValueText(value: network)
                }
            }
        }
    }
}

public struct MonitorSavedCameraSummary: Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let network: String?
    public init(id: String, name: String, detail: String, network: String? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.network = network
    }
}

/// Read-only saved-camera summaries do not start pairing or read credential storage.
public struct MonitorSavedCameraSettings: View {
    private let cameras: [MonitorSavedCameraSummary]
    private let emptyHelp: String
    public init(cameras: [MonitorSavedCameraSummary], emptyHelp: String) {
        self.cameras = cameras; self.emptyHelp = emptyHelp
    }

    public var body: some View {
        MonitorSettingsRowCard(title: "Your cameras") {
            if cameras.isEmpty {
                MonitorSettingsInlineRow(title: "Saved", help: emptyHelp, showTopDivider: false) {
                    MonitorSettingsValueText(value: "None")
                }
            } else {
                MonitorSnapshotRows(Array(cameras.enumerated()), id: \.element.id) { index, camera in
                    MonitorSettingsInlineRow(title: camera.name, help: camera.detail, showTopDivider: index > 0) {
                        MonitorSettingsValueText(value: camera.network ?? "Saved")
                    }
                }
            }
        }
    }
}
#endif
