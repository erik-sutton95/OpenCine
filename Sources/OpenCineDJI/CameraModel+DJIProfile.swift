import Foundation

// Manufacturer catalogue resolution belongs to this integration.
extension CameraModel {
    /// Legacy DJI catalogue construction supplies facts before shared capability admission.
    public init(name: String) {
        self = Self.describedModel(name: name)
    }

    public var isAction6: Bool { name.lowercased().replacingOccurrences(of: " ", with: "").contains("action6") }
    public var usesNanoLiveViewGate: Bool { family == .nano }
    public var isPocket3: Bool {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        return n.contains("pocket3") || n.contains("muse")
    }
    public var isPocket4Pro: Bool {
        name.lowercased().replacingOccurrences(of: " ", with: "").contains("pocket4p")
    }

    public static let `default` = describedModel(name: "DJI Osmo camera")

    package static let byId: [Int: CameraModel] = [
        0x0010: describedModel(name: "Osmo Action 2"),
        0x0012: describedModel(name: "Osmo Action 3"),
        0x0014: describedModel(name: "Osmo Action 4"),
        0x0015: describedModel(name: "Osmo Action 5 Pro", verified: true),
        0x0017: describedModel(name: "Osmo 360", wpa3: true),
        0x0018: describedModel(name: "Osmo Action 6", verified: true),
        0x0019: describedModel(name: "Osmo Nano", verified: true),
        0x0020: describedModel(name: "Osmo Pocket 3", verified: true),
        0x0021: describedModel(name: "Osmo Pocket 4", verified: true),
        0x0022: describedModel(name: "Osmo Pocket 4 Pro", verified: true),
        0x0070: describedModel(
            name: "Mavic 3", datalinkPort: 9003, tcpPoke: false, verified: true, isDrone: true),
        0x007E: describedModel(name: "DJI Neo 2", datalinkPort: 9003, tcpPoke: false, isDrone: true),
    ]

    /// Xtra's shell-company product names for the DJI models they rebadge, keyed by the shared
    /// DJI BLE model id — an Xtra advertises the *same* id as the DJI original.
    static let xtraNames: [Int: String] = [
        0x0019: "Xtra Atto",  // rebadged Osmo Nano
        0x0014: "Xtra Edge",  // rebadged Osmo Action 4
        0x0015: "Xtra Edge Pro",  // rebadged Osmo Action 5 Pro — the only verified Xtra
        0x0020: "Xtra Muse",  // rebadged Osmo Pocket 3
    ]

    /// Resolve by BLE model id, then by local name (the Pocket 3 sends no manufacturer data, so it
    /// only resolves by name). Unknown ids at/above 0x40 are treated as drones.
    ///
    /// `brand` matters because the whole Xtra line runs a **10004 / no-poke** datalink instead of
    /// the DJI-standard 9004 + TCP-7001 poke — a rebrand firmware change, not a model difference.
    /// The Edge Pro advertises the same model id `0x0015` as a genuine Action 5 Pro yet speaks
    /// 10004, so the id alone cannot tell them apart; the hardware OUI can. Ported from Osmosis
    /// `ble/CameraModel.kt`, where the Edge Pro is hardware-verified.
    public static func resolve(
        modelId: Int?, name: String?, brand: CameraBrand = .unknown
    ) -> CameraModel {
        let base = resolveIgnoringBrand(modelId: modelId, name: name)
        guard brand == .xtra else { return base }
        let isEdgePro = modelId == 0x0015 || base.name.contains("Action 5")
        let xtraName =
            modelId.flatMap { xtraNames[$0] }
            ?? (isEdgePro ? "Xtra Edge Pro" : "Xtra \(base.name)")
        return describedModel(
            name: xtraName, datalinkPort: 10004, tcpPoke: false,
            wpa3: base.wpa3, verified: isEdgePro, isDrone: base.isDrone)
    }

    private static func resolveIgnoringBrand(modelId: Int?, name: String?) -> CameraModel {
        if let id = modelId, let m = byId[id] { return m }
        if let id = modelId, id >= 0x40 {
            return describedModel(
                name: name.map { "DJI drone (\($0))" } ?? "DJI drone",
                datalinkPort: 9003, tcpPoke: false, isDrone: true)
        }
        let n = (name ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        // "pocket4p" before "pocket4": the Pro's BLE name is OsmoPocket4P-XXXX.
        switch true {
        case n.contains("pocket3"), n.contains("muse"): return byId[0x0020]!
        case n.contains("pocket4p"): return byId[0x0022]!
        case n.contains("pocket4"): return byId[0x0021]!
        case n.contains("360"): return byId[0x0017]!
        case n.contains("nano"), n.contains("atto"): return byId[0x0019]!
        case n.contains("action6"): return byId[0x0018]!
        case n.contains("action5"), n.contains("edgepro"): return byId[0x0015]!
        case n.contains("action4"), n.contains("edge"): return byId[0x0014]!
        default:
            return describedModel(name: name?.isEmpty == false ? name! : CameraModel.default.name)
        }
    }

    private static func describedModel(
        name: String, datalinkPort: Int = 9004, tcpPoke: Bool = true,
        wpa3: Bool = false, verified: Bool = false, isDrone: Bool = false
    ) -> CameraModel {
        var model = CameraModel(name: name, datalinkPort: datalinkPort, tcpPoke: tcpPoke,
            wpa3: wpa3, verified: verified, isDrone: isDrone,
            family: CameraBodyFamily.resolve(modelId: nil, name: name))
        model.captureProfile = DJICaptureCapabilityProfile.make(for: model)
        return model
    }
}

extension CameraBodyFamily {
    public static func resolve(modelId: Int?, name: String?) -> CameraBodyFamily {
        if let id = modelId {
            switch id {
            case 0x0020, 0x0021, 0x0022: return .pocket
            case 0x0019: return .nano
            default: break
            }
        }
        let n = (name ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if n.contains("pocket") || n.contains("muse") { return .pocket }
        if n.contains("nano") || n.contains("atto") { return .nano }
        return .other
    }
}

public enum CameraBrand: Equatable, Sendable {
    case dji
    case xtra
    case unknown

    public static let xtraOUI = "EC:9E:EA"

    /// `djiCid` = the advert carried a DJI BLE company id. That is the definitive DJI tell, but it
    /// is checked *after* the Xtra branches: an Xtra broadcasts DJI's company id too, and its own
    /// OUI has to win or it would be handed the 9004 config it cannot answer.
    public static func of(address: String?, name: String?, djiCid: Bool = false) -> CameraBrand {
        let oui = (address ?? "").uppercased().prefix(8)
        let n = (name ?? "").lowercased()
        if oui == xtraOUI { return .xtra }
        if n.contains("xtra") || n.contains("edge") { return .xtra }
        if djiCid { return .dji }
        for tell in ["osmo", "nano", "dji", "pocket", "action"] where n.contains(tell) {
            return .dji
        }
        return .unknown
    }
}
