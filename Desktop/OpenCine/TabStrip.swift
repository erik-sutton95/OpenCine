import AppKit
import OpenCineDesktopKit
import SwiftUI

/// The dock's own window, shown only while no camera module can show the tabs: every tab with its
/// state, Restart on a stopped one, and the driver notice.
struct TabStrip: View {
    @Bindable var model: DockModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(model.modules) { module in
                    let selected = model.selectedID == module.id
                    let state = DockModel.tabState(of: module)
                    Button {
                        model.select(module.id)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(color(for: state)).frame(width: 8, height: 8)
                            Text(module.module.manifest.displayName).font(.system(size: 13, weight: .medium))
                            if state == .stopped {
                                Text("Restart").font(.system(size: 12))
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selected ? Color.white.opacity(0.16) : .clear, in: .rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: module))
                }
                Spacer(minLength: 12)
                if let notice = model.notice {
                    if notice.opensDriverSettings {
                        Button(notice.text) {
                            NSWorkspace.shared.open(DriverController.approvalSettingsURL)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityHint("Opens System Settings. Turn on OpenCine Camera under Camera Extensions.")
                    } else {
                        Text(notice.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle).help(notice.text)
                    }
                }
            }
            .frame(minHeight: 44)
            Text(model.modules.isEmpty ? "No camera module is installed" : "No camera is running")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.11))
    }

    private func color(for state: DockTab.State) -> Color {
        switch state {
        case .live: .green
        case .connecting: .yellow
        case .failed, .stopped: .red
        case .idle: .gray
        }
    }

    private func accessibilityLabel(for module: ModuleProcess) -> String {
        let name = module.module.manifest.displayName
        if module.phase == .crashed || module.phase == .stopped { return "\(name), stopped. Restart." }
        switch module.status {
        case .live(let camera): return "\(name), live\(camera.map { ", \($0)" } ?? "")"
        case .connecting: return "\(name), connecting"
        case .failed(let reason): return "\(name), \(reason)"
        case .idle: return "\(name), no camera connected"
        }
    }
}
