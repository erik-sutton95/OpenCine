import AppKit
import OpenCineDesktopKit
import SwiftUI

/// The strip of camera tabs across the top of the OpenCine window.
struct TabStrip: View {
    @Bindable var model: DockModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.modules) { module in
                let selected = model.selectedID == module.id
                Button {
                    if module.phase == .crashed {
                        model.restart(module.id)
                    }
                    model.select(module.id)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(color(for: module)).frame(width: 8, height: 8)
                        Text(module.module.manifest.displayName).font(.system(size: 13, weight: .medium))
                        if module.phase == .crashed {
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
            if model.driver.state == .awaitingApproval, model.problem == nil {
                Button("Turn on camera driver") {
                    NSWorkspace.shared.open(DriverController.approvalSettingsURL)
                }
                .font(.system(size: 12, weight: .medium))
                .accessibilityHint("Opens System Settings. Turn on OpenCine Camera under Camera Extensions.")
            } else {
                Text(driverText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).help(driverText)
            }
        }
        .padding(.leading, 84).padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .background(Color(white: 0.11))
        // The strip shares the title bar's row with the window buttons.
        .ignoresSafeArea()
    }

    private func color(for module: ModuleProcess) -> Color {
        if module.phase == .crashed { return .red }
        switch module.status {
        case .live: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private func accessibilityLabel(for module: ModuleProcess) -> String {
        let name = module.module.manifest.displayName
        if module.phase == .crashed { return "\(name), stopped. Restart." }
        switch module.status {
        case .live(let camera): return "\(name), live\(camera.map { ", \($0)" } ?? "")"
        case .connecting: return "\(name), connecting"
        case .failed(let reason): return "\(name), \(reason)"
        case .idle: return "\(name), no camera connected"
        }
    }

    private var driverText: String {
        if let problem = model.problem { return problem }
        switch model.driver.state {
        case .checking: return "Checking camera driver"
        case .notInstalled: return "Installing camera driver"
        case .awaitingApproval: return ""
        case .installed: return ""
        case .restartNeeded: return "Restart the Mac to finish the camera driver"
        case .failed(let reason): return "Camera driver: \(reason)"
        }
    }
}
