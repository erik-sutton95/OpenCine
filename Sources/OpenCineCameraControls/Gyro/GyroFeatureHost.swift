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
        /// passes the operator's haptics preference; the coordinator stays the single owner of
        /// state. The modifier sequences its own presentations (arming or calibration closes the
        /// gyro logs sheet first), but it cannot see the host's: a host must dismiss its own
        /// sheets before arming or calibration can present the cover.
        public func gyroFeature(
            _ coordinator: GyroCaptureCoordinator, haptics: OperatorHaptics
        ) -> some View {
            modifier(GyroFeatureModifier(coordinator: coordinator, haptics: haptics))
        }
    }

    /// Which of the feature's presentations may show, from what the coordinator wants and whether
    /// the logs sheet is still on screen. SwiftUI refuses a cover over a sheet presented from the
    /// same content, so the cover waits until the logs sheet has fully dismissed.
    struct GyroPresentationPlan: Equatable {
        /// Setup or calibration has something to show.
        var coverWanted: Bool
        /// The coordinator asks for the logs sheet.
        var logsPresented: Bool
        /// The logs sheet is on screen, including while it animates away.
        var logsUp: Bool
        /// The coordinator has a drift prompt queued.
        var driftPrompt: Bool

        /// Arming or calibration while the logs are up: the logs close first.
        var closeLogs: Bool { coverWanted && logsPresented }
        /// The cover presents only once the logs sheet is gone.
        var cover: Bool { coverWanted && !logsPresented && !logsUp }
        /// The drift sheet shows only when nothing else is presented or waiting.
        var drift: Bool { driftPrompt && !logsPresented && !logsUp && !coverWanted }
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
        @State private var driftShown = false
        /// Recalibrate was tapped: the ring opens only after the drift sheet has dismissed, so
        /// the cover is never asked to present over a sheet that is still going away.
        @State private var recalibrateAfterDismiss = false
        /// The logs sheet is on screen, including while it animates away; the cover waits for it.
        @State private var logsUp = false

        private var plan: GyroPresentationPlan {
            GyroPresentationPlan(
                coverWanted: !coordinator.setupSteps.isEmpty || coordinator.ring != nil,
                logsPresented: coordinator.logsPresented, logsUp: logsUp,
                driftPrompt: coordinator.driftPromptPresented)
        }

        private var coverPresented: Bool { plan.cover }

        /// The drift prompt stays queued in the coordinator until the logs sheet and the cover
        /// are gone.
        private var driftWanted: Bool { plan.drift }

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .top) { GyroNoticeBanner(notice: coordinator.notice) }
                .task(id: coordinator.noticeToken) {
                    let token = coordinator.noticeToken
                    guard let notice = coordinator.notice else { return }
                    announcer.announce(GyroCopy.notice(notice))
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled, coordinator.noticeToken == token { coordinator.clearNotice() }
                }
                .fullScreenCover(isPresented: $coverShown) {
                    GyroSetupFlow(coordinator: coordinator, haptics: haptics)
                }
                .sheet(
                    isPresented: Binding(
                        get: { coordinator.logsPresented },
                        set: { coordinator.logsPresented = $0 }),
                    onDismiss: { logsUp = false }
                ) {
                    // logsUp tracks the sheet actually on screen: set when it appears, cleared
                    // by onDismiss, so a request withdrawn before presenting never strands it.
                    GyroLogsFlow(coordinator: coordinator, haptics: haptics)
                        .onAppear { logsUp = true }
                }
                .sheet(isPresented: $driftShown, onDismiss: driftDidDismiss) {
                    GyroDriftSheet(
                        recalibrate: {
                            recalibrateAfterDismiss = true
                            driftShown = false
                        },
                        notNow: coordinator.dismissDriftPrompt
                    )
                    .environment(\.gyroHaptics, haptics)
                }
                .onChange(of: plan.closeLogs, initial: true) { _, close in
                    // The cover follows from the logs sheet's onDismiss.
                    if close { coordinator.logsPresented = false }
                }
                .onChange(of: coverPresented, initial: true) { _, presented in
                    coverShown = presented
                }
                .onChange(of: driftWanted, initial: true) { _, wanted in
                    driftShown = wanted
                }
                .onChange(of: coordinator.driftHapticToken) { _, _ in
                    haptics.light()
                    announcer.announce(GyroCopy.pillMountMoved)
                }
        }

        private func driftDidDismiss() {
            if recalibrateAfterDismiss {
                recalibrateAfterDismiss = false
                coordinator.recalibrateAfterDrift()
            } else if driftWanted {
                // The operator swiped the sheet away: that silences the prompt. A sheet that went
                // away because it was queued or the prompt ended is not a decision.
                coordinator.dismissDriftPrompt()
            }
        }
    }

    /// The content of the one full-screen cover: the setup sheet while a setup step is open,
    /// otherwise the calibration screens. One view, so a step change never re-presents. It draws
    /// the notice banner too, since the cover hides the monitor's own.
    @available(iOS 17, *)
    struct GyroSetupFlow: View {
        let coordinator: GyroCaptureCoordinator
        let haptics: OperatorHaptics

        @Environment(\.gyroAnnouncer) private var announcer

        /// Which screen the cover shows; a change replaces the content without a presentation,
        /// so VoiceOver is told the screen changed.
        private var screen: String {
            if case .stabilization? = coordinator.setupSteps.first { return "stabilization" }
            switch coordinator.ring {
            case nil: return coordinator.setupSteps.isEmpty ? "none" : "intro"
            case .intro?: return "intro"
            case .complete?: return "complete"
            case .invalidated?: return "invalidated"
            case .posing?, .blocked?, .retrying?: return "ring"
            }
        }

        var body: some View {
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
                    MonitorTheme.background.ignoresSafeArea()
                }
            }
            .overlay(alignment: .top) {
                // Below the navigation bar, so Cancel stays reachable.
                GyroNoticeBanner(notice: coordinator.notice, topInset: 44)
            }
            .environment(\.gyroHaptics, haptics)
            .onChange(of: screen) { _, _ in announcer.screenChanged() }
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

    /// The logs sheet's content with its share sheet. It draws the notice banner too, since the
    /// sheet covers the monitor's own.
    @available(iOS 17, *)
    struct GyroLogsFlow: View {
        let coordinator: GyroCaptureCoordinator
        let haptics: OperatorHaptics
        @State private var shareItems: GyroShareItems?

        var body: some View {
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
            .overlay(alignment: .top) {
                // Below the navigation bar, so Close stays reachable.
                GyroNoticeBanner(notice: coordinator.notice, topInset: 44)
            }
            .environment(\.gyroHaptics, haptics)
            .sheet(item: $shareItems) { items in MonitorActivityShareSheet(items: items.urls) }
        }
    }

    /// A short banner at the top of the screen for the coordinator's notice, in the monitor chip
    /// style. The modifier owns the announcement and the 4 second timer.
    struct GyroNoticeBanner: View {
        let notice: GyroNotice?
        var topInset: CGFloat = 0

        var body: some View {
            if let notice {
                GyroNoticeBannerLabel(text: GyroCopy.notice(notice))
                    .padding(.top, 8 + topInset).padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// The banner's look: dark rounded chip, amber warning mark.
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
