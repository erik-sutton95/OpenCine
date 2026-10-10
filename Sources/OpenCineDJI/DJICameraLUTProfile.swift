import Foundation

/// The integration owns body-specific official cube choice, including Action 6's own file.
public enum DJICameraLUTProfile {
    public static func make(for model: CameraModel) -> CameraLUTProfile {
        make(family: model.family, cameraName: model.name)
    }

    public static func make(family: CameraBodyFamily, cameraName: String?) -> CameraLUTProfile {
        let automatic = Dictionary(uniqueKeysWithValues: ColorMode.allCases.compactMap { color in
            OfficialDJILUT.auto(colorMode: color, family: family, cameraName: cameraName)
                .map { (color, LUTSource.dji($0)) }
        })
        return CameraLUTProfile(automatic: automatic,
            selections: [.djiDLogM: .dji(OfficialDJILUT.dLogM(cameraName: cameraName))])
    }
}

extension OfficialDJILUT {
    /// Shared D-Log M cube unless this body has its own official file.
    public static func dLogM(cameraName: String?) -> OfficialDJILUT {
        let n = (cameraName ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if n.contains("action6") { return .action6DLogM }
        return .nanoDLogM
    }

    /// Official look for this body + color. Rec.709 / HDR have none.
    public static func auto(
        colorMode: ColorMode?,
        family: CameraBodyFamily,
        cameraName: String? = nil
    ) -> OfficialDJILUT? {
        switch colorMode {
        case .dLog2:
            return family == .nano ? dLogM(cameraName: cameraName) : .pocketDLog2
        case .dLog:
            return family == .nano ? dLogM(cameraName: cameraName) : .pocketDLog
        case .dLogM:
            return dLogM(cameraName: cameraName)
        default:
            return nil
        }
    }
}
