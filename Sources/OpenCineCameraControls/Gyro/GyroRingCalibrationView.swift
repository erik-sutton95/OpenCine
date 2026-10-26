#if os(iOS)
    import MonitorUI
    import OpenCineGyro
    import SwiftUI

    /// The fill-the-ring calibration screens: intro, posing, retry, invalidated and complete.
    /// Values and actions only; the host owns the calibration and feeds `phase`.
    public struct GyroRingCalibrationView: View {
        private let phase: GyroRingPhase
        private let completedSteps: Int
        private let lastEvent: GyroRingEvent?
        private let canUseLast: Bool
        private let eventToken: Int
        private let actions: GyroSetupActions

        @Environment(\.gyroAnnouncer) private var announcer
        @Environment(\.gyroHaptics) private var haptics
        @State private var flash = false
        @State private var retryVisible = false
        @State private var holdBucket = 0
        @State private var flashTask: Task<Void, Never>?
        @State private var retryTask: Task<Void, Never>?
        @State private var handledEvent: String?

        public init(
            phase: GyroRingPhase, completedSteps: Int, lastEvent: GyroRingEvent?,
            eventToken: Int = 0, canUseLast: Bool, actions: GyroSetupActions
        ) {
            self.eventToken = eventToken
            self.phase = phase
            self.completedSteps = completedSteps
            self.lastEvent = lastEvent
            self.canUseLast = canUseLast
            self.actions = actions
        }

        /// The pose being asked for, when the phase is a posing screen.
        private var posingStep: GyroRingStep? {
            switch phase {
            case .posing(let step, _, _), .blocked(let step, _): return step
            case .retrying: return .level
            case .intro, .invalidated, .complete: return nil
            }
        }

        private var blockReason: GyroCalibrationBlock? {
            if case .blocked(_, let reason) = phase { return reason }
            return nil
        }

        private var invalidation: GyroCalibrationInvalidation? {
            if case .invalidated(let reason) = phase { return reason }
            return nil
        }

        private var isComplete: Bool {
            if case .complete = phase { return true }
            return false
        }

        private var holdFraction: Double? {
            if case .posing(_, true, let hold) = phase { return hold }
            return nil
        }

        private var ringModel: GyroRingModel {
            let base = GyroRingModel.make(phase)
            guard flash, !base.checkmark else { return base }
            return GyroRingModel(
                litFraction: base.litFraction, dimmed: false, checkmark: true,
                tiltDegrees: base.tiltDegrees)
        }

        private var ringLabel: String {
            if let step = posingStep { return GyroCopy.step(step) }
            switch phase {
            case .complete: return GyroCopy.completeTitle
            case .invalidated(let reason): return GyroCopy.invalidation(reason)
            default: return GyroCopy.calibrateTitle
            }
        }

        public var body: some View {
            NavigationStack {
                ZStack {
                    MonitorTheme.background.ignoresSafeArea()
                    GyroAdaptiveStack(
                        visual: { visual }, header: { header }, footer: { footer })
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isComplete {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(GyroCopy.cancel, action: actions.cancel)
                                .tint(MonitorTheme.accent)
                                .accessibilityIdentifier("gyro.cancel")
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: lastEvent) { _, _ in handleLatest() }
            .onChange(of: eventToken) { _, _ in handleLatest() }
            .onChange(of: blockReason, initial: true) { _, reason in
                if let reason { announcer.announce(GyroCopy.block(reason)) }
            }
            .onChange(of: invalidation, initial: true) { _, reason in
                if let reason { announcer.announce(GyroCopy.invalidation(reason)) }
            }
            .onChange(of: holdFraction) { _, hold in trackHold(hold) }
            .onDisappear {
                flashTask?.cancel()
                retryTask?.cancel()
            }
        }

        private var visual: some View {
            GyroRing(model: ringModel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ringLabel)
                .accessibilityValue(
                    holdFraction.map { GyroCopy.holdProgressA11y(Int(($0 * 100).rounded())) } ?? ""
                )
                .accessibilityIdentifier("gyro.visual")
        }

        private var header: some View {
            GyroLandscapeReader { landscape in headerContent(landscape: landscape) }
        }

        @ViewBuilder private func headerContent(landscape: Bool) -> some View {
            let textAlignment: TextAlignment = landscape ? .leading : .center
            VStack(alignment: landscape ? .leading : .center, spacing: 8) {
                if let step = posingStep {
                    GyroOverline(text: GyroCopy.stepCounter(step.rawValue + 1))
                    title(GyroCopy.step(step), textAlignment)
                    dots
                } else if case .invalidated(let reason) = phase {
                    GyroOverline(text: GyroCopy.phoneMount)
                    title(GyroCopy.invalidation(reason), textAlignment)
                } else if isComplete {
                    GyroOverline(text: GyroCopy.phoneMount)
                    title(GyroCopy.completeTitle, textAlignment)
                    bodyText(GyroCopy.completeBody, textAlignment)
                } else {
                    GyroOverline(text: GyroCopy.phoneMount)
                    title(GyroCopy.calibrateTitle, textAlignment)
                    bodyText(GyroCopy.calibrateBody, textAlignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: landscape ? .leading : .center)
        }

        private func title(_ text: String, _ textAlignment: TextAlignment) -> some View {
            Text(text)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }

        private func bodyText(_ text: String, _ textAlignment: TextAlignment) -> some View {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(GyroPalette.body)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
        }

        private var dots: some View {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index < completedSteps ? MonitorTheme.accent : GyroPalette.dotOff)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
        }

        private var footer: some View {
            GyroLandscapeReader { landscape in footerContent(landscape: landscape) }
        }

        @ViewBuilder private func footerContent(landscape: Bool) -> some View {
            VStack(spacing: 6) {
                switch phase {
                case .intro:
                    GyroPrimaryButton(GyroCopy.getStarted, action: actions.getStarted)
                    if canUseLast {
                        GyroTextButton(
                            title: GyroCopy.useLastCalibration, identifier: "gyro.useLast",
                            action: actions.useLast)
                    }
                case .complete:
                    GyroPrimaryButton(GyroCopy.done, action: actions.done)
                case .invalidated:
                    GyroPrimaryButton(GyroCopy.done, action: actions.done)
                case .blocked(_, let reason):
                    hint(GyroCopy.block(reason), landscape)
                case .retrying:
                    hint(GyroCopy.retry, landscape)
                case .posing:
                    hint(retryVisible ? GyroCopy.retry : GyroCopy.holdHint, landscape)
                }
            }
        }

        private func hint(_ text: String, _ landscape: Bool) -> some View {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(GyroPalette.hint)
                .multilineTextAlignment(landscape ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: landscape ? .leading : .center)
                .accessibilityIdentifier("gyro.hint")
        }

        /// Handles the newest event once, whether it arrived as a new value or as a bumped token
        /// (the same event twice in a row only differs by its token).
        private func handleLatest() {
            let key = "\(eventToken)|\(String(describing: lastEvent))"
            guard handledEvent != key else { return }
            handledEvent = key
            handle(lastEvent)
        }

        private func handle(_ event: GyroRingEvent?) {
            switch event {
            case .stepCaptured(let step):
                haptics.confirm()
                announcer.announce(GyroCopy.stepDoneA11y(step.rawValue + 1))
                holdBucket = 0
                flash = true
                flashTask?.cancel()
                flashTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { flash = false }
                }
            case .verificationFailed:
                holdBucket = 0
                announcer.announce(GyroCopy.retry)
                retryVisible = true
                retryTask?.cancel()
                retryTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { retryVisible = false }
                }
            case .completed:
                haptics.confirm()
                announcer.announce(GyroCopy.completeTitle)
            case nil:
                break
            }
        }

        private func trackHold(_ hold: Double?) {
            guard let hold else {
                holdBucket = 0
                return
            }
            if let percent = GyroHoldMilestones.crossing(previousBucket: holdBucket, hold: hold) {
                announcer.announce(GyroCopy.holdProgressA11y(percent))
            }
            holdBucket = GyroHoldMilestones.bucket(hold)
        }
    }
#endif
