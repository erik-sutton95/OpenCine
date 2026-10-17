import Foundation
import OpenCineCameraVocabulary

/// A LUT pack the operator downloads from its maker's own web page (the maker's terms are accepted
/// there, never bundled): the page, the hosts a download may come from, the cookie origins that
/// carry the session, the page scripts that keep the terms on screen, and the operator copy. The
/// Swift twin of the Kotlin `MonitorLutPackSource` (camera-controls).
public struct MonitorLutPackSource: Sendable {
    public let pageUrl: String
    /// Cache file name for the in-progress archive.
    public let archiveFileName: String
    public let isAllowedDownload: @Sendable (String) -> Bool
    /// Origins whose web cookies authorise the archive fetch when the download host has none.
    public let cookieOrigins: [String]
    /// Injected at page start: a cover while the maker's terms load.
    public let loadingScript: String?
    /// Injected at page end: keeps only the terms dialog and its download action.
    public let helperScript: String?
    public let copy: MonitorLutPackCopy

    public init(
        pageUrl: String, archiveFileName: String,
        isAllowedDownload: @escaping @Sendable (String) -> Bool, cookieOrigins: [String],
        loadingScript: String? = nil, helperScript: String? = nil, copy: MonitorLutPackCopy
    ) {
        self.pageUrl = pageUrl
        self.archiveFileName = archiveFileName
        self.isAllowedDownload = isAllowedDownload
        self.cookieOrigins = cookieOrigins
        self.loadingScript = loadingScript
        self.helperScript = helperScript
        self.copy = copy
    }
}

/// Every word the pack flow shows; the maker's name and the app's name arrive here. The fields
/// after `downloadFailed` name states only the Apple web view has (its own page cover, a link it
/// cannot read, a page process that keeps dying, a download that never starts).
public struct MonitorLutPackCopy: Sendable {
    public let intro: String
    public let introDetail: String
    public let continueLabel: String
    public let hopReady: String
    public let hopUnavailable: String
    public let downloading: String
    public let success: @Sendable (Int) -> String
    public let successDetail: String
    public let unexpectedSite: String
    public let noFile: String
    public let pageFailed: String
    public let httpFailure: @Sendable (Int) -> String
    public let webPageInsteadOfArchive: String
    public let notAnArchive: String
    public let blockedTitle: String
    public let switching: String
    public let hopAction: String
    public let importing: String
    public let failedTitle: String
    public let downloadFailed: String
    public let opening: String
    public let offline: String
    public let unreadableLink: String
    public let pageKeptClosing: String
    public let downloadNotStarted: String

    public init(
        intro: String, introDetail: String, continueLabel: String, hopReady: String,
        hopUnavailable: String, downloading: String, success: @escaping @Sendable (Int) -> String,
        successDetail: String, unexpectedSite: String, noFile: String, pageFailed: String,
        httpFailure: @escaping @Sendable (Int) -> String, webPageInsteadOfArchive: String,
        notAnArchive: String, blockedTitle: String = "Internet required",
        switching: String = "Switching networks…", hopAction: String = "Download over internet",
        importing: String = "Adding LUTs…", failedTitle: String = "Download failed",
        downloadFailed: String = "Download failed.",
        opening: String = "Opening the download page…",
        offline: String = "No internet connection right now. Reconnect and try again.",
        unreadableLink: String = "Couldn't read the download link. Please try again.",
        pageKeptClosing: String = "The download page kept closing. Please try again.",
        downloadNotStarted: String =
            "The download didn't start. Please accept the terms and try again."
    ) {
        self.intro = intro
        self.introDetail = introDetail
        self.continueLabel = continueLabel
        self.hopReady = hopReady
        self.hopUnavailable = hopUnavailable
        self.downloading = downloading
        self.success = success
        self.successDetail = successDetail
        self.unexpectedSite = unexpectedSite
        self.noFile = noFile
        self.pageFailed = pageFailed
        self.httpFailure = httpFailure
        self.webPageInsteadOfArchive = webPageInsteadOfArchive
        self.notAnArchive = notAnArchive
        self.blockedTitle = blockedTitle
        self.switching = switching
        self.hopAction = hopAction
        self.importing = importing
        self.failedTitle = failedTitle
        self.downloadFailed = downloadFailed
        self.opening = opening
        self.offline = offline
        self.unreadableLink = unreadableLink
        self.pageKeptClosing = pageKeptClosing
        self.downloadNotStarted = downloadNotStarted
    }

    /// Turns a failed page load into a sentence without inventing a cause: the host's network
    /// verdict when it has one, the OS's own "no route" when that is the code, else the page's
    /// plain failure. A request that failed on a working network says nothing about which network.
    public func pageLoadFailure(_ error: NSError, readiness: MonitorLutPackReadiness) -> String {
        if readiness.network.blocksDownload { return readiness.message }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorNotConnectedToInternet {
            return offline
        }
        return pageFailed
    }
}

/// Where the phone's internet stands for the pack download, decided by the host's network policy.
public enum MonitorLutPackNetwork: Sendable, Equatable {
    case available, onCameraAccessPoint, noInternet, policyUnavailable

    /// No internet path: on the camera's access point or offline.
    public var blocksDownload: Bool { self == .onCameraAccessPoint || self == .noInternet }
}

/// The network state and the operator's words for it.
public struct MonitorLutPackReadiness: Sendable, Equatable {
    public let network: MonitorLutPackNetwork
    public let message: String

    public init(network: MonitorLutPackNetwork, message: String) {
        self.network = network
        self.message = message
    }
}

/// The host's camera access point hop: leave the camera's Wi-Fi for an internet route and rejoin
/// it after the flow closes. Absent when this surface cannot hop.
@MainActor
public protocol MonitorLutPackInternetHop: AnyObject {
    /// True when a hop can start now.
    var ready: Bool { get }
    /// Why a hop cannot start, when `ready` is false.
    var unavailableMessage: String? { get }
    /// Leaving the camera or waiting for internet.
    var switching: Bool { get }
    var active: Bool { get }
    var errorMessage: String? { get }
    func begin() async -> Bool
    /// Rejoins the camera after the flow has closed; never awaited before closing.
    func endAfterDismiss()
}

/// What the host's import made of the downloaded file: a count, or the operator's failure words.
public enum MonitorLutPackOutcome: Sendable, Equatable {
    case imported(count: Int)
    case failed(message: String)
}

#if canImport(Darwin)
    /// The web cookies for `url`, else the first of the source's origins that has a session.
    public func lutPackCookies(
        source: MonitorLutPackSource, url: String, read: (String) -> [HTTPCookie]
    ) -> [HTTPCookie] {
        let own = read(url)
        if !own.isEmpty { return own }
        for origin in source.cookieOrigins {
            let cookies = read(origin)
            if !cookies.isEmpty { return cookies }
        }
        return []
    }

    /// The cookies of `jar` a request to `url` carries (domain match, as WebKit sends them).
    public func lutPackCookies(in jar: [HTTPCookie], for url: String) -> [HTTPCookie] {
        guard let host = URL(string: url)?.host?.lowercased() else { return [] }
        return jar.filter { cookie in
            let raw = cookie.domain.lowercased()
            let domain = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
            return host == domain || host.hasSuffix("." + domain)
        }
    }

#endif

/// What the fetched file is: the archive, or the source's words for why it is not.
public func lutPackArchiveCheck(_ file: URL, copy: MonitorLutPackCopy) -> Result<
    URL, MonitorLutPackFetchError
> {
    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size > 0 else { return .failure(.init(message: copy.noFile)) }
    if file.looksLikeZipArchive { return .success(file) }
    let head =
        (try? FileHandle(forReadingFrom: file)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 64)
        } ?? Data()
    let text = String(decoding: head, as: UTF8.self)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
        || text.lowercased().contains("html")
    {
        return .failure(.init(message: copy.webPageInsteadOfArchive))
    }
    return .failure(.init(message: copy.notAnArchive))
}

/// A pack fetch that did not leave an archive, in the source's words.
public struct MonitorLutPackFetchError: Error, Equatable, Sendable {
    public let message: String
}

#if os(iOS)
    import MonitorUI
    import SwiftUI
    import OpenCineApple

    /// The full-screen pack download: a gateway (terms, blocked or hop), the maker's real page in
    /// a web view, the fetched archive, then the host's import. Closing never waits for the camera
    /// rejoin. The Swift twin of the Kotlin `MonitorLutPackDownloadScreen`.
    public struct MonitorLutPackDownloadScreen: View {
        let source: MonitorLutPackSource
        let readiness: () -> MonitorLutPackReadiness
        let hop: (any MonitorLutPackInternetHop)?
        /// Shown when the operator asks for a hop and this surface has none.
        let noHopMessage: String
        /// Shown when a hop fails without its own words.
        let hopFailedMessage: String
        let closeLabel: String
        let importPack: (URL) async -> MonitorLutPackOutcome
        let onClose: () -> Void
        let onImported: (Int) -> Void

        @State private var phase: Phase = .gateway
        @State private var progress: Double = 0
        @State private var hopBusy = false
        @State private var hopError: String?
        @State private var pageCommitted = false
        @State private var reloadToken = 0
        @State private var pageLoadWatchdog: Task<Void, Never>?

        enum Phase: Equatable {
            case gateway, browsing, downloading, importing
            case success(Int)
            case failed(String)
        }

        public init(
            source: MonitorLutPackSource, readiness: @escaping () -> MonitorLutPackReadiness,
            hop: (any MonitorLutPackInternetHop)?, noHopMessage: String, hopFailedMessage: String,
            closeLabel: String, importPack: @escaping (URL) async -> MonitorLutPackOutcome,
            onClose: @escaping () -> Void, onImported: @escaping (Int) -> Void = { _ in }
        ) {
            self.source = source
            self.readiness = readiness
            self.hop = hop
            self.noHopMessage = noHopMessage
            self.hopFailedMessage = hopFailedMessage
            self.closeLabel = closeLabel
            self.importPack = importPack
            self.onClose = onClose
            self.onImported = onImported
        }

        private var copy: MonitorLutPackCopy { source.copy }

        public var body: some View {
            let state = readiness()
            ZStack(alignment: .topLeading) {
                MonitorTheme.background.ignoresSafeArea()
                if phase != .gateway {
                    webPage
                        .allowsHitTesting(phase == .browsing)
                        .accessibilityHidden(phase != .browsing)
                }
                switch phase {
                case .gateway:
                    gateway(state)
                case .browsing:
                    // The native page stays mounted behind every progress and result cover.
                    if !pageCommitted { statusPage(title: copy.opening, spinner: true) }
                case .downloading:
                    statusPage(
                        title: copy.downloading, progress: progress, secondary: ("Cancel", onClose))
                case .importing:
                    statusPage(title: copy.importing, spinner: true, secondary: ("Cancel", onClose))
                case .success(let count):
                    statusPage(
                        title: copy.success(count), body: copy.successDetail,
                        primary: ("Done", onClose))
                case .failed(let message):
                    statusPage(
                        title: copy.failedTitle, body: message,
                        primary: (
                            "Retry",
                            {
                                phase = .gateway
                                progress = 0
                            }
                        ),
                        secondary: (closeLabel, onClose))
                }
                Button(action: onClose) {
                    MonitorIcon.x.frame(width: 18, height: 18)
                        .foregroundStyle(MonitorTheme.text)
                        .frame(width: 44, height: 44)
                        .background(MonitorTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.monitorTapTarget)
                .accessibilityLabel(closeLabel)
                .padding(.leading, 8)
                .padding(.top, 4)
            }
            .animation(.easeInOut(duration: 0.2), value: phase)
            .onChange(of: state.network) { _, network in
                if network == .available { hopError = nil }
                // A route lost mid-flow is said at once, never left to a stalled page.
                guard network.blocksDownload else { return }
                switch phase {
                case .browsing, .downloading, .importing: phase = .failed(state.message)
                default: break
                }
            }
            .onChange(of: phase) { _, next in
                if next == .browsing { armPageLoadWatchdog() }
            }
            .onDisappear {
                pageLoadWatchdog?.cancel()
                // The camera rejoins after the cover is gone; closing never waits for it.
                if let hop, hop.active { hop.endAfterDismiss() }
            }
        }

        private var webPage: some View {
            PackWebView(
                source: source, currentReadiness: readiness,
                onCommitted: {
                    pageCommitted = true
                    pageLoadWatchdog?.cancel()
                },
                onDownloadStarted: { phase = .downloading },
                onProgress: { fraction in progress = fraction },
                onFileReady: { file in
                    phase = .importing
                    Task { @MainActor in
                        let outcome = await importPack(file)
                        try? FileManager.default.removeItem(at: file)
                        switch outcome {
                        case .imported(let count):
                            onImported(count)
                            phase = .success(count)
                        case .failed(let message):
                            phase = .failed(message)
                        }
                    }
                },
                onFailed: { message in
                    pageLoadWatchdog?.cancel()
                    phase = .failed(message)
                }
            )
            .id(reloadToken)
            .ignoresSafeArea()
        }

        private var switching: Bool { hopBusy || hop?.switching == true }

        private func requestHop() {
            guard let hop else {
                hopError = noHopMessage
                return
            }
            guard hop.ready else {
                hopError =
                    hop.unavailableMessage.flatMap { $0.isEmpty ? nil : $0 } ?? hopFailedMessage
                return
            }
            Task { @MainActor in
                hopBusy = true
                hopError = nil
                let ok = await hop.begin()
                hopBusy = false
                if !ok { hopError = hop.errorMessage ?? hopFailedMessage }
            }
        }

        private func start(_ state: MonitorLutPackReadiness) {
            switch state.network {
            case .available, .policyUnavailable:
                pageCommitted = false
                reloadToken += 1
                phase = .browsing
            case .onCameraAccessPoint: requestHop()
            case .noInternet: break
            }
        }

        /// A page that never commits (typical on the camera's access point or offline) fails.
        private func armPageLoadWatchdog() {
            pageLoadWatchdog?.cancel()
            pageLoadWatchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, phase == .browsing, !pageCommitted else { return }
                let state = readiness()
                phase = .failed(state.network.blocksDownload ? state.message : copy.pageFailed)
            }
        }

        @ViewBuilder private func gateway(_ state: MonitorLutPackReadiness) -> some View {
            VStack(spacing: 0) {
                if state.network.blocksDownload || switching {
                    text(copy.blockedTitle, size: 20, weight: .bold, color: MonitorTheme.text)
                    Spacer().frame(height: 12)
                    if switching {
                        ProgressView().tint(MonitorTheme.accent).controlSize(.regular)
                        Spacer().frame(height: 12)
                        text(copy.switching, size: 14, weight: .semibold, color: MonitorTheme.text)
                    } else {
                        text(hopError ?? state.message, size: 14, color: MonitorTheme.muted)
                        Spacer().frame(height: 20)
                        if state.network == .onCameraAccessPoint {
                            let canHop = hop?.ready == true
                            action(
                                copy.hopAction, primary: true, enabled: canHop, perform: requestHop)
                            Spacer().frame(height: 8)
                            text(
                                canHop ? copy.hopReady : copy.hopUnavailable, size: 12,
                                color: MonitorTheme.muted)
                        }
                    }
                    Spacer().frame(height: 16)
                    action(switching ? "Cancel" : closeLabel, primary: false, perform: onClose)
                } else {
                    text(copy.intro, size: 15, weight: .medium, color: MonitorTheme.text)
                    Spacer().frame(height: 12)
                    text(copy.introDetail, size: 13, color: MonitorTheme.muted)
                    Spacer().frame(height: 24)
                    action(copy.continueLabel, primary: true) { start(readiness()) }
                    Spacer().frame(height: 12)
                    action(closeLabel, primary: false, perform: onClose)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func statusPage(
            title: String, body: String? = nil, progress: Double? = nil, spinner: Bool = false,
            primary: (String, () -> Void)? = nil, secondary: (String, () -> Void)? = nil
        ) -> some View {
            VStack(spacing: 0) {
                if spinner {
                    ProgressView().tint(MonitorTheme.accent).controlSize(.large)
                    Spacer().frame(height: 16)
                }
                text(title, size: 18, weight: .bold, color: MonitorTheme.text)
                if let body {
                    Spacer().frame(height: 10)
                    text(body, size: 13, color: MonitorTheme.muted)
                }
                if let progress {
                    Spacer().frame(height: 16)
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(MonitorTheme.accent)
                        .frame(maxWidth: 300)
                }
                if let primary {
                    Spacer().frame(height: 20)
                    action(primary.0, primary: true, perform: primary.1)
                }
                if let secondary {
                    Spacer().frame(height: 10)
                    action(secondary.0, primary: false, perform: secondary.1)
                }
            }
            .padding(28)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MonitorTheme.background.ignoresSafeArea())
            // The maker's page behind the status page cannot be touched.
            .contentShape(Rectangle())
            .onTapGesture {}
        }

        private func text(
            _ value: String, size: CGFloat, weight: Font.Weight = .regular, color: Color
        ) -> some View {
            Text(value)
                .font(MonitorTheme.font(size, weight: weight))
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }

        private func action(
            _ title: String, primary: Bool, enabled: Bool = true, perform: @escaping () -> Void
        ) -> some View {
            Button(action: perform) {
                Text(title).frame(maxWidth: .infinity, minHeight: 45)
            }
            .buttonStyle(CameraPageButtonStyle(primary: primary))
            .disabled(!enabled)
            .accessibilityLabel(title)
        }
    }

    /// The maker's page with the source's scripts. A popup (`window.open`) or an attachment
    /// navigation to an allowed host is fetched in-process with the page's cookies and user agent;
    /// WebKit never downloads it itself (its popup process swap fails the load).
    private struct PackWebView: UIViewRepresentable {
        let source: MonitorLutPackSource
        /// Read at failure time, not at open time: the phone can change networks while it loads.
        let currentReadiness: () -> MonitorLutPackReadiness
        let onCommitted: () -> Void
        let onDownloadStarted: () -> Void
        let onProgress: (Double) -> Void
        let onFileReady: (URL) -> Void
        let onFailed: (String) -> Void

        func makeUIView(context: Context) -> MonitorWebDownloadView {
            MonitorWebDownloadView(
                configuration: .init(
                    pageURL: source.pageUrl, archiveFileName: source.archiveFileName,
                    isAllowedDownload: source.isAllowedDownload,
                    loadingScript: source.loadingScript, helperScript: source.helperScript,
                    backgroundColor: UIColor(MonitorTheme.background)),
                cookiesForDownload: { jar, url in
                    lutPackCookies(source: source, url: url) { origin in
                        lutPackCookies(in: jar, for: origin)
                    }
                },
                onCommitted: onCommitted, onDownloadStarted: onDownloadStarted,
                onProgress: onProgress,
                onFileReady: { file in
                    switch lutPackArchiveCheck(file, copy: source.copy) {
                    case .success(let archive): onFileReady(archive)
                    case .failure(let failure):
                        try? FileManager.default.removeItem(at: file)
                        onFailed(failure.message)
                    }
                },
                onFailed: { failure in onFailed(message(for: failure)) })
        }

        func updateUIView(_ webView: MonitorWebDownloadView, context: Context) {}

        static func dismantleUIView(_ webView: MonitorWebDownloadView, coordinator: ()) {
            webView.close()
        }

        private func message(for failure: MonitorWebDownloadView.Failure) -> String {
            let copy = source.copy
            switch failure {
            case .navigation(let error):
                return copy.pageLoadFailure(error, readiness: currentReadiness())
            case .unreadableLink: return copy.unreadableLink
            case .unexpectedSite: return copy.unexpectedSite
            case .pageKeptClosing: return copy.pageKeptClosing
            case .downloadNotStarted: return copy.downloadNotStarted
            case .noFile: return copy.noFile
            case .transport(let message): return message.isEmpty ? copy.downloadFailed : message
            case .httpStatus(let code): return copy.httpFailure(code)
            }
        }
    }
#endif
