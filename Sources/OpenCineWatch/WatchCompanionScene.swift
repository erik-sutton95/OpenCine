#if os(watchOS)
import OpenCineRelay
import SwiftUI

/// A watch app's one scene over any relay codec: it owns the receiver for the scene's life,
/// activates it on first appearance and re-arms it whenever the scene becomes active again. A
/// dimmed display suspends the app without re-running `onAppear`, so returning to active is the
/// only signal that the link needs re-arming. The receiver is in the environment for `content`.
public struct WatchReceiverScene<Codec: RelayWatchCodec, Content: View>: Scene {
    @Environment(\.scenePhase) private var scenePhase
    @State private var receiver: WatchReceiver<Codec>
    private let content: (WatchReceiver<Codec>) -> Content

    public init(
        receiver: @autoclosure @escaping () -> WatchReceiver<Codec>,
        @ViewBuilder content: @escaping (WatchReceiver<Codec>) -> Content
    ) {
        _receiver = State(wrappedValue: receiver())
        self.content = content
    }

    public var body: some Scene {
        WindowGroup {
            content(receiver)
                .environment(receiver)
                .onAppear { receiver.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { receiver.resume() }
                }
        }
    }
}

/// The watch companion's scene for the common relay codec: the iPhone monitor on the wrist (a
/// 16:9 preview feed, Record / shutter, timecode and storage). The iPhone owns the camera radio;
/// the watch is a WatchConnectivity remote. Each watch app names itself for the placeholder.
public struct WatchCompanionScene: Scene {
    private let openOnIPhone: String

    public init(openOnIPhone: String) {
        self.openOnIPhone = openOnIPhone
    }

    /// `appName` fills the shared "Open <app> on iPhone" placeholder.
    public init(appName: String) {
        self.init(openOnIPhone: WatchRelayCopy.openOnIPhone(appName: appName))
    }

    public var body: some Scene {
        WatchReceiverScene(receiver: WatchSessionController()) { _ in
            WatchMonitorView(openOnIPhone: openOnIPhone)
        }
    }
}
#endif
