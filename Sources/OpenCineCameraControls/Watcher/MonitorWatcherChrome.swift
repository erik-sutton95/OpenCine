#if os(iOS)
import MonitorPresentation
import MonitorUI
import SwiftUI

/// Common watcher controls; the app supplies decoded picture and transport facts separately.
public struct MonitorWatcherChrome<Palette: LiveChromePalette, Tools: View>: View {
    private let value: MonitorWatcherPresentation
    private let confirmRecording: Bool
    private let palette: Palette.Type
    private let tools: () -> Tools
    private let action: (MonitorWatcherAction) -> Void
    @Binding private var clean: Bool
    @State private var interaction = MonitorWatcherInteraction()

    public init(value: MonitorWatcherPresentation, clean: Binding<Bool>, confirmRecording: Bool,
        palette: Palette.Type, action: @escaping (MonitorWatcherAction) -> Void,
        @ViewBuilder tools: @escaping () -> Tools) {
        self.value = value; self._clean = clean; self.confirmRecording = confirmRecording
        self.palette = palette; self.action = action; self.tools = tools
    }
    public var body: some View {
        VStack(spacing: 8) {
            header
            if !clean { telemetry }
            Spacer(minLength: 0)
            if let notice = value.notice { connectionNotice(notice) }
            if !clean { controls; tools().frame(height: 58) }
        }
        .onChange(of: value.context, initial: true) { _, context in interaction.update(context: context, clean: clean) }
        .onChange(of: clean) { _, clean in interaction.update(context: value.context, clean: clean) }
        .onDisappear { interaction.cancel() }
        .confirmationDialog(value.context.recording ? "Stop recording?" : "Start recording?",
            isPresented: Binding(get: { interaction.pendingRecording != nil }, set: { if !$0 { interaction.cancel() } }),
            titleVisibility: .visible) {
            Button(value.context.recording ? "Stop recording" : "Start recording") {
                if let command = interaction.confirmRecording(context: value.context) { send(command) }
            }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button("Leave") { send(.leave) }.accessibilityIdentifier("watcher.leave")
            VStack(alignment: .leading, spacing: 2) {
                Text(value.hostTitle).font(MonitorTheme.font(13, weight: .semibold)).lineLimit(1)
                if !clean {
                    Text(value.receivedFPS.map { "WATCHING · \($0) fps" } ?? "WATCHING")
                        .font(MonitorTheme.font(10, weight: .medium)).foregroundStyle(Palette.text.opacity(0.65))
                }
            }
            Spacer(minLength: 4)
            if value.context.recording {
                HStack(spacing: 5) { Circle().fill(Palette.rec).frame(width: 7, height: 7); Text("REC") }
                    .foregroundStyle(Palette.rec).accessibilityLabel("Camera recording")
            }
            Button(clean ? "Controls" : "Clean view") { interaction.cancel(); clean.toggle() }
        }
        .font(MonitorTheme.font(12, weight: .semibold)).foregroundStyle(Palette.text)
        .padding(.horizontal, 12).padding(.vertical, 9).monitorGlass(in: Capsule())
    }
    private var telemetry: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(value.readings) { reading in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.id).font(MonitorTheme.font(8, weight: .medium)).foregroundStyle(Palette.text.opacity(0.65))
                        Text(reading.value ?? "--").font(MonitorTheme.font(12, weight: .semibold)).foregroundStyle(Palette.text)
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }.monitorScrollFade(.horizontal).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
    private func connectionNotice(_ notice: MonitorWatcherNotice) -> some View {
        VStack(spacing: 10) {
            Text(notice.message).multilineTextAlignment(.center)
            if notice.canChooseFeed { Button("Choose a feed") { send(.chooseFeed) }.buttonStyle(StartupFilledButtonStyle()) }
        }.font(MonitorTheme.font(14, weight: .medium)).foregroundStyle(Palette.text)
            .padding(14).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }
    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text(value.context.canControl ? "CONTROL · YOU" : "CONTROL · \(value.holderName)")
                    .font(MonitorTheme.font(10, weight: .semibold))
                    .foregroundStyle(value.context.canControl ? Palette.accent : Palette.text.opacity(0.65))
                if value.context.canControl {
                    ForEach(value.settings) { setting in
                        Menu(setting.title) {
                            ForEach(setting.choices) { choice in
                                Button(choice.title) { send(.set(value.context, setting.id, choice.id)) }
                            }
                        }
                    }
                    Button("Release") { interaction.cancel(); send(.releaseControl) }
                    Button(value.context.recording ? "Stop REC" : "REC") {
                        if let command = interaction.requestRecording(context: value.context, confirm: confirmRecording) { send(command) }
                    }.foregroundStyle(Palette.rec)
                } else if value.canRequestControl {
                    Button(value.controlRequested ? "Requested…" : "Request control") { send(.requestControl) }
                        .disabled(value.controlRequested)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.monitorScrollFade(.horizontal).font(MonitorTheme.font(12, weight: .semibold))
            .foregroundStyle(Palette.text).background(.black.opacity(0.72), in: Capsule())
    }
    private func send(_ command: MonitorWatcherAction) { if value.admits(command) { action(command) } }
}
#endif
