#if canImport(Darwin)
    import Foundation

    /// `URLSession` transport for Apple apps. Android shells bring their own (OkHttp), so this
    /// file compiles only where `URLSession` needs no FoundationNetworking.
    public struct FrameioURLSessionTransport: FrameioHTTPTransport {
        private let session: URLSession

        public init(session: URLSession) { self.session = session }

        /// Short request timeout for interactive API, token and upload-part calls: on a camera
        /// access point there is no internet route, and the default 60 s timeout showed up as
        /// minute-long hangs and launch-log IMS timeout spam.
        public static let interactive = FrameioURLSessionTransport(
            session: {
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 12
                configuration.waitsForConnectivity = false
                return URLSession(configuration: configuration)
            }())

        public func send(_ request: FrameioAPIRequest) async throws -> FrameioHTTPResponse {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method.rawValue
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response): (Data, URLResponse)
            if request.method == .put, let body = request.body {
                (data, response) = try await session.upload(for: urlRequest, from: body)
            } else {
                urlRequest.httpBody = request.body
                (data, response) = try await session.data(for: urlRequest)
            }
            // A non-HTTP response (file or custom protocol) carries no status; treat it as 200,
            // as the app clients did.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            return FrameioHTTPResponse(statusCode: status, body: data)
        }
    }
#endif
