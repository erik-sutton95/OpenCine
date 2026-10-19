#if os(iOS)
    import Foundation
    import UIKit
    import WebKit

    /// The native web page and cookie-bound download owner. Composition supplies the maker's
    /// page, scripts, host policy and callbacks; no app, camera or LUT policy lives here.
    @MainActor
    public final class MonitorWebDownloadView: UIView, WKNavigationDelegate, WKUIDelegate {
        /// Native failures are values; the composing screen supplies their operator wording.
        public enum Failure {
            case navigation(NSError)
            case unreadableLink, unexpectedSite, pageKeptClosing, downloadNotStarted, noFile
            case transport(String)
            case httpStatus(Int)
        }

        /// Immutable platform input, independent of the screen that presents the web page.
        public struct Configuration {
            fileprivate let pageURL: String
            fileprivate let archiveFileName: String
            fileprivate let isAllowedDownload: @Sendable (String) -> Bool
            fileprivate let loadingScript: String?
            fileprivate let helperScript: String?
            fileprivate let backgroundColor: UIColor

            public init(
                pageURL: String, archiveFileName: String,
                isAllowedDownload: @escaping @Sendable (String) -> Bool,
                loadingScript: String? = nil, helperScript: String? = nil,
                backgroundColor: UIColor
            ) {
                self.pageURL = pageURL
                self.archiveFileName = archiveFileName
                self.isAllowedDownload = isAllowedDownload
                self.loadingScript = loadingScript
                self.helperScript = helperScript
                self.backgroundColor = backgroundColor
            }
        }

        private let configuration: Configuration
        private let browser: WKWebView
        private let cookiesForDownload: ([HTTPCookie], String) -> [HTTPCookie]
        private let onCommitted: () -> Void
        private let onDownloadStarted: () -> Void
        private let onProgress: (Double) -> Void
        private let onFileReady: (URL) -> Void
        private let onFailed: (Failure) -> Void
        private var fetching = false
        private var completed = false
        private var watchdog: Task<Void, Never>?
        private var progressObservation: NSKeyValueObservation?
        private var transfer: URLSessionDownloadTask?
        private var reloadCount = 0
        private var cachedUserAgent: String?
        private var cachedCookies: [HTTPCookie] = []

        public init(
            configuration: Configuration,
            cookiesForDownload: @escaping ([HTTPCookie], String) -> [HTTPCookie],
            onCommitted: @escaping () -> Void, onDownloadStarted: @escaping () -> Void,
            onProgress: @escaping (Double) -> Void, onFileReady: @escaping (URL) -> Void,
            onFailed: @escaping (Failure) -> Void
        ) {
            self.configuration = configuration
            self.cookiesForDownload = cookiesForDownload
            self.onCommitted = onCommitted
            self.onDownloadStarted = onDownloadStarted
            self.onProgress = onProgress
            self.onFileReady = onFileReady
            self.onFailed = onFailed
            let web = WKWebViewConfiguration()
            if let script = configuration.loadingScript {
                web.userContentController.addUserScript(
                    WKUserScript(
                        source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            if let script = configuration.helperScript {
                web.userContentController.addUserScript(
                    WKUserScript(
                        source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            web.preferences.javaScriptCanOpenWindowsAutomatically = true
            browser = WKWebView(frame: .zero, configuration: web)
            super.init(frame: .zero)
            backgroundColor = configuration.backgroundColor
            browser.navigationDelegate = self
            browser.uiDelegate = self
            browser.isOpaque = false
            browser.backgroundColor = configuration.backgroundColor
            browser.scrollView.backgroundColor = configuration.backgroundColor
            browser.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(browser)
            if let url = URL(string: configuration.pageURL) { browser.load(URLRequest(url: url)) }
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) { fatalError("Use the configuration initializer") }

        /// Retires this native owner without waiting for a transfer or a page process.
        public func close() {
            completed = true
            watchdog?.cancel()
            progressObservation?.invalidate()
            transfer?.cancel()
            transfer = nil
            browser.stopLoading()
            browser.navigationDelegate = nil
            browser.uiDelegate = nil
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onCommitted()
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
                if let agent = result as? String { self?.cachedUserAgent = agent }
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                [weak self] cookies in
                self?.cachedCookies = cookies
            }
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !completed else { return }
            guard reloadCount < 2, let url = URL(string: configuration.pageURL) else {
                fail(.pageKeptClosing)
                return
            }
            reloadCount += 1
            webView.load(URLRequest(url: url))
        }

        public func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) { navigationFailed(error) }

        public func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            navigationFailed(error)
        }

        private func navigationFailed(_ error: Error) {
            let error = error as NSError
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain", error.code == 102 { return }
            guard !fetching, !completed else { return }
            fail(.navigation(error))
        }

        public func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https"
            {
                fetchDownload(url)
            } else {
                fail(.unreadableLink)
            }
            return nil
        }

        public func webView(
            _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            let attachment =
                (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains(
                    "attachment") ?? false
            if !navigationResponse.canShowMIMEType || attachment,
                let url = navigationResponse.response.url
            {
                fetchDownload(url)
                return .cancel
            }
            return .allow
        }

        private func markStarted() {
            guard watchdog == nil, !completed else { return }
            onDownloadStarted()
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self else { return }
                self.fail(.downloadNotStarted)
            }
        }

        private func finish(_ url: URL) {
            guard !completed else { return }
            completed = true
            watchdog?.cancel()
            progressObservation?.invalidate()
            transfer = nil
            onFileReady(url)
        }

        private func fail(_ reason: Failure) {
            guard !completed else { return }
            completed = true
            watchdog?.cancel()
            progressObservation?.invalidate()
            transfer?.cancel()
            transfer = nil
            onFailed(reason)
        }

        private func fetchDownload(_ url: URL) {
            guard !fetching, !completed else { return }
            guard configuration.isAllowedDownload(url.absoluteString) else {
                fail(.unexpectedSite)
                return
            }
            fetching = true
            markStarted()
            let cookies = cookiesForDownload(cachedCookies, url.absoluteString)
            var request = URLRequest(url: url)
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if let agent = cachedUserAgent {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue(configuration.pageURL, forHTTPHeaderField: "Referer")
            startDownload(request)
        }

        private func startDownload(_ request: URLRequest) {
            guard !completed else { return }
            watchdog?.cancel()
            let name = configuration.archiveFileName
            let task = URLSession.shared.downloadTask(with: request) {
                [weak self] location, response, error in
                var moved: URL?
                if let location {
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
                        name)
                    try? FileManager.default.removeItem(at: destination)
                    if (try? FileManager.default.moveItem(at: location, to: destination)) != nil {
                        moved = destination
                    }
                }
                let status = (response as? HTTPURLResponse)?.statusCode
                let message = error?.localizedDescription
                let file = moved
                Task { @MainActor in
                    guard let self, !self.completed else {
                        if let file { try? FileManager.default.removeItem(at: file) }
                        return
                    }
                    if let message {
                        if let file { try? FileManager.default.removeItem(at: file) }
                        self.fail(.transport(message))
                    } else if let status, !(200..<300).contains(status) {
                        if let file { try? FileManager.default.removeItem(at: file) }
                        self.fail(.httpStatus(status))
                    } else if let file {
                        self.onProgress(1)
                        self.finish(file)
                    } else {
                        self.fail(.noFile)
                    }
                }
            }
            transfer = task
            // URLSession updates the progress on its own queue: no main-actor isolation, or Swift 6
            // traps on entry where the SDK does not import the KVO handler as @Sendable.
            progressObservation = task.progress.observe(\.fractionCompleted) {
                @Sendable [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self?.onProgress(fraction) }
            }
            task.resume()
        }
    }
#endif
