#if os(iOS)
    import MonitorPresentation
    import OpenCineAppKit
    import SwiftUI

    extension View {
        /// The root's native task, scene ticks and first-report sheet over a shared startup lifetime.
        /// The app keeps its existing model, splash layer and startup/background actions.
        @MainActor public func monitorAppStartup<Consent: View>(
            _ startup: MonitorAppStartup, splashVisible: Binding<Bool>,
            @ViewBuilder consent: @escaping (@escaping (Bool) -> Void) -> Consent
        ) -> some View {
            modifier(
                MonitorAppStartupModifier(
                    startup: startup, splashVisible: splashVisible, consent: consent))
        }
    }

    @MainActor private struct MonitorAppStartupModifier<Consent: View>: ViewModifier {
        let startup: MonitorAppStartup
        @Binding var splashVisible: Bool
        let consent: (@escaping (Bool) -> Void) -> Consent
        @Environment(\.scenePhase) private var scenePhase

        func body(content: Content) -> some View {
            content
                .sheet(
                    item: Binding(
                        get: { startup.consentOffer },
                        set: { if $0 == nil { startup.dismissConsentOffer() } }
                    )
                ) { offer in consent(offer.choose) }
                .task(id: ObjectIdentifier(startup)) {
                    await startup.run {
                        withAnimation(.easeOut(duration: MonitorLaunchTiming.fadeOutDuration)) {
                            splashVisible = false
                        }
                    }
                }
                .onChange(of: scenePhase) { _, _ in startup.sceneChanged() }
                .onDisappear { startup.retire() }
        }
    }
#endif
