import Foundation

/// A Luna body this integration supports (Kotlin twin `LunaModel`, same members): the model
/// string it reports in device-information option 48, its name for the operator and what its
/// lenses can do. Insta360's Bluetooth service BE80 is shared by more of its cameras, so only a
/// body listed in `supported` gets the Luna profile.
///
/// Sources: Luna Ultra is hardware-qualified (owner, firmware 1.1.15 to 1.2.7). Luna Pro is
/// untested: its model string and lens figures come from Insta360's public Luna Pro manual
/// ("Insta360 Luna Pro"; one 1-inch main camera, no telephoto; common focal lengths 1x, 2x and
/// 4x, 4x maximum) and the luna_ultra-vs-luna_pro compare page, not from a camera.
public struct LunaModel: Hashable, Sendable {
    /// What the camera reports in option 48, for example "Insta360 Luna Ultra".
    public let reportedName: String
    /// The operator's name for the body, for example "Luna Ultra".
    public let name: String
    /// A separate telephoto camera (Ultra's 3x). Without one, every factor past 1x is a crop of
    /// the main camera, so the monitor shows no tele stop or "TELE" caption.
    public let hasTelephoto: Bool
    /// The highest zoom factor the body takes.
    public let maximumZoom: Double
    /// The zoom presets the official app offers, ascending, 1x first.
    public let zoomPresets: [Double]
    /// The factors a lens gives without a crop: 1x, and 3x on a body with a telephoto.
    public var opticalZoomStops: [Double] { hasTelephoto ? [1, 3] : [1] }
    /// Whether the body has been tried on hardware with this integration.
    public let hardwareQualified: Bool

    public init(
        reportedName: String, name: String, hasTelephoto: Bool, maximumZoom: Double,
        zoomPresets: [Double], hardwareQualified: Bool
    ) {
        self.reportedName = reportedName
        self.name = name
        self.hasTelephoto = hasTelephoto
        self.maximumZoom = maximumZoom
        self.zoomPresets = zoomPresets
        self.hardwareQualified = hardwareQualified
    }

    /// Main camera and 3x telephoto; presets as the official app offered them on fw 1.1.15.
    public static let ultra = LunaModel(
        reportedName: "Insta360 Luna Ultra", name: "Luna Ultra", hasTelephoto: true, maximumZoom: 15,
        zoomPresets: [1, 2, 3, 6, 15], hardwareQualified: true)
    /// The Ultra's main camera without the telephoto. Untested: no Luna Pro has connected yet.
    public static let pro = LunaModel(
        reportedName: "Insta360 Luna Pro", name: "Luna Pro", hasTelephoto: false, maximumZoom: 4,
        zoomPresets: [1, 2, 4], hardwareQualified: false)

    /// Every body the integration connects to.
    public static let supported: [LunaModel] = [.ultra, .pro]

    /// The name for a Luna whose body is not known yet: a Bluetooth sighting carries no model.
    public static let familyName = "Luna"
    /// `familyName` as a camera reports it.
    public static let familyReportedName = "Insta360 Luna"

    /// The supported body that reported `reported`. The known names are compared without case,
    /// surrounding or repeated spaces and the "Insta360" prefix, so "Insta360 Luna Pro" and
    /// "Luna Pro" are the Pro. `nil` for any other camera, including a Luna variant not listed in
    /// `supported`: its wire behaviour is unverified, so it is refused rather than guessed.
    public static func identify(_ reported: String) -> LunaModel? {
        let key = comparable(reported)
        guard !key.isEmpty else { return nil }
        return supported.first { comparable($0.reportedName) == key }
    }

    /// Whether `reported` names a Luna at all ("Insta360 Luna ..."), supported or not.
    public static func isLunaFamily(_ reported: String) -> Bool {
        let key = comparable(reported)
        return key == "luna" || key.hasPrefix("luna ")
    }

    /// "Insta360 Luna Ultra and Luna Pro": the supported bodies for operator copy.
    public static var supportedNames: String {
        let names = supported.map(\.name)
        let list =
            names.count < 2
            ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "Insta360 \(list)"
    }

    /// The operator copy for a camera the gate refused: which camera it is and what `appName`
    /// supports. An unknown Luna variant is named as one, so its owner can report the model.
    public static func unsupportedMessage(reported: String, appName: String) -> String {
        let model = reported.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let supports = "\(appName) currently supports the \(supportedNames)."
        if model.isEmpty { return "This camera did not report its model. \(supports)" }
        if isLunaFamily(model) { return "This camera is \(model), a Luna model \(appName) does not support yet. \(supports)" }
        return "This camera is \(model). \(supports)"
    }

    private static func comparable(_ value: String) -> String {
        var words = value.lowercased().split(whereSeparator: \.isWhitespace)
        if words.first == "insta360" { words.removeFirst() }
        return words.joined(separator: " ")
    }
}

extension LunaDeviceInformation {
    /// The supported body this camera reported; `nil` for any other.
    public var lunaModel: LunaModel? { LunaModel.identify(model) }
}
