import Foundation
import Insta360Apple
import Insta360Protocol
import OpenCineCore

/// A Luna camera behind a session's link, for tests: it applies the real SET bodies the session
/// builds and answers readbacks in the real reply encodings.
@MainActor
public final class FakeLuna {
    public init() {}

    public var program: UInt64 = 0
    public var iso: UInt64 = 0
    public var shutterSeconds = 0.0
    /// The camera reads its exposure back through single precision, as a real Luna can: 1/60
    /// returns as 0.016666668 (1/59.99999), never bit-exact.
    public var reportsSinglePrecisionShutter = false
    public var kelvin: UInt64 = 5600
    public var colorMode: UInt64?
    public var zoom = 1.0
    public var afMode: UInt64 = 1
    /// Capture state (cmd 15); nil sends no reply at all.
    public var captureState: UInt64? = 0
    /// The camera acknowledges SETs and record commands but stores nothing.
    public var ignoresWrites = false
    /// A stored value changes this long after its SET is acknowledged.
    public var applyDelay: Duration = .zero
    public var silent = false
    /// The camera answers every request with a refusal (Kotlin `FakeLuna.refuses`).
    public var refuses = false
    /// Runs after a request is received and before its reply, so a test can deliver camera
    /// reports in the window before the acknowledgement (a format readback that beats the ack).
    public var beforeReply: (@MainActor (LunaRequest) async -> Void)?
    public private(set) var sent: [LunaRequest] = []
    private var lastApply: Task<Void, Never>?
    public weak var session: LunaCameraSession?

    /// Confirmations return as soon as a readback matches, so only failure tests pass a short
    /// settle; the long default absorbs main-thread stalls while the host app launches.
    /// `admittedSends` gives the session the backend's admitted port (`LunaCameraBackend`
    /// always supplies one), so app writes made with a `LunaCommandAdmission` reach this camera
    /// instead of failing as expired; without it the session has no admitted port.
    public func makeSession(settle: Duration = .seconds(5), admittedSends: Bool = false,
        backendCapabilities: @escaping @MainActor () -> CameraCapabilities? = { nil },
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now) -> LunaCameraSession {
        var admitted: LunaAdmittedCommandSend?
        var admittedWithin: LunaAdmittedCommandSendWithin?
        if admittedSends {
            admitted = { @MainActor [unowned self] build, admission, didDispatch in
                try await self.receive(build, admission: admission, didDispatch: didDispatch)
            }
            admittedWithin = { @MainActor [unowned self] build, admission, _, didDispatch in
                try await self.receive(build, admission: admission, didDispatch: didDispatch)
            }
        }
        let session = LunaCameraSession(
            send: { [unowned self] in try await self.receive($0) },
            functionMode: { LunaFunctionMode.normalVideo.rawValue },
            readSettings: { [unowned self] in self.reportSettings() },
            readCapture: { [unowned self] in self.reportCapture() },
            sendAdmitted: admitted, sendAdmittedWithin: admittedWithin,
            timing: .init(
                settle: [
                    .iso: settle, .shutter: settle, .whiteBalance: settle, .recording: settle,
                    .zoom: settle, .focusMode: settle,
                ],
                readbackInterval: .milliseconds(40)), backendCapabilities: backendCapabilities, now: now)
        self.session = session
        return session
    }

    /// A live session that has heard every report once.
    public func connectedSession(settle: Duration = .seconds(5), admittedSends: Bool = false,
        backendCapabilities: @escaping @MainActor () -> CameraCapabilities? = { nil },
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now) -> LunaCameraSession {
        let session = makeSession(settle: settle, admittedSends: admittedSends,
            backendCapabilities: backendCapabilities, now: now)
        session.linkChanged(.streaming, serial: "LUNA-TEST")
        reportDevice()
        reportSettings()
        reportCapture()
        return session
    }

    /// The backend's admitted send: the owner is checked and the request built at dispatch.
    private func receive(
        _ build: LunaCommandRequestBuilder, admission: LunaCommandAdmission,
        didDispatch: LunaCommandDidDispatch
    ) async throws -> Data {
        try admission.require(owner: session?.commandOwner)
        let request = try build()
        didDispatch()
        return try await receive(request)
    }

    private func receive(_ request: LunaRequest) async throws -> Data {
        sent.append(request)
        if let beforeReply { await beforeReply(request) }
        if refuses { throw FakeLunaRefusal() }
        guard !ignoresWrites else { return Data() }
        if applyDelay == .zero {
            apply(request)
        } else {
            // One control socket: the camera applies SETs in the order they arrived.
            let (delay, previous) = (applyDelay, lastApply)
            lastApply = Task { [weak self] in
                await previous?.value
                try? await Task.sleep(for: delay)
                self?.apply(request)
            }
        }
        return Data()
    }

    private func apply(_ request: LunaRequest) {
        switch request.command {
        case .setPhotographyOptions:
            let set = try! LunaPhotographySettings(response: request.body)
            if set.types.contains(21), let exposure = set.videoExposure {
                (program, iso, shutterSeconds) = (
                    exposure.program, exposure.iso, exposure.shutterSeconds
                )
            }
            if set.types.contains(39) { kelvin = set.whiteBalanceKelvin ?? 0 }
            if set.types.contains(53), let value = set.zoom { zoom = value }
            if set.types.contains(93), let value = set.afMode { afMode = value }
        case .startCapture: captureState = 1
        case .stopCapture: captureState = 0
        default: break
        }
    }

    public func reportSettings() {
        guard !silent else { return }
        var types = [21, 39, 53, 93]
        var exposure =
            try! ProtoMessage.integer(field: 1, value: program)
            + ProtoMessage.integer(field: 2, value: iso)
        if shutterSeconds > 0 {
            let reported = reportsSinglePrecisionShutter ? Double(Float(shutterSeconds)) : shutterSeconds
            exposure += try! ProtoMessage.double(field: 3, value: reported)
        }
        var nested =
            try! ProtoMessage.blob(field: 21, value: exposure)
            + ProtoMessage.integer(field: 39, value: kelvin)
            + ProtoMessage.double(field: 53, value: zoom)
            + ProtoMessage.integer(field: 93, value: afMode)
        if let colorMode {
            types.append(35)
            nested += try! ProtoMessage.integer(field: 35, value: colorMode)
        }
        let packed = types.reduce(into: Data()) { $0 += ProtoMessage.varint(UInt64($1)) }
        let body =
            try! ProtoMessage.blob(field: 1, value: packed)
            + ProtoMessage.blob(field: 2, value: nested)
            + ProtoMessage.integer(field: 3, value: UInt64(LunaFunctionMode.normalVideo.rawValue))
        session?.ingest(settings: try! LunaPhotographySettings(response: body))
    }

    public func reportCapture() {
        guard !silent, let captureState else { return }
        let body = try! ProtoMessage.blob(
            field: 1, value: try! ProtoMessage.integer(field: 1, value: captureState))
        session?.ingest(capture: try! LunaCaptureStatus(captureStatusResponse: body))
    }

    /// Video mode, no battery or storage fields.
    public func reportDevice() {
        let nested =
            try! ProtoMessage.integer(field: 40, value: 100)
            + ProtoMessage.integer(field: 41, value: 0)
        session?.ingest(
            device: try! LunaDeviceStatus(response: ProtoMessage.blob(field: 2, value: nested)))
    }
}

/// The error a refusing `FakeLuna` throws.
public struct FakeLunaRefusal: Error {}
