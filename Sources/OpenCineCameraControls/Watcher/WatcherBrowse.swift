#if os(iOS)
    import MonitorPresentation
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
        var watcherPasscodeError: String? { get }
        func startWatcherBrowse()
        func joinWatcherFeed(id: String)
        func retryWatcherPasscode(_ code: String)
        func stopWatching()
    }

    extension WatcherBrowseHost {
        /// Hosts without a separate passcode refusal keep the original prompt.
        public var watcherPasscodeError: String? { nil }
    }

    /// Finds a feed another phone shares on the host's supported network and joins it.
    public struct WatcherBrowse<Host: WatcherBrowseHost>: View {
        @Environment(Host.self) private var host
        @State private var passcode = ""
        @Environment(\.scenePhase) private var scenePhase

        private let networkInstructions: String
        private let emptyMessage: String

        /// Network guidance is a host value; the sharing transport keeps its existing owner.
        public init(
            networkInstructions: String =
                "Join the same camera Wi-Fi as the sharing phone first. On that phone, open Operator Setup → Sharing → Show Wi-Fi code. Scan it with Camera, join the network, then return here.",
            emptyMessage: String =
                "No shared feeds on this network. Check that both devices joined the same camera Wi-Fi and Share this feed is on. Allow Local Network if asked."
        ) {
            self.networkInstructions = networkInstructions
            self.emptyMessage = emptyMessage
        }

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
                    Text(networkInstructions)
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
                            host.watcherBrowseError ?? emptyMessage
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
                                    if let cameraName = feed.cameraName, !cameraName.isEmpty {
                                        Text(cameraName)
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
                if let error = host.watcherPasscodeError {
                    Text(error)
                        .font(MonitorTheme.font(14, weight: .medium))
                        .foregroundStyle(Host.Palette.rec)
                }
                SecureField("Passcode", text: $passcode)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.join)
                    .onSubmit(join)
                Button("Join", action: join)
                    .buttonStyle(StartupFilledButtonStyle())
                    .disabled(MonitorWatcherPasscodeRule.answer(passcode) == nil)
            }
        }

        /// The host decides whether the code is right; any non-empty answer is sent, trimmed.
        private func join() {
            guard let code = MonitorWatcherPasscodeRule.answer(passcode) else { return }
            host.retryWatcherPasscode(code)
        }
    }
#endif
