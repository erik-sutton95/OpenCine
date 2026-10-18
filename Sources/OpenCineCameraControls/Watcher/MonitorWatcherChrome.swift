#if os(iOS)
import MonitorPresentation
import MonitorUI
import SwiftUI

extension View {
    /// The host's explicit grant decision, using the same native confirmation as the watcher hosts.
    /// Dismissal declines through the supplied request; the host retains request admission.
    public func monitorRelayControlRequest(_ request: MonitorSettingsWatchersSource.Request?) -> some View {
        confirmationDialog(
            "Allow \(request?.name ?? "a watcher") to control the camera?",
            isPresented: Binding(
                get: { request != nil },
                set: { if !$0 { request?.decline() } }),
            titleVisibility: .visible
        ) {
            Button("Grant") { request?.grant() }
            Button("Deny", role: .cancel) { request?.decline() }
        }
    }
}

/// A relay token action, inline in watcher chrome or over the monitor picture.
/// The host retains source and control admission and supplies the action.
public struct MonitorWatcherControlKey<Palette: LiveChromePalette>: View {
    private let title: LocalizedStringKey
    private let accented: Bool
    private let holderName: String?
    private let prominent: Bool
    private let action: () -> Void

    public init(title: LocalizedStringKey, accented: Bool = false, holderName: String? = nil,
        prominent: Bool = true, palette: Palette.Type, action: @escaping () -> Void) {
        self.title = title; self.accented = accented; self.holderName = holderName
        self.prominent = prominent; self.action = action
    }

    public var body: some View {
        if prominent {
            key.buttonStyle(.monitorTapTarget)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            key
        }
    }

    private var key: some View {
        Button(action: action) {
            if prominent {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .kerning(0.8)
                        .foregroundStyle(accented ? Palette.accent : Palette.text)
                    if let holderName {
                        Text(holderName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.text.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(
                    accented ? Palette.accent : Palette.hairline, lineWidth: 1))
            } else {
                Text(title)
            }
        }
    }
}

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
                    MonitorWatcherControlKey(title: "Release", prominent: false, palette: palette) {
                        interaction.cancel(); send(.releaseControl)
                    }
                    Button(value.context.recording ? "Stop REC" : "REC") {
                        if let command = interaction.requestRecording(context: value.context, confirm: confirmRecording) { send(command) }
                    }.foregroundStyle(Palette.rec)
                } else if value.canRequestControl {
                    MonitorWatcherControlKey(title: value.controlRequested ? "Requested…" : "Request control",
                        prominent: false, palette: palette) { send(.requestControl) }
                        .disabled(value.controlRequested)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.monitorScrollFade(.horizontal).font(MonitorTheme.font(12, weight: .semibold))
            .foregroundStyle(Palette.text).background(.black.opacity(0.72), in: Capsule())
    }
    private func send(_ command: MonitorWatcherAction) { if value.admits(command) { action(command) } }
}
#endif
