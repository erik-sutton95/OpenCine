#if os(iOS)
    import MonitorUI
    import OpenCineAppKitApple
    import SwiftUI

    /// The app side of the watcher browse screen: the shared feeds found, the join status and the
    /// browse, join and leave actions.
    @MainActor
    public protocol WatcherBrowseHost: AnyObject, Observable {
        associatedtype Palette: LiveChromePalette
        var watcherJoinStatus: WatcherJoinStatus { get }
        var watcherFeeds: [WatcherFeedRow] { get }
        var watcherBrowseError: String? { get }
        func startWatcherBrowse()
        func joinWatcherFeed(id: String)
        func retryWatcherPasscode(_ code: String)
        func stopWatching()
    }

    /// Finds a feed another phone shares on the camera Wi-Fi and joins it.
    public struct WatcherBrowse<Host: WatcherBrowseHost>: View {
        @Environment(Host.self) private var host
        @State private var passcode = ""
        @Environment(\.scenePhase) private var scenePhase

        public init() {}

        public var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Watch a feed")
                            .font(MonitorTheme.font(22, weight: .bold))
                            .foregroundStyle(StartupColors.ink)
                        Spacer()
                        Button("Close") { host.stopWatching() }
                            .font(MonitorTheme.font(15, weight: .semibold))
                    }
                    Text(
                        "Join the same camera Wi-Fi as the sharing phone first. On that phone, open Operator Setup → Sharing → Show Wi-Fi code. Scan it with Camera, join the network, then return here."
                    )
                    .font(MonitorTheme.font(13, weight: .regular))
                    .foregroundStyle(StartupColors.muted)

                    Text(
                        "Already joined? Choose the shared feed below. Keep the camera connection inside the app on the sharing phone only."
                    )
                    .font(MonitorTheme.font(13, weight: .regular))
                    .foregroundStyle(StartupColors.muted)
                    Button("Find shared feeds") { host.startWatcherBrowse() }
                        .buttonStyle(StartupFilledButtonStyle())

                    switch host.watcherJoinStatus {
                    case .needsPasscode:
                        passcodePrompt
                    case .failed(let message):
                        Text(message)
                            .font(MonitorTheme.font(14, weight: .medium))
                            .foregroundStyle(Host.Palette.rec)
                    case .reconnecting(let attempt, let maximum):
                        Text("Reconnecting… \(attempt) of \(maximum)")
                            .font(MonitorTheme.font(14, weight: .medium))
                            .foregroundStyle(StartupColors.muted)
                    case .connecting:
                        Text("Joining…")
                            .font(MonitorTheme.font(14, weight: .medium))
                            .foregroundStyle(StartupColors.muted)
                    default:
                        EmptyView()
                    }

                    if host.watcherFeeds.isEmpty {
                        Text(
                            host.watcherBrowseError
                                ?? "No shared feeds on this network. Check that both devices joined the same camera Wi-Fi and Share this feed is on. Allow Local Network if asked."
                        )
                        .font(MonitorTheme.font(14, weight: .regular))
                        .foregroundStyle(StartupColors.muted)
                        .padding(.top, 8)
                    } else {
                        ForEach(host.watcherFeeds) { feed in
                            Button {
                                host.joinWatcherFeed(id: feed.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feed.name)
                                        .font(MonitorTheme.font(16, weight: .semibold))
                                        .foregroundStyle(StartupColors.ink)
                                    if !feed.cameraName.isEmpty {
                                        Text(feed.cameraName)
                                            .font(MonitorTheme.font(12, weight: .regular))
                                            .foregroundStyle(StartupColors.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
                .padding(20)
            }
            .monitorScrollFade()
            .onAppear { host.startWatcherBrowse() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { host.startWatcherBrowse() }
            }
        }

        private var passcodePrompt: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("This feed needs a passcode.")
                    .font(MonitorTheme.font(14, weight: .medium))
                SecureField("Passcode", text: $passcode)
                    .textFieldStyle(.roundedBorder)
                Button("Join") {
                    host.retryWatcherPasscode(passcode)
                }
                .buttonStyle(StartupFilledButtonStyle())
            }
        }
    }
#endif
