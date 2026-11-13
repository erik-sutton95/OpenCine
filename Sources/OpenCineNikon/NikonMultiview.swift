import Foundation
import OpenCineCore
import OpenCineMedia

// Shared Multiview prep (roadmap Plan 6): what a Pocket-standard Multiview needs from the Nikon
// integration, as plain values and closures. Plan 6 wraps them in the app shell's Multiview seams;
// nothing here names that shell. Kotlin twins: `NikonMultiview.kt`, same names.

/// Timing a Multiview member link keeps (Kotlin `NikonMemberTiming`).
public enum NikonMemberTiming {
    /// After a link to a host closes (CloseSession, a dropped socket or a failed dial), the next Init
    /// to that host waits this long: the ZR can hold the PTP slot briefly after a close, and an Init
    /// inside that window tips a reconnect into a wedge (OpenZCine's reconnect settle, 1200 ms).
    public static let reconnectSettle: Duration = .milliseconds(1_200)
    /// The least time between two automatic reopen attempts of one member after a failed reopen: the
    /// Android saved-profile busy handoff's settle, the gentlest re-Init cadence the integration uses.
    public static let reopenSpacing: Duration = .seconds(5)
}

/// Why `NikonMemberOpener` did not hand back a link.
public enum NikonMemberOpenRefusal: Hashable, Sendable {
    /// A Multiview member or this app's Live View holds the host: it was not dialled.
    case hostInUse
    /// The body (by serial) is already in the group, under whatever host: closed.
    case alreadyMember
    /// The host answered with another body than the one picked: closed.
    case differentBody
    /// The body reported no serial, so the group cannot tell it from a member: closed.
    case noIdentity
}

public enum NikonMemberOpenResult<Link: Sendable>: Sendable {
    /// An open link to the picked body, and its member identity (the serial from GetDeviceInfo).
    case opened(Link, device: CameraDeviceID)
    case refused(NikonMemberOpenRefusal)

    public var link: Link? {
        if case .opened(let link, _) = self { return link }
        return nil
    }

    public var device: CameraDeviceID? {
        if case .opened(_, let device) = self { return device }
        return nil
    }

    public var refusal: NikonMemberOpenRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// Opens the one body the operator picked from Multiview's Add camera, or the member a repair
/// reopens, and checks who it is (Kotlin `NikonMemberOpener`). It dials nothing else: never a host
/// in use, and never a host it was not asked to open. The link type and its open, serial and close
/// are the platform's (iOS `NativeCameraSession`; Android the Swift session behind `NikonNative`).
///
/// Every close or failed dial of a host starts that host's `NikonMemberTiming.reconnectSettle`; an
/// open inside it waits out the rest before its Init.
public final class NikonMemberOpener<Link: Sendable>: @unchecked Sendable {
    // SAFETY: `@unchecked Sendable`: the only mutable state is `released`, guarded by `lock`.
    private let settle: Duration
    private let now: @Sendable () -> MonotonicInstant
    private let sleep: @Sendable (Duration) async throws -> Void
    private let connect: @Sendable (String) async throws -> Link
    private let serialNumber: @Sendable (Link) -> String?
    private let closeLink: @Sendable (Link) async -> Void
    private let lock = NSLock()
    private var released: [String: MonotonicInstant] = [:]

    /// - `connect`: opens a PTP session to the host (Init, OpenSession, GetDeviceInfo).
    /// - `serialNumber`: the serial the link's GetDeviceInfo reported.
    /// - `close`: a graceful CloseSession, then the sockets. Never a record command.
    public init(
        settle: Duration = NikonMemberTiming.reconnectSettle,
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        connect: @escaping @Sendable (String) async throws -> Link,
        serialNumber: @escaping @Sendable (Link) -> String?,
        close: @escaping @Sendable (Link) async -> Void
    ) {
        self.settle = settle
        self.now = now
        self.sleep = sleep
        self.connect = connect
        self.serialNumber = serialNumber
        closeLink = close
    }

    /// Opens `host` and checks the body: refused (and closed) when it is already in the group
    /// (`members`), is not the `expectedSerial` body, or reports no serial. A host in `hostsInUse` is
    /// refused without a dial. A failed dial throws.
    public func open(
        host: String, expectedSerial: String? = nil, members: Set<CameraDeviceID>,
        hostsInUse: Set<String>
    ) async throws -> NikonMemberOpenResult<Link> {
        let key = NikonDiscovery.hostKey(host)
        guard !hostsInUse.contains(where: { NikonDiscovery.hostKey($0) == key }) else {
            return .refused(.hostInUse)
        }
        if let releasedAt = lock.withLock({ released[key] }) {
            let wait = settle - (now() - releasedAt)
            if wait > .zero { try await sleep(wait) }
        }
        let link: Link
        do {
            link = try await connect(host)
        } catch {
            markReleased(key)
            throw error
        }
        guard let device = NikonMulticamPolicy.device(serialNumber: serialNumber(link)) else {
            await close(link, host: host)
            return .refused(.noIdentity)
        }
        if members.contains(device) {
            await close(link, host: host)
            return .refused(.alreadyMember)
        }
        if let expected = NikonMulticamPolicy.device(serialNumber: expectedSerial), expected != device {
            await close(link, host: host)
            return .refused(.differentBody)
        }
        return .opened(link, device: device)
    }

    /// Closes a link this opener handed out (or any link to `host`) and starts the host's settle.
    public func close(_ link: Link, host: String) async {
        await closeLink(link)
        markReleased(NikonDiscovery.hostKey(host))
    }

    private func markReleased(_ key: String) {
        let time = now()
        lock.withLock { released[key] = time }
    }
}

/// A member's recording tone for Multiview's Auto LUT (Kotlin `CameraPropertySnapshot.recordingTone`):
/// the active codec (`MovFileType`) and the per-codec tone properties, as read. Unknown is `nil`,
/// never SDR: a tone property alone does not say which codec records.
public struct NikonRecordingTone: Hashable, Sendable {
    /// The packed `MovFileType` the body last reported; `nil` until read or after a malformed read.
    public private(set) var fileType: UInt32?
    /// The tone each per-codec tone property last reported; an unnamed or malformed value is absent.
    public private(set) var tones: [PTPPropertyCode: NikonMovieTone] = [:]

    public init() {}

    /// Applies one property read; properties other than the codec and its tone properties are ignored.
    public mutating func apply(_ property: PTPPropertyCode, data: Data) {
        if property == .movieFileType {
            fileType = data.count >= 4 ? ByteCoding.readUInt32LE([UInt8](data), at: 0) : nil
        } else if NikonMovieToneCapability.toneProperties.contains(property) {
            tones[property] = NikonMovieToneCapability.tone(readback: [UInt8](data))
        }
    }

    /// The tone the active codec records: its fixed tone, or its tone property's value.
    public var tone: NikonMovieTone? {
        guard let fileType else { return nil }
        if let fixed = NikonMovieToneCapability.fixedTone(forFileType: fileType) { return fixed }
        guard let property = NikonMovieToneCapability.toneProperty(forFileType: fileType) else { return nil }
        return tones[property]
    }

    /// `tone` as the neutral transfer a Multiview tile's Auto LUT reads.
    public var transfer: MonitorTransfer? { tone?.monitorTransfer }

    /// The tone property the next poll reads after the codec, or `nil` when the codec has none.
    var toneProperty: PTPPropertyCode? {
        fileType.flatMap(NikonMovieToneCapability.toneProperty(forFileType:))
    }
}
