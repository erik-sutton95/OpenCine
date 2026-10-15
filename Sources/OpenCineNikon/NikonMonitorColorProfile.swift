import OpenCineMedia

/// Generated monitoring looks declared by the Nikon source adapter. Published decoders and
/// gamut matrices remain distinct from camera wire inference and measured clipping endpoints.
// Matrix provenance retained from the original OpenZCine generated looks:
// Nikon "N-Log Specification Document" v1.0.0 (N-Gamut is BT.2020), and RED
// "REDWideGamutRGB and Log3G10" white paper Rev B (RWG to Rec.709).
// The shared tone map supplies the anchored display transform and inverse BT.1886.
public enum NikonMonitorColorProfile {
    /// REDWideGamutRGB/Log3G10 to the existing scene-anchored Rec.709 display look.
    public static let log3G10Rec709 = MonitorLogDisplayTransform(
        decode: { Log3G10.decode($0) },
        sourceToRec709: [
            1.981880, -0.900388, -0.081540,
            -0.178143, 1.500467, -0.322325,
            -0.101811, -0.535343, 1.637304,
        ])

    /// N-Gamut (BT.2020)/N-Log to the existing scene-anchored Rec.709 display look.
    public static let nLogRec709 = MonitorLogDisplayTransform(
        decode: { NLog.decode($0) },
        sourceToRec709: [
            1.660491, -0.587641, -0.072850,
            -0.124550, 1.132900, -0.008349,
            -0.018151, -0.100579, 1.118730,
        ])

    /// Only the source's two declared log looks support a read-through-display measurement.
    public static let rec709LookCurves: [MonitorTransfer: [Double]] = [
        .log3G10: log3G10Rec709.neutralLumaCurve(),
        .nlog: nLogRec709.neutralLumaCurve(),
    ]
}
