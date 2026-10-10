#if os(iOS)
    import MonitorUI
    import OpenCineAppKit
    import SwiftUI

    public struct MonitorOperatorDeliveryProgress: View {
        private let state: MonitorDeliveryBatchProgress
        private let onCancel: () -> Void
        public init(state: MonitorDeliveryBatchProgress, onCancel: @escaping () -> Void) {
            self.state = state
            self.onCancel = onCancel
        }
        public var body: some View {
            MonitorMediaDeliveryProgress(
                value: .init(
                    status: state.statusLine(),
                    batch: state.totalClips > 1
                        ? "Clip \(min(state.clipIndex, state.totalClips)) of \(state.totalClips)"
                        : nil,
                    fraction: state.overallFraction, preparing: state.showsBusySpinner,
                    showsProgress: !state.isPreparingClip), onCancel: onCancel
            ) {
                if state.destination == .nativeShare {
                    MonitorIcon.share
                } else {
                    MonitorIcon.upload
                }
            }
        }
    }
#endif
