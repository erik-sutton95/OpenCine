/// The Nikon picker ladders every shell draws when the body has not advertised its own enum.
///
/// Twin of `ShutterPickerPolicy`, `FocusPickerPolicy` and `StillPickerLadders` in
/// `Android/nikon`. Both suites read `Fixtures/nikon-picker-ladders.tsv`, so a ladder edited on one
/// side and not the other fails a test instead of drifting.

/// Movie SHUTTER drums: the Angle and Speed circuits.
public enum ShutterPickerPolicy: Sendable {
    public static let angleOptions: [String] = [
        "5.6°", "11.2°", "22.5°", "45°", "72°", "86.4°", "90°", "108°", "144°", "172°", "180°",
        "216°", "288°", "346°", "360°",
    ]

    public static let speedOptions: [String] = [
        "1/6", "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30", "1/40", "1/50", "1/60",
        "1/80", "1/100", "1/125", "1/160", "1/200", "1/250", "1/320", "1/400", "1/500", "1/640",
        "1/800", "1/1000", "1/1250", "1/1600", "1/2000", "1/2500", "1/3200", "1/4000", "1/5000",
        "1/6400", "1/8000", "1/10000", "1/13000", "1/16000",
    ]

    public static let angleBase = "180°"
    public static let speedBase = "1/50"
}

/// Movie FOCUS drums: AF mode, AF area and subject detection. Labels match the
/// `PTPCameraPropertyDecoders` movie AF tables so they round-trip with the body.
public enum FocusPickerPolicy: Sendable {
    public static let afModeOptions: [String] = ["MF", "AF-S", "AF-C", "AF-F"]

    /// `Subject tracking` is the AF-area mode, spelled the way the body spells it in video; it is
    /// a different setting from the subject-detection drum (#274).
    public static let areaOptions: [String] = [
        "Single", "Wide-S", "Wide-L", "Auto", "Subject tracking",
    ]

    public static let subjectOptions: [String] = [
        "Auto", "People", "Animal", "Bird", "Vehicle", "Airplane",
    ]

    public static let afModeBase = "AF-F"
    public static let areaBase = "Single"
    public static let subjectBase = "Auto"
}

/// Stills picker ladders.
public enum StillPickerLadders: Sendable {
    public static let isoOptions: [String] = [
        "100", "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000", "1250",
        "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000", "10000", "12800", "16000",
        "20000", "25600", "32000", "40000", "51200",
    ]

    public static let shutterOptions: [String] = [
        "30s", "15s", "8s", "4s", "2s", "1s", "1/2", "1/4", "1/8", "1/15", "1/30", "1/60", "1/125",
        "1/200", "1/250", "1/500", "1/1000", "1/2000", "1/4000", "1/8000", "Bulb",
    ]

    /// One decimal place throughout, matching the `irisFNumber` readout.
    public static let irisOptions: [String] = [
        "f/1.2", "f/1.4", "f/1.8", "f/2.0", "f/2.2", "f/2.5", "f/2.8", "f/3.2", "f/3.5", "f/4.0",
        "f/4.5", "f/5.0", "f/5.6", "f/6.3", "f/7.1", "f/8.0", "f/9.0", "f/10.0", "f/11.0",
        "f/13.0", "f/14.0", "f/16.0", "f/18.0", "f/20.0", "f/22.0",
    ]

    /// The release order minus the dial-only Quick position and the body's Self-timer (the
    /// Built-in Timer tab owns that one).
    public static let driveOptions: [String] = StillDriveMode.allCases
        .filter { $0 != .quickSetting && $0 != .selfTimer }
        .map(\.label)

    public static let appTimerOptions: [String] = [
        "Off", "1s", "2s", "3s", "5s", "10s", "20s", "30s", "60s",
    ]

    public static let focusModeOptions: [String] = ["AF-S", "AF-C", "AF-A", "MF"]

    /// `3D tracking` is the AF-area mode, not the subject-detection tab (#274).
    public static let focusAreaOptions: [String] = [
        "Pinpoint", "Single", "Dyn-S", "Dyn-M", "Dyn-L", "Wide-S", "Wide-L", "3D tracking", "Auto",
    ]

    public static let focusSubjectOptions: [String] = [
        "Off", "Auto", "People", "Animal", "Vehicle", "Bird", "Airplane",
    ]

    /// No user banks: a body that has them advertises them (#274).
    public static let modeOptions: [String] = PTPCameraPropertyDecoders
        .exposureProgramFallbackOptions

    public static let userModeOptions: [String] = ["P", "S", "A", "M"]

    public static let meterOptions: [String] = ["Matrix", "Center", "Spot", "Highlight"]

    public static let pictureOptions: [String] =
        [
            "Auto", "Standard", "Neutral", "Vivid", "Monochrome", "Portrait", "Landscape", "Flat",
            "Flat Mono", "Deep Tone Mono", "Rich Tone Portrait", "Dream", "Morning", "Pop",
            "Sunday",
            "Somber", "Drama", "Silence", "Bleach", "Melancholic", "Pure", "Denim", "Toy", "Sepia",
            "Blue", "Red", "Pink", "Charcoal", "Graphite", "Binary", "Carbon",
        ] + (1...9).map { "Custom \($0)" } + (1...9).map { "Cloud \($0)" }

    public static let areaOptions: [String] = StillImageArea.allCases.map(\.label)

    public static let sizeOptions: [String] = ["Size L", "Size M", "Size S"]

    /// The `CompressionSetting` ladder minus the ★ size-priority variants and TIFF.
    public static let qualityOptions: [String] = [
        "RAW", "RAW+JPEG Fine", "RAW+JPEG Normal", "RAW+JPEG Basic", "JPEG Fine", "JPEG Normal",
        "JPEG Basic",
    ]

    public static let nefOptions: [String] = [
        "High efficiency", "High efficiency★", "Lossless compression",
    ]
}
