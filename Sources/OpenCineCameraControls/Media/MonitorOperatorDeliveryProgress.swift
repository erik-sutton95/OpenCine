#if os(iOS)
    import MonitorPresentation
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
                value: state.chromeFacts(remoteDisplayName: nil).value, onCancel: onCancel
            ) { MonitorOperatorDeliveryIcon(destination: state.destination) }
        }
    }

    /// What the delivery chrome shows for one progress value.
    public struct MonitorOperatorDeliveryFacts: Sendable {
        public let value: MonitorMediaDeliveryProgressValue
        public let destination: MonitorDeliveryDestination
        public let details: MonitorMediaDeliveryProgressDetailsValue
        public init(
            value: MonitorMediaDeliveryProgressValue, destination: MonitorDeliveryDestination,
            details: MonitorMediaDeliveryProgressDetailsValue = .init()
        ) {
            self.value = value
            self.destination = destination
            self.details = details
        }
    }

    extension MonitorDeliveryBatchProgress {
        public func chromeFacts(remoteDisplayName: String?) -> MonitorOperatorDeliveryFacts {
            .init(
                value: .init(
                    status: statusLine(),
                    batch: totalClips > 1 ? "Clip \(min(clipIndex, totalClips)) of \(totalClips)" : nil,
                    fraction: overallFraction, preparing: showsBusySpinner,
                    showsProgress: !isPreparingClip),
                destination: destination,
                details: .init(
                    filename: filename,
                    destination: destination.title(remoteDisplayName: remoteDisplayName)))
        }
    }

    /// One delivery chrome for every app: compact progress with cancel, an expandable detail
    /// panel and the outcome toast, all read from the app-scoped delivery model. Mount it once
    /// at the app root (`.root`) and as an overlay of each media surface a cover can hide
    /// (`.surface`); the root yields while any surface is on screen. Mount it where the safe
    /// area applies (an overlay outside `ignoresSafeArea`) so it clears the notch and island.
    public struct MonitorOperatorDeliveryChrome<Progress: Sendable, Outcome: Sendable, Share: Sendable>: View {
        public typealias Scope = MonitorDeliveryChromeScope
        private let model: MonitorDeliveryModel<Progress, Outcome, Share>
        private let scope: Scope
        private let facts: (Progress) -> MonitorOperatorDeliveryFacts

        public init(
            model: MonitorDeliveryModel<Progress, Outcome, Share>, scope: Scope,
            facts: @escaping (Progress) -> MonitorOperatorDeliveryFacts
        ) {
            self.model = model
            self.scope = scope
            self.facts = facts
        }

        public var body: some View {
            let state = model.state
            let progress = state.progress(in: scope), toast = state.toast(in: scope)
            ZStack {
                if let progress { anchored(facts(progress), expanded: state.expanded) }
                if let toast {
                    VStack {
                        Spacer()
                        Text(toast).font(MonitorTheme.font(13, weight: .medium))
                            .foregroundStyle(MonitorTheme.text).multilineTextAlignment(.center)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .liquidGlass(in: Capsule(), interactive: false)
                            // A media surface keeps its bottom toolbar clear.
                            .padding(.bottom, scope == .surface ? 96 : 28)
                            .accessibilityIdentifier("monitor.delivery.toast")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.32), value: progress == nil)
            .animation(.spring(duration: 0.28), value: state.expanded)
            .onAppear { if scope == .surface { model.enterLocalOverlayContext() } }
            .onDisappear { if scope == .surface { model.exitLocalOverlayContext() } }
        }

        private func anchored(_ facts: MonitorOperatorDeliveryFacts, expanded: Bool) -> some View {
            VStack {
                Group {
                    if expanded {
                        MonitorMediaDeliveryProgressPanel(
                            value: facts.value, details: facts.details, onCancel: { model.cancel() },
                            onCollapse: { model.setExpanded(false) }
                        ) { MonitorOperatorDeliveryIcon(destination: facts.destination) }
                    } else {
                        MonitorMediaDeliveryProgress(
                            value: facts.value, onCancel: { model.cancel() },
                            onExpand: { model.setExpanded(true) }
                        ) { MonitorOperatorDeliveryIcon(destination: facts.destination) }
                    }
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 20).padding(.top, 8)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("monitor.delivery.progress")
        }
    }

    extension MonitorOperatorDeliveryChrome where Progress == MonitorDeliveryBatchProgress {
        public init(
            model: MonitorDeliveryModel<Progress, Outcome, Share>, scope: Scope,
            remoteDisplayName: String?
        ) {
            self.init(model: model, scope: scope) { $0.chromeFacts(remoteDisplayName: remoteDisplayName) }
        }
    }

    private struct MonitorOperatorDeliveryIcon: View {
        let destination: MonitorDeliveryDestination
        var body: some View {
            if destination == .nativeShare { MonitorIcon.share } else { MonitorIcon.upload }
        }
    }
#endif
