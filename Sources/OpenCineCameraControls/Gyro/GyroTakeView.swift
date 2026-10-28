#if os(iOS)
    import MonitorUI
    import OpenCineGyro
    import SwiftUI

    /// The verdict colors of a take: green for ready, red while recording, orange otherwise.
    public enum GyroStatusTone {
        /// The list badge: green ready, red for a recording or cut-short take, orange otherwise.
        public static func badge(_ status: GyroTakeStatus) -> Color {
            switch status {
            case .ready: return GyroPalette.green
            case .recording, .cutShort: return GyroPalette.red
            case .mountMoved, .smallGaps, .notCalibrated: return GyroPalette.orange
            }
        }

        /// The take page's verdict glyph: green ready, red recording, orange for every other.
        public static func verdict(_ status: GyroTakeStatus) -> Color {
            switch status {
            case .ready: return GyroPalette.green
            case .recording: return GyroPalette.red
            default: return GyroPalette.orange
            }
        }
    }

    /// One take: the verdict first, Share log, then the numbers under Details.
    public struct GyroTakeView: View {
        private let entry: GyroLogEntry
        private let now: Date
        private let showsShare: Bool
        private let share: () -> Void

        public init(
            entry: GyroLogEntry, now: Date = Date(), showsShare: Bool = true,
            share: @escaping () -> Void
        ) {
            self.entry = entry
            self.now = now
            self.showsShare = showsShare
            self.share = share
        }

        private var status: GyroTakeStatus { entry.status }

        private var subtitle: String {
            var parts = [entry.rowSubtitle(now: now)]
            parts.append(
                entry.descriptor.mountCalibration != nil
                    ? GyroCopy.calibratedMount : GyroCopy.notCalibrated)
            return parts.joined(separator: GyroCopy.separator)
        }

        /// The verdict and Share log stay fixed and the Details rows follow them. The rows scroll
        /// whenever they are taller than the room left (landscape, large text) and are plain
        /// content when they fit.
        public var body: some View {
            GeometryReader { proxy in
                let compact = proxy.size.height < 560
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        VerdictGlyph(status: status, size: compact ? 46 : 70)
                            .padding(.bottom, compact ? 2 : 6)
                        Text(GyroCopy.verdict(status))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("gyro.take.verdict")
                        Text(subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(GyroPalette.body)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, compact ? 4 : 12).padding(.horizontal, 24)

                    if showsShare {
                        GyroPrimaryButton(GyroCopy.shareLog, action: share)
                            .disabled(!entry.canShare)
                            .padding(.horizontal, 20).padding(.top, compact ? 10 : 24)
                    }

                    Text(GyroCopy.details.uppercased())
                        .font(.system(size: 12))
                        .tracking(0.8)
                        .foregroundStyle(GyroPalette.overline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, compact ? 10 : 28)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)

                    GyroFitScroll { rows(compact: compact) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .background(MonitorTheme.background)
        }

        private func rows(compact: Bool) -> some View {
            VStack(spacing: 0) {
                row(
                    GyroCopy.startsLabel,
                    GyroCopy.startOffset(
                        entry.summary?.approximateStartOffset
                            ?? entry.descriptor.approximateStartOffset), compact: compact)
                row(GyroCopy.smoothnessLabel, GyroCopy.smoothness(status), compact: compact)
                if let summary = entry.summary {
                    row(
                        GyroCopy.sampleRateLabel, GyroCopy.sampleRate(summary.measuredRate),
                        compact: compact)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }

        private func row(_ key: String, _ value: String, compact: Bool) -> some View {
            VStack(spacing: 0) {
                HStack {
                    Text(key).foregroundStyle(GyroPalette.overline)
                    Spacer(minLength: 12)
                    Text(value).foregroundStyle(.white)
                }
                .font(.system(size: compact ? 14 : 15))
                .padding(.vertical, compact ? 7 : 12)
                Rectangle().fill(GyroPalette.hairline).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 70 pt glyph: a green check, an orange exclamation or a red record dot in a tinted circle.
    private struct VerdictGlyph: View {
        let status: GyroTakeStatus
        var size: CGFloat = 70

        var body: some View {
            let tone = GyroStatusTone.verdict(status)
            ZStack {
                Circle().fill(tone.opacity(0.15))
                switch status {
                case .ready:
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(tone)
                case .recording:
                    Circle().fill(tone).frame(width: 26, height: 26)
                default:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 32, weight: .bold)).foregroundStyle(tone)
                }
            }
            .frame(width: 70, height: 70)
            .scaleEffect(size / 70)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
#endif
