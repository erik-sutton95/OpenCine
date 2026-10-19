#if os(iOS)
    import MonitorUI
    import OpenCineCameraVocabulary
    import SwiftUI

    /// What the recovery card needs from an app. `LiveChromeHost` refines it; an app whose live
    /// chrome is its own conforms to this alone.
    @MainActor
    public protocol SessionRecoveryHost: AnyObject, Observable {
        associatedtype Palette: LiveChromePalette

        /// The interrupted session's recovery, for the recovery card.
        var sessionRecovery: SessionRecoveryState { get }
        /// The first retry's card waits out a short grace so a quick reconnect stays quiet.
        var sessionRecoveryCardGraceElapsed: Bool { get }
        /// The dropped camera's name, captured at the drop.
        var recoveryDeviceName: String { get }
        /// What the card says while a retry runs, from the camera's connection phase.
        var recoveryProgressDetail: String { get }
        /// The likely cause the paused card names, when the app can tell; nil names none.
        var recoveryDropSuspect: SessionDropSuspect? { get }
        func retrySessionRecovery()
        func exitMonitorToOperatorMenu()
    }

    extension SessionRecoveryHost {
        public var recoveryDropSuspect: SessionDropSuspect? { nil }
    }

    /// Recovery card over a held live-view frame after an established session dropped. A camera
    /// power cycle must not throw the operator back to the connect screen.
    public struct SessionRecoveryOverlay<Host: SessionRecoveryHost>: View {
        @Environment(Host.self) private var host

        public init() {}

        private func showsCard(_ state: SessionRecoveryState) -> Bool {
            guard state.isRecovering else { return false }
            if case .retrying(let attempt, _) = state, attempt <= 1 {
                return host.sessionRecoveryCardGraceElapsed
            }
            return true
        }

        public var body: some View {
            recoveryBody(host.sessionRecovery)
        }

        @ViewBuilder private func recoveryBody(_ state: SessionRecoveryState) -> some View {
            if showsCard(state) {
                ZStack {
                    Color.black.opacity(0.34)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    card(state: state)
                        .frame(maxWidth: 460)
                        .padding(.horizontal, 24)
                }
                .transition(.opacity)
            }
        }

        private func card(state: SessionRecoveryState) -> some View {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    statusIcon(state: state)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SessionRecoveryCopy.title(state))
                            .font(MonitorTheme.font(16, weight: .semibold))
                            .foregroundStyle(Host.Palette.text)
                        Text(
                            SessionRecoveryCopy.detail(
                                state, deviceName: host.recoveryDeviceName,
                                dropSuspect: host.recoveryDropSuspect)
                        )
                        .font(MonitorTheme.font(12, weight: .medium))
                        .foregroundStyle(Host.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        if case .retrying = state {
                            Text(host.recoveryProgressDetail)
                                .font(MonitorTheme.font(12, weight: .medium))
                                .foregroundStyle(Host.Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    actionButton(
                        title: "Retry connection",
                        icon: .refreshCw,
                        tint: Host.Palette.accent
                    ) {
                        host.retrySessionRecovery()
                    }
                    actionButton(
                        title: "Operator menu",
                        icon: .chevronLeft,
                        tint: nil
                    ) {
                        host.exitMonitorToOperatorMenu()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
            )
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        }

        @ViewBuilder private func statusIcon(state: SessionRecoveryState) -> some View {
            switch state {
            case .retrying:
                ProgressView()
                    .controlSize(.small)
                    .tint(Host.Palette.accent)
            case .waitingForOperator, .pausedAfterRepeatedDrops, .takenOver, .idle:
                MonitorIcon.unplug
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Host.Palette.accent)
            }
        }

        private func actionButton(
            title: String,
            icon: MonitorIcon,
            tint: Color?,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Label {
                    Text(title)
                } icon: {
                    icon.frame(width: 13, height: 13)
                }
                .font(MonitorTheme.font(13, weight: .semibold))
                .foregroundStyle(tint == nil ? Host.Palette.text : Color.black)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .liquidGlass(in: Capsule(), tint: tint, interactive: true)
                .minTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }
#endif
