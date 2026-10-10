#if os(watchOS)
import SwiftUI

/// The watch companion's scene: the iPhone monitor on the wrist (a 16:9 preview feed, Record /
/// shutter, timecode and storage). The iPhone owns the camera radio; the watch is a
/// WatchConnectivity remote. Each watch app's `@main` passes its own placeholder copy.
public struct WatchCompanionScene: Scene {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = WatchSessionController()
    private let openOnIPhone: String

    public init(openOnIPhone: String) {
        self.openOnIPhone = openOnIPhone
    }

    public var body: some Scene {
        WindowGroup {
            WatchMonitorView(openOnIPhone: openOnIPhone)
                .environment(controller)
                .onAppear { controller.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { controller.resume() }
                }
        }
    }
}
#endif
