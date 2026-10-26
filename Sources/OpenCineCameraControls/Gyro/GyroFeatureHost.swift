#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import OpenCineGyro
    import OpenCineGyroApple
    import SwiftUI

    @available(iOS 17, *)
    extension View {
        /// The whole gyro feature in one modifier: setup or calibration (one full-screen cover),
        /// the logs sheet with its share sheet, the drift sheet and the notice banner. The host
        /// passes its haptics preference; the coordinator stays the single owner of state.
        public func gyroFeature(
            _ coordinator: GyroCaptureCoordinator,
            haptics: OperatorHaptics = OperatorHaptics(isEnabled: { true })
        ) -> some View {
            modifier(GyroFeatureModifier(coordinator: coordinator, haptics: haptics))
        }
    }

    /// The URLs a share produced, identified so the share sheet presents once per share.
    private struct GyroShareItems: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    @available(iOS 17, *)
    private struct GyroFeatureModifier: ViewModifier {
        let coordinator: GyroCaptureCoordinator
        let haptics: OperatorHaptics

        @Environment(\.gyroAnnouncer) private var announcer
        @State private var coverShown = false

        private var coverPresented: Bool {
            !coordinator.setupSteps.isEmpty || coordinator.ring != nil
        }

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .top) {
                    GyroNoticeBanner(coordinator: coordinator)
                }
                .fullScreenCover(isPresented: $coverShown) {
                    GyroSetupFlow(coordinator: coordinator, haptics: haptics)
                }
                .sheet(
                    isPresented: Binding(
                        get: { coordinator.logsPresented },
                        set: { coordinator.logsPresented = $0 })
                ) {
                    GyroLogsFlow(coordinator: coordinator, haptics: haptics)
                }
                .sheet(
                    isPresented: Binding(
                        get: { coordinator.driftPromptPresented },
                        set: { if !$0 { coordinator.dismissDriftPrompt() } })
                ) {
                    GyroDriftSheet(
                        recalibrate: coordinator.recalibrateAfterDrift,
                        notNow: coordinator.dismissDriftPrompt
                    )
                    .environment(\.gyroHaptics, haptics)
                }
                .onChange(of: coverPresented, initial: true) { _, presented in
                    coverShown = presented
                }
                .onChange(of: coordinator.driftHapticToken) { _, _ in
                    haptics.confirm()
                    announcer.announce(GyroCopy.pillMountMoved)
                }
        }
    }

    /// The content of the one full-screen cover: the setup sheet while a setup step is open,
    /// otherwise the calibration screens. One view, so a step change never re-presents.
    @available(iOS 17, *)
    public struct GyroSetupFlow: View {
        let coordinator: GyroCaptureCoordinator
        let haptics: OperatorHaptics

        public init(coordinator: GyroCaptureCoordinator, haptics: OperatorHaptics) {
            self.coordinator = coordinator
            self.haptics = haptics
        }

        public var body: some View {
            Group {
                if let step = coordinator.setupSteps.first {
                    GyroSetupSheet(
                        step: step, ring: coordinator.ring,
                        completedSteps: coordinator.ringCompletedSteps,
                        lastEvent: coordinator.lastRingEvent,
                        eventToken: coordinator.ringEventToken, actions: actions(step))
                } else if let ring = coordinator.ring {
                    GyroRingCalibrationView(
                        phase: ring, completedSteps: coordinator.ringCompletedSteps,
                        lastEvent: coordinator.lastRingEvent,
                        eventToken: coordinator.ringEventToken,
                        canUseLast: false, actions: actions(nil))
                } else {
                    Color(MonitorTheme.background.opacity(1)).ignoresSafeArea()
                }
            }
            .environment(\.gyroHaptics, haptics)
        }

        /// Maps the screens' buttons onto the coordinator. Cancel on the stabilization step
        /// leaves the camera unchanged, which is "Keep it on".
        private func actions(_ step: GyroArmingStep?) -> GyroSetupActions {
            let c = coordinator
            return GyroSetupActions(
                turnOff: { c.setupTurnOffStabilization() },
                keepOn: { c.setupKeepStabilization() },
                getStarted: {
                    if c.ring == nil { c.beginCalibration() }
                    c.startRing()
                },
                useLast: { c.setupUseLastCalibration() },
                cancel: {
                    if case .stabilization = step { c.setupKeepStabilization() } else {
                        c.cancelCalibration()
                    }
                },
                done: { c.finishCalibration() })
        }
    }

    /// The logs sheet's content with its share sheet.
    @available(iOS 17, *)
    public struct GyroLogsFlow: View {
        let coordinator: GyroCaptureCoordinator
        let haptics: OperatorHaptics
        @State private var shareItems: GyroShareItems?

        public init(coordinator: GyroCaptureCoordinator, haptics: OperatorHaptics) {
            self.coordinator = coordinator
            self.haptics = haptics
        }

        public var body: some View {
            GyroLogsView(
                entries: coordinator.logs, tipVisible: coordinator.tipVisible,
                gyroEnabled: coordinator.enabled, now: Date(),
                actions: GyroLogsActions(
                    share: { ids in
                        Task {
                            let urls = await coordinator.share(ids)
                            if !urls.isEmpty { shareItems = GyroShareItems(urls: urls) }
                        }
                    },
                    delete: { id in Task { await coordinator.delete(id) } },
                    dismissTip: coordinator.dismissTip,
                    turnOnGyro: { coordinator.enabled = true },
                    close: { coordinator.logsPresented = false })
            )
            .environment(\.gyroHaptics, haptics)
            .sheet(item: $shareItems) { items in MonitorActivityShareSheet(items: items.urls) }
        }
    }

    /// A short banner at the top of the monitor for the coordinator's notice, announced when it
    /// appears and cleared after 4 seconds.
    @available(iOS 17, *)
    struct GyroNoticeBanner: View {
        let coordinator: GyroCaptureCoordinator
        @Environment(\.gyroAnnouncer) private var announcer

        var body: some View {
            Group {
                if let notice = coordinator.notice {
                    GyroNoticeBannerLabel(text: GyroCopy.notice(notice))
                        .padding(.top, 8).padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task(id: coordinator.notice) {
                guard let notice = coordinator.notice else { return }
                announcer.announce(GyroCopy.notice(notice))
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled, coordinator.notice == notice { coordinator.clearNotice() }
            }
        }
    }

    /// The banner's look, in the monitor chip style: dark capsule, amber warning mark.
    struct GyroNoticeBannerLabel: View {
        let text: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(GyroPalette.orange)
                Text(text).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("gyro.notice")
        }
    }
#endif
