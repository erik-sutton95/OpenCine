#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// The mount-moved prompt: one primary Recalibrate and a plain Not now. Medium detent.
    public struct GyroDriftSheet: View {
        private let recalibrate: () -> Void
        private let notNow: () -> Void

        public init(recalibrate: @escaping () -> Void, notNow: @escaping () -> Void) {
            self.recalibrate = recalibrate
            self.notNow = notNow
        }

        public var body: some View {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(GyroPalette.orange)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(GyroCopy.driftTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Text(GyroCopy.driftQuestion)
                        .font(.system(size: 15))
                        .foregroundStyle(GyroPalette.body)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 4) {
                    GyroPrimaryButton(GyroCopy.recalibrate, action: recalibrate)
                    GyroTextButton(
                        title: GyroCopy.notNow, tint: .white, identifier: "gyro.drift.notNow",
                        action: notNow)
                }
            }
            .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(MonitorTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .presentationDetents([.medium])
        }
    }
#endif
