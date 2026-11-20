#if os(iOS)
import MonitorPresentation
import SwiftUI

public struct LiveStreamMonitorActions {
    public var start: () -> Void
    public var stop: () -> Void
    public var restart: () -> Void
    public var dismissNotice: () -> Void

    public init(start: @escaping () -> Void, stop: @escaping () -> Void, restart: @escaping () -> Void,
        dismissNotice: @escaping () -> Void) {
        self.start = start
        self.stop = stop
        self.restart = restart
        self.dismissNotice = dismissNotice
    }
}

/// The Go live control with its two confirmations, the status readout, the notice and the warning,
/// stacked top center over the monitor picture. Kotlin twin: `LiveStreamMonitorControls` (part 3).
public struct LiveStreamMonitorControls: View {
    let state: LiveStreamMonitorState
    let actions: LiveStreamMonitorActions
    @State private var confirming: LiveStreamControlState.Tap?

    public init(state: LiveStreamMonitorState, actions: LiveStreamMonitorActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 6) {
            LiveStreamGoLiveButton(control: state.control) { confirming = state.control.tap }
            if let status = state.status { LiveStreamStatusReadout(status: status) }
            if let warning = state.warning {
                capsuleText(warning.text, color: MonitorTheme.linkHealthColor(.watch))
                    .accessibilityIdentifier("monitor.livestream.warning")
            }
            if let end = state.end, let notice = end.notice { noticeView(notice, restart: end.offersRestart) }
        }
        .frame(maxWidth: 340)
        .alert(LiveStreamCopy.startTitle(service: state.serviceName),
            isPresented: binding(.confirmStart)) {
            Button(LiveStreamCopy.startConfirm) { actions.start() }
            Button(LiveStreamCopy.cancel, role: .cancel) {}
        } message: {
            Text(LiveStreamCopy.startMessage(quality: state.quality, encrypted: state.encrypted))
        }
        .alert(LiveStreamCopy.stopTitle, isPresented: binding(.confirmStop)) {
            Button(LiveStreamCopy.stopConfirm, role: .destructive) { actions.stop() }
            Button(LiveStreamCopy.stopCancel, role: .cancel) {}
        } message: {
            Text(LiveStreamCopy.stopMessage)
        }
    }

    private func binding(_ tap: LiveStreamControlState.Tap) -> Binding<Bool> {
        Binding(get: { confirming == tap }, set: { if !$0 { confirming = nil } })
    }

    private func noticeView(_ text: String, restart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("monitor.livestream.notice")
            HStack(spacing: 8) {
                if restart {
                    MonitorSettingsActionPill(title: LiveStreamCopy.restart) { actions.restart() }
                        .accessibilityIdentifier("monitor.livestream.restart")
                }
                MonitorSettingsActionPill(title: LiveStreamCopy.dismiss, tint: MonitorTheme.muted, background: .clear) {
                    actions.dismissNotice()
                }
                .accessibilityIdentifier("monitor.livestream.notice.dismiss")
            }
        }
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: MonitorTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius).stroke(MonitorTheme.border))
    }

    private func capsuleText(_ text: String, color: Color) -> some View {
        Text(text).font(MonitorTheme.font(11, weight: .semibold)).foregroundStyle(color)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The Go live control. Disabled, with its short reason under it, when the route cannot stream.
public struct LiveStreamGoLiveButton: View {
    let control: LiveStreamControlState
    let onTap: () -> Void

    public init(control: LiveStreamControlState, onTap: @escaping () -> Void) {
        self.control = control
        self.onTap = onTap
    }

    private var tint: Color {
        switch control.tone {
        case .ready: MonitorTheme.text
        case .unavailable: MonitorTheme.muted
        case .live: .white
        case .warning: MonitorTheme.linkHealthColor(.watch)
        }
    }

    public var body: some View {
        VStack(spacing: 3) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    MonitorIcon.radio.frame(width: 14, height: 14)
                    Text(control.title.uppercased()).font(MonitorTheme.font(12, weight: .bold))
                        .monospacedDigit().kerning(0.6).lineLimit(1)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
                .background {
                    Capsule().fill(control.tone == .live ? AnyShapeStyle(MonitorTheme.recording)
                        : AnyShapeStyle(.black.opacity(0.62)))
                }
                .overlay(Capsule().stroke(tint.opacity(control.tone == .live ? 0 : 0.5), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!control.isEnabled)
            .accessibilityLabel(control.accessibilityLabel)
            .accessibilityHint(control.accessibilityHint)
            .accessibilityIdentifier("monitor.livestream.goLive")
            if let caption = control.caption {
                Text(caption).font(MonitorTheme.font(10.5, weight: .semibold)).foregroundStyle(MonitorTheme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Elapsed time, sent bitrate, dropped groups and connection health, read as one element.
public struct LiveStreamStatusReadout: View {
    let status: LiveStreamStatusState

    public init(status: LiveStreamStatusState) { self.status = status }

    private var healthColor: Color {
        switch status.health {
        case .good: MonitorTheme.linkHealthColor(.stable)
        case .congested: MonitorTheme.linkHealthColor(.watch)
        case .offline: MonitorTheme.linkHealthColor(.poor)
        }
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(status.elapsedText)
            Text(status.bitrateText)
            Text(status.droppedText)
            HStack(spacing: 4) {
                Circle().fill(healthColor).frame(width: 7, height: 7)
                Text(status.healthText)
            }
        }
        .font(MonitorTheme.font(11, weight: .semibold)).monospacedDigit()
        .foregroundStyle(MonitorTheme.text).lineLimit(1).minimumScaleFactor(0.7)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.62), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel)
        .accessibilityIdentifier("monitor.livestream.status")
    }
}
#endif
