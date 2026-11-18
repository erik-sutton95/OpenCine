#if os(iOS)
import MonitorUI
import OpenCineAppKit
import OpenCineCore
import SwiftUI

/// The Controls tab's camera presets card: save the connected camera's exposure and white balance
/// under a name, recall or delete a saved preset, and read what the last recall skipped. Kotlin
/// twin: `SettingsCameraPresets`.
struct MonitorSettingsCameraPresetsCard: View {
    let model: CameraSettingsPresetsModel
    let feedback: () -> Void
    @State private var naming = false
    @State private var name = ""
    @State private var deleting: CameraSettingsPreset?

    var body: some View {
        MonitorSettingsRowCard(title: CameraSettingsPresetCopy.title) {
            if model.scope == nil {
                note(CameraSettingsPresetCopy.connectFirst)
            } else {
                MonitorSettingsInlineRow(title: "Save current settings", help: CameraSettingsPresetCopy.help,
                    showTopDivider: false) {
                    MonitorSettingsActionPill(title: "Save") {
                        feedback(); name = ""; naming = true
                    }
                    .disabled(!model.canSave).opacity(model.canSave ? 1 : 0.4)
                    .accessibilityIdentifier("monitor.settings.presets.save")
                }
                let presets = model.presets
                if presets.isEmpty { note(CameraSettingsPresetCopy.empty) }
                ForEach(presets) { preset in row(preset) }
            }
            if let message = model.message { note(message).accessibilityIdentifier("monitor.settings.presets.message") }
        }
        .alert("Save preset", isPresented: $naming) {
            TextField(model.suggestedName, text: $name)
            Button("Save") { model.save(name: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the camera's current exposure and white balance.")
        }
        .alert("Delete preset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting) { preset in
            Button("Delete", role: .destructive) { model.delete(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text("\(preset.name) is removed from this phone. The camera is unchanged.")
        }
    }

    private func row(_ preset: CameraSettingsPreset) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(MonitorTheme.border).frame(height: 1)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(MonitorTheme.font(13, weight: .semibold))
                        .foregroundStyle(MonitorTheme.text).lineLimit(1)
                    Text(CameraSettingsPresetCopy.summary(preset)).font(MonitorTheme.font(11))
                        .foregroundStyle(MonitorTheme.muted).lineLimit(2)
                }
                Spacer(minLength: 8)
                MonitorSettingsActionPill(title: "Recall") {
                    feedback()
                    Task { await model.recall(preset) }
                }
                .disabled(!model.canRecall).opacity(model.canRecall ? 1 : 0.4)
                .accessibilityLabel("Recall \(preset.name)")
                .accessibilityIdentifier("monitor.settings.presets.recall")
                MonitorSettingsActionPill(title: "Delete", tint: MonitorTheme.muted, background: .clear) {
                    feedback(); deleting = preset
                }
                .disabled(model.recalling)
                .accessibilityLabel("Delete \(preset.name)")
                .accessibilityIdentifier("monitor.settings.presets.delete")
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 50)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}
#endif
