#if os(iOS) || os(macOS)
    import Foundation
    import MonitorPresentation

    enum MonitorTeleprompterLoadError: LocalizedError {
        case tooLarge, response
        var errorDescription: String? {
            switch self {
            case .tooLarge: "The script is larger than 1 MiB. Choose a smaller text file."
            case .response:
                "The link did not return a readable HTTPS text file. Use a direct TXT or Markdown link."
            }
        }
    }

    enum MonitorTeleprompterLoader {
        static func file(_ url: URL) async throws -> TeleprompterScript {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let remaining = TeleprompterScriptImport.maximumBytes + 1 - data.count
                guard remaining > 0 else { throw MonitorTeleprompterLoadError.tooLarge }
                guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty
                else { break }
                data.append(chunk)
                if data.count > TeleprompterScriptImport.maximumBytes {
                    throw MonitorTeleprompterLoadError.tooLarge
                }
            }
            try Task.checkCancellation()
            return try TeleprompterScriptImport.decode(data, name: url.lastPathComponent)
        }

        static func remote(
            _ url: URL, configuration: URLSessionConfiguration = .ephemeral
        ) async throws -> TeleprompterScript {
            let validated = try TeleprompterScriptImport.link(url.absoluteString)
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(
                configuration: configuration, delegate: MonitorTeleprompterRedirects(),
                delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(
                for: URLRequest(url: validated, timeoutInterval: 30))
            guard let response = response as? HTTPURLResponse,
                (200...299).contains(response.statusCode),
                let finalURL = response.url,
                (try? TeleprompterScriptImport.link(finalURL.absoluteString)) != nil
            else { throw MonitorTeleprompterLoadError.response }
            guard response.expectedContentLength <= TeleprompterScriptImport.maximumBytes else {
                throw MonitorTeleprompterLoadError.tooLarge
            }
            var data = Data()
            for try await byte in bytes {
                if data.count >= TeleprompterScriptImport.maximumBytes {
                    throw MonitorTeleprompterLoadError.tooLarge
                }
                data.append(byte)
                if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return try TeleprompterScriptImport.decode(
                data, name: finalURL.lastPathComponent,
                sourceURL: validated, contentType: response.mimeType)
        }
    }

    private final class MonitorTeleprompterRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(
                request.url.flatMap { try? TeleprompterScriptImport.link($0.absoluteString) } == nil
                    ? nil : request)
        }
    }
#endif
