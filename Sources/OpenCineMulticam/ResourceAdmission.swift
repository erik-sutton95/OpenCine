import Foundation
import OpenCineCore

/// A host resource a connection route needs. Integrations declare them; they know how to
/// establish and release the route. Network names and interface identities are opaque,
/// integration-chosen strings.
public enum ResourceClaim: Hashable, Codable, Sendable {
    /// The phone joins this camera's own access point. The phone has one Wi-Fi association, and
    /// the access point serves one camera.
    case cameraAccessPoint(network: String)
    /// Phone and camera share this infrastructure network (router or hotspot). Several cameras
    /// may coexist on one; the phone still joins only one.
    case infrastructureNetwork(String)
    /// Exclusive ownership of one USB interface.
    case usbInterface(String)
    /// Temporary Bluetooth commissioning or provisioning. One device at a time.
    case bluetoothCommissioning
}

/// What one entry's route needs. Entries of the same device never conflict with each other: a
/// picture entry and a control entry of one camera share its route.
public struct ResourceRequest: Hashable, Codable, Sendable {
    public var entry: MonitorEntryID
    public var device: CameraDeviceID?
    public var claims: [ResourceClaim]
    /// Estimates; zero when the route carries no picture.
    public var bitsPerSecond: Int
    public var decoders: Int

    public init(
        entry: MonitorEntryID, device: CameraDeviceID?, claims: [ResourceClaim],
        bitsPerSecond: Int = 0, decoders: Int = 0
    ) {
        self.entry = entry
        self.device = device
        self.claims = claims
        self.bitsPerSecond = bitsPerSecond
        self.decoders = decoders
    }
}

extension ResourceClaim {
    /// What a saved route claims on the phone. A hotspot is an infrastructure network named
    /// `hotspot:<network>`, so it conflicts with any other Wi-Fi. A USB or capture route claims its
    /// interface. A route that needs Bluetooth first also claims commissioning.
    public static func claims(for route: SavedRoute) -> [ResourceClaim] {
        // ponytail: an unknown network or interface is this route's own name, so it never
        // matches another route's; a known name replaces it once the route reports one.
        let name = route.network ?? "route:\(route.id)"
        var claims: [ResourceClaim] =
            switch route.kind {
            case .cameraAccessPoint: [.cameraAccessPoint(network: name)]
            case .infrastructureNetwork: [.infrastructureNetwork(name)]
            case .phoneHotspot: [.infrastructureNetwork("hotspot:" + name)]
            case .usb, .captureDevice: [.usbInterface(name)]
            }
        // ponytail: commissioning is claimed for the whole entry; split candidate and member
        // requests when a multicam app admits members that commission over Bluetooth.
        if route.bluetooth { claims.append(.bluetoothCommissioning) }
        return claims
    }
}

extension ResourceRequest {
    /// The request for one entry on a saved route: its claims, one decoder when it carries the
    /// picture, and the caller's bandwidth estimate.
    public init(
        entry: MonitorEntryID, device: CameraDeviceID?, route: SavedRoute, picture: Bool,
        bitsPerSecond: Int = 0
    ) {
        self.init(
            entry: entry, device: device, claims: ResourceClaim.claims(for: route),
            bitsPerSecond: bitsPerSecond, decoders: picture ? 1 : 0)
    }
}

/// The app's limits. `qualifiedEntries` is the tested product limit (for example four), never an
/// engine constant; `nil` means unlimited.
public struct ResourceBudget: Hashable, Codable, Sendable {
    public var qualifiedEntries: Int?
    public var bitsPerSecond: Int?
    public var decoders: Int?

    public init(qualifiedEntries: Int?, bitsPerSecond: Int? = nil, decoders: Int? = nil) {
        self.qualifiedEntries = qualifiedEntries
        self.bitsPerSecond = bitsPerSecond
        self.decoders = decoders
    }
}

public enum AdmissionReason: Hashable, Sendable {
    case qualificationUnknown
    case integrationRefused(MulticamQualificationRefusal)
    case overQualifiedLimit(Int)
    /// The candidate needs a different phone Wi-Fi network than this member.
    case wifiNetworkConflict(with: MonitorEntryID)
    /// Another device already uses this camera access point.
    case accessPointTaken(by: MonitorEntryID)
    case usbInterfaceTaken(by: MonitorEntryID)
    case commissioningInProgress(by: MonitorEntryID)
    case bandwidthExceeded(needed: Int, limit: Int)
    case decodersExceeded(needed: Int, limit: Int)
}

/// Feasibility of adding one route next to the current members, checked before any disruptive
/// transition (joining a network, claiming USB). It describes; it never provisions or releases.
public enum ResourceAdmission {
    /// Combines the integration's configuration qualification with the app's resource budget.
    /// Unknown qualification blocks admission; this never infers camera observations or sends
    /// a command. The resource-only overload remains useful for single connection feasibility.
    public static func reasons(
        admitting candidate: ResourceRequest, qualification: MulticamQualification,
        alongside members: [ResourceRequest], budget: ResourceBudget
    ) -> [AdmissionReason] {
        let qualificationReasons: [AdmissionReason] =
            switch qualification {
            case .qualified: []
            case .unknown: [.qualificationUnknown]
            case .refused(let reason): [.integrationRefused(reason)]
            }
        return qualificationReasons
            + reasons(admitting: candidate, alongside: members, budget: budget)
    }

    /// Empty when the candidate may join.
    public static func reasons(
        admitting candidate: ResourceRequest, alongside members: [ResourceRequest],
        budget: ResourceBudget
    ) -> [AdmissionReason] {
        var reasons: [AdmissionReason] = []
        let others = members.filter { $0.entry != candidate.entry }
        if let limit = budget.qualifiedEntries, others.count + 1 > limit {
            reasons.append(.overQualifiedLimit(limit))
        }
        for member in others {
            let sameDevice = candidate.device != nil && member.device == candidate.device
            for mine in candidate.claims {
                for theirs in member.claims {
                    if let reason = conflict(mine, theirs, member.entry, sameDevice: sameDevice),
                        !reasons.contains(reason)
                    {
                        reasons.append(reason)
                    }
                }
            }
        }
        let bits = (others + [candidate]).map(\.bitsPerSecond).reduce(0, +)
        if let limit = budget.bitsPerSecond, bits > limit {
            reasons.append(.bandwidthExceeded(needed: bits, limit: limit))
        }
        let decoders = (others + [candidate]).map(\.decoders).reduce(0, +)
        if let limit = budget.decoders, decoders > limit {
            reasons.append(.decodersExceeded(needed: decoders, limit: limit))
        }
        return reasons
    }

    private static func conflict(
        _ mine: ResourceClaim, _ theirs: ResourceClaim, _ member: MonitorEntryID, sameDevice: Bool
    ) -> AdmissionReason? {
        switch (mine, theirs) {
        case (.cameraAccessPoint(let a), .cameraAccessPoint(let b)):
            if a != b { return .wifiNetworkConflict(with: member) }
            return sameDevice ? nil : .accessPointTaken(by: member)
        case (.cameraAccessPoint(let a), .infrastructureNetwork(let b)),
            (.infrastructureNetwork(let a), .cameraAccessPoint(let b)),
            (.infrastructureNetwork(let a), .infrastructureNetwork(let b)):
            return a == b ? nil : .wifiNetworkConflict(with: member)
        case (.usbInterface(let a), .usbInterface(let b)):
            return a == b && !sameDevice ? .usbInterfaceTaken(by: member) : nil
        case (.bluetoothCommissioning, .bluetoothCommissioning):
            return sameDevice ? nil : .commissioningInProgress(by: member)
        default:
            return nil
        }
    }
}
