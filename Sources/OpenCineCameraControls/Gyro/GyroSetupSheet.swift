#if os(iOS)
    import MonitorUI
    import OpenCineGyro
    import SwiftUI

    /// The arming sheet: the stabilization step, then the calibration step. Values and actions
    /// only; the host decides which step to show and feeds the ring phase.
    public struct GyroSetupSheet: View {
        private let step: GyroArmingStep
        private let ring: GyroRingPhase?
        private let completedSteps: Int
        private let lastEvent: GyroRingEvent?
        private let eventToken: Int
        private let actions: GyroSetupActions

        public init(
            step: GyroArmingStep, ring: GyroRingPhase?, completedSteps: Int,
            lastEvent: GyroRingEvent? = nil, eventToken: Int = 0, actions: GyroSetupActions
        ) {
            self.lastEvent = lastEvent
            self.eventToken = eventToken
            self.step = step
            self.ring = ring
            self.completedSteps = completedSteps
            self.actions = actions
        }

        public var body: some View {
            switch step {
            case .stabilization(let lensHasVRSwitch):
                stabilization(lensHasVRSwitch: lensHasVRSwitch)
            case .calibration(let hasSavedCalibration):
                GyroRingCalibrationView(
                    phase: ring ?? .intro, completedSteps: completedSteps, lastEvent: lastEvent,
                    eventToken: eventToken, canUseLast: hasSavedCalibration, actions: actions)
            }
        }

        private func stabilization(lensHasVRSwitch: Bool?) -> some View {
            NavigationStack {
                ZStack {
                    MonitorTheme.background.ignoresSafeArea()
                    GyroAdaptiveStack(
                        visual: { StabilizationVisual() },
                        header: { header(lensHasVRSwitch: lensHasVRSwitch) },
                        footer: {
                            VStack(spacing: 6) {
                                GyroPrimaryButton(
                                    GyroCopy.ibisTurnOff, identifier: "gyro.setup.turnOff",
                                    action: actions.turnOff)
                                GyroTextButton(
                                    title: GyroCopy.ibisKeep, tint: .white,
                                    identifier: "gyro.setup.keepOn", action: actions.keepOn)
                            }
                        })
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(GyroCopy.cancel, action: actions.cancel)
                            .tint(MonitorTheme.accent)
                            .accessibilityIdentifier("gyro.cancel")
                    }
                }
            }
            .preferredColorScheme(.dark)
        }

        private func header(lensHasVRSwitch: Bool?) -> some View {
            GyroLandscapeReader { landscape in
                headerContent(lensHasVRSwitch: lensHasVRSwitch, landscape: landscape)
            }
        }

        private func headerContent(lensHasVRSwitch: Bool?, landscape: Bool) -> some View {
            VStack(alignment: landscape ? .leading : .center, spacing: 8) {
                Text(GyroCopy.ibisTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(GyroCopy.ibisReason)
                    .font(.system(size: 15))
                    .foregroundStyle(GyroPalette.body)
                if lensHasVRSwitch == true {
                    Text(GyroCopy.ibisLens)
                        .font(.system(size: 15))
                        .foregroundStyle(GyroPalette.body)
                        .accessibilityIdentifier("gyro.setup.lens")
                }
            }
            .multilineTextAlignment(landscape ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: landscape ? .leading : .center)
        }
    }

    /// A camera glyph with a gyroscope badge, the picture for the stabilization step.
    private struct StabilizationVisual: View {
        var body: some View {
            GeometryReader { proxy in
                let d = min(min(proxy.size.width, proxy.size.height) * 0.7, 260)
                ZStack {
                    Circle().stroke(
                        GyroPalette.track,
                        style: StrokeStyle(lineWidth: d * 0.1, dash: [d * 0.025, d * 0.05])
                    )
                    .frame(width: d * 0.9, height: d * 0.9)
                    GyroCameraGlyph(width: d * 0.44)
                    Image(systemName: "waveform")
                        .font(.system(size: d * 0.1, weight: .semibold))
                        .foregroundStyle(MonitorTheme.accent)
                        .frame(width: d * 0.17, height: d * 0.17)
                        .background(MonitorTheme.background, in: Circle())
                        .overlay(Circle().stroke(GyroPalette.glyphBody, lineWidth: 1))
                        .offset(x: d * 0.2, y: d * 0.15)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GyroCopy.ibisTitle)
            .accessibilityIdentifier("gyro.visual")
        }
    }
#endif
