import OpenCineCameraVocabulary
import OpenCineCore

/// A write a Nikon ladder tab asks for. The value key is the tab's mode index; circuit switches
/// are separate so selecting a tab can change the circuit without pretending a drum value moved.
public enum NikonLadderControl: Hashable, Sendable {
    case value(Int)
    case baseISO
    case autoISO
    case stillAutoISO
    case shutterMode
    case tint
}

/// How a Nikon capture popup's tabs behave. Each case is one property family on the body.
public enum NikonCapturePopupKind: Equatable, Sendable {
    /// Movie ISO: R3D NE's Low and High base circuits, or Auto ISO Off and On.
    case iso
    /// Photo ISO: Auto (the body owns the value) and Manual.
    case stillISO
    /// Shutter angle and speed circuits. Choosing a circuit writes only the circuit.
    case shutter
    /// White balance: Kelvin, the body's presets, and the two-axis fine-tune pad.
    case whiteBalance
    /// Recording codec, with the bit depths the body offers beside the selected codec.
    case codec
    /// F-numbers the mounted lens reaches.
    case aperture
    /// Release mode tab plus the two timer tabs; each tab is its own setting.
    case drive
    /// Each tab is an independent setting (focus mode, area, subject; audio; photo size).
    case independentTabs
    /// One setting; choosing a tab writes the value it lands on.
    case settings
}

/// One tab as the body and the app's ladder table describe it.
public struct NikonLadderMode: Sendable {
    /// The tab's mode index, the key its writes carry.
    public let index: Int
    public let title: String
    public let detail: String?
    /// The app's ladder for the tab, used when the body advertises none.
    public let options: [String]
    /// The value the drum marks (a native base); empty for none.
    public let base: String
    /// The body's current value on this tab; empty while unknown.
    public let current: String
    /// The body refuses this tab now.
    public let disabled: Bool
    /// The values the body advertises for this tab, in body order; nil or empty for none.
    public let advertised: [String]?

    public init(
        index: Int, title: String, detail: String? = nil, options: [String], base: String = "",
        current: String, disabled: Bool = false, advertised: [String]? = nil
    ) {
        self.index = index
        self.title = title
        self.detail = detail
        self.options = options
        self.base = base
        self.current = current
        self.disabled = disabled
        self.advertised = advertised
    }
}

/// Everything one Nikon capture popup shows, as values read from the session. `presentation`
/// turns it into the shared ladder sheet every app draws inside the common capture drawer.
public struct NikonCapturePopupState: Sendable {
    public var kind: NikonCapturePopupKind
    public var title: String
    public var subtitle: String
    public var modes: [NikonLadderMode]
    /// The body's camera value for the picker, which picks the opening tab of a plain setting.
    public var cameraValue: String = ""
    /// A tab position the opener asked for (a command tile); nil opens on the body's value.
    public var seededTab: Int?
    /// The body's active circuit (ISO base or Auto, shutter mode, photo Auto ISO).
    public var circuitIndex: Int?
    public var codec: String = ""
    public var photography = false
    /// The body's white balance mode label; it picks the Kelvin or Preset tab.
    public var whiteBalanceMode: String?
    public var liveISO: Int?
    public var dualBaseISO = false
    public var autoISO = false
    public var isoCameraOwned = false
    public var isoRecordingLocked = false
    public var allowsManualISO = true
    public var stillAllowsManualISO = true
    public var shutterLockedOnCamera = false
    /// The fine-tune grid position, and whether the current mode has a tune property.
    public var tintCells: (amberBlue: Int, greenMagenta: Int) = (0, 0)
    public var tintAvailable = false
    public var lensApertures: [String] = []
    public var codecRows: [PTPCameraCodecFamily] = []
    public var activeCodecDepth: Int?
    /// The common setting a typed drum edits; nil keeps label drums (demo, relay, untyped).
    public var typed: NikonControlSetting?

    public init(
        kind: NikonCapturePopupKind, title: String, subtitle: String, modes: [NikonLadderMode]
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.modes = modes
    }
}

extension NikonCapturePopupState {
    static let kelvinTab = "Kelvin"
    static let tintTab = "Tint"
    static let presetTab = "Preset"

    /// The popup as the shared ladder sheet draws it.
    public var presentation: LadderSheetPresentation<NikonLadderControl> {
        LadderSheetPresentation(
            title: title, subtitle: subtitle, tabs: displayModes.map(tab), initialTab: initialTab,
            lock: sheetLock, lockBanner: banner)
    }

    /// The tabs in the order every app shows them (Pocket's): white balance Mode, Kelvin, Tint and
    /// shutter Speed, Angle. Each tab keeps the body's mode index as its key, so only the display
    /// order differs from the camera's mode numbering, and nothing stores a display position.
    var displayModes: [NikonLadderMode] {
        let order: [String]
        switch kind {
        case .whiteBalance: order = [Self.presetTab, Self.kelvinTab, Self.tintTab]
        case .shutter: order = ["Speed", "Angle"]
        default: return modes
        }
        let rank = { (mode: NikonLadderMode) in order.firstIndex(of: mode.title) ?? order.count }
        return modes.enumerated().sorted {
            (rank($0.element), $0.offset) < (rank($1.element), $1.offset)
        }
        .map(\.element)
    }

    /// The tab label every app shows: the white balance presets tab is "Mode", as on Pocket.
    func label(_ mode: NikonLadderMode) -> String {
        kind == .whiteBalance && mode.title == Self.presetTab ? "Mode" : mode.title
    }

    /// The opening tab as a display position: chosen in the camera's mode order, then found in
    /// `displayModes` by mode index.
    var initialTab: Int {
        let raw: Int
        switch kind {
        case .iso, .shutter, .stillISO:
            raw = circuitIndex ?? 0
        case .whiteBalance:
            let mode = whiteBalanceMode
            raw =
                modes.firstIndex {
                    $0.title
                        == (mode == nil || mode == "Color temp" ? Self.kelvinTab : Self.presetTab)
                } ?? 0
        default:
            raw = seededTab ?? modes.firstIndex { optionsOf($0).contains(cameraValue) } ?? 0
        }
        guard !modes.isEmpty else { return 0 }
        let chosen = modes[min(max(raw, 0), modes.count - 1)].index
        return displayModes.firstIndex { $0.index == chosen } ?? 0
    }

    /// Recording and a camera shutter lock freeze the whole sheet. Auto ISO locks each drum
    /// instead, so the operator can still leave Auto.
    var sheetLock: CaptureLock? {
        if kind == .shutter, shutterLockedOnCamera { return .cameraControl }
        if kind == .iso, isoRecordingLocked { return .recording }
        return nil
    }

    var banner: String? {
        switch sheetLock {
        case .cameraControl: return "Shutter locked on camera. Hold anywhere to unlock."
        case .recording: return "ISO is locked while recording in R3D NE"
        default: break
        }
        if kind == .stillISO {
            return stillAllowsManualISO
                ? "Auto ISO is on. The camera sets sensitivity. Switch to Manual to choose a value."
                : "Manual ISO needs P, S, A, M or a U bank. The camera is setting sensitivity."
        }
        guard kind == .iso, autoISO, isoCameraOwned else { return nil }
        return allowsManualISO
            ? "Auto ISO is on. The camera sets sensitivity. Switch to Auto Off to choose a value."
            : "Manual ISO needs exposure mode M. The camera is setting sensitivity."
    }

    func tab(_ mode: NikonLadderMode) -> LadderTab<NikonLadderControl> {
        let options = optionsOf(mode)
        let lock = tabLock(mode)
        let kelvin = kind == .whiteBalance && mode.title == Self.kelvinTab
        let (activate, apply) = activation(mode)
        let grown: (@Sendable (String) -> [String])? = kelvin ? Self.kelvinValues : nil
        return LadderTab(
            label: label(mode), key: .value(mode.index),
            ladder: CaptureLadder(
                current: mode.current.isEmpty ? nil : mode.current, values: options,
                marked: marked(mode), lock: lock),
            detail: mode.detail, activate: activate, applyOnActivate: apply,
            disabled: mode.disabled, setting: setting(mode, options: options, lock: lock),
            tint: kind == .whiteBalance && mode.title == Self.tintTab
                ? CaptureTint(
                    greenMagenta: tintCells.greenMagenta, amberBlue: tintCells.amberBlue,
                    range: WhiteBalanceTint.cellRange) : nil,
            values: grown,
            steps: steps(kelvin: kelvin), stepsHint: stepsHint(kelvin: kelvin))
    }

    func tabLock(_ mode: NikonLadderMode) -> CaptureLock? {
        if kind == .whiteBalance, mode.title == Self.tintTab, !tintAvailable { return .auto }
        if kind == .iso, autoISO, isoCameraOwned, !isoRecordingLocked { return .auto }
        if kind == .stillISO, mode.index == 0 { return .auto }
        return nil
    }

    func activation(_ mode: NikonLadderMode) -> (LadderWrite<NikonLadderControl>?, Bool) {
        switch kind {
        case .iso where dualBaseISO:
            return (LadderWrite(key: .baseISO, value: mode.index == 1 ? "High" : "Low"), true)
        case .iso where autoISO:
            let on = mode.index == 0
            return (LadderWrite(key: .autoISO, value: on ? "On" : "Off"), !on)
        case .stillISO:
            let on = mode.index == 0
            return (LadderWrite(key: .stillAutoISO, value: on ? "On" : "Off"), !on)
        case .shutter:
            return (
                LadderWrite(key: .shutterMode, value: mode.index == 1 ? "Speed" : "Angle"), false
            )
        case .drive, .independentTabs:
            return (nil, false)
        case .whiteBalance where mode.title == Self.tintTab:
            return (nil, false)
        default:
            return (nil, true)
        }
    }

    /// The drum's labels: the body's advertised set where it has one, else the app's ladder.
    func optionsOf(_ mode: NikonLadderMode) -> [String] {
        let advertised = mode.advertised.flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .iso:
            return ISOPickerPolicy.options(
                codec: codec, modeIndex: mode.index,
                includingLiveISO: autoISO && isoCameraOwned ? liveISO.map(String.init) : nil)
        case .stillISO where mode.index == 0:
            return Self.including(liveISO.map(String.init), in: mode.options)
        case .aperture:
            return lensApertures.isEmpty ? mode.options : lensApertures
        case .codec:
            return codecRows.isEmpty ? mode.options : codecRows.map(\.label)
        case .whiteBalance where mode.title == Self.kelvinTab:
            return WhiteBalanceKelvinPolicy.kelvinOptions
        case .whiteBalance where mode.title == Self.tintTab:
            return []
        case .whiteBalance where !photography:
            // R3D NE forbids automatic white balance; the codec can change after the enum landed.
            return PTPCameraPropertyDecoders.whiteBalanceOptions(
                advertised: advertised ?? mode.options, codec: codec)
        case .drive where mode.index == 0:
            return advertised.map(StillDriveMode.driveDrumOptions(advertised:)) ?? mode.options
        default:
            return advertised ?? mode.options
        }
    }

    func marked(_ mode: NikonLadderMode) -> Set<String> {
        if kind == .iso { return ISOPickerPolicy.markedValues(codec: codec, modeIndex: mode.index) }
        return mode.base.isEmpty ? [] : [mode.base]
    }

    /// A typed drum where the common setting covers the tab and nothing locks it.
    func setting(_ mode: NikonLadderMode, options: [String], lock: CaptureLock?)
        -> CaptureLadderSetting?
    {
        guard let typed, lock == nil,
            !(kind == .whiteBalance && [Self.kelvinTab, Self.tintTab].contains(mode.title))
        else { return nil }
        return CaptureLadderSetting(
            key: typed.key,
            offered: options.compactMap { NikonCameraSession.setting(typed, label: $0) })
    }

    public static let kelvinStepsHint: String? =
        "Use minus 10 and plus 10 beside the selected value to fine-adjust"
    public static let codecStepsHint: String? =
        "Use the bit-depth buttons beside the codec to switch depth"

    func stepsHint(kelvin: Bool) -> String? {
        kind == .codec ? Self.codecStepsHint : kelvin ? Self.kelvinStepsHint : nil
    }

    func steps(kelvin: Bool) -> (@Sendable (String) -> (LadderStep, LadderStep)?)? {
        if kind == .codec {
            let rows = codecRows
            let depth = activeCodecDepth
            return { Self.codecSteps(rows: rows, selected: $0, activeDepth: depth) }
        }
        guard kelvin else { return nil }
        return { Self.kelvinSteps($0) }
    }

    /// The body's live pick on the photo Auto tab, so a value off the ladder still centres.
    public static func including(_ live: String?, in ladder: [String]) -> [String] {
        guard let live, let value = Int(live), !ladder.contains(live) else { return ladder }
        let index = ladder.firstIndex { (Int($0) ?? .max) > value } ?? ladder.endIndex
        var grown = ladder
        grown.insert(live, at: index)
        return grown
    }

    static func kelvinValues(_ landed: String) -> [String] {
        WhiteBalanceKelvinPolicy.options(including: landed)
    }

    static func kelvinSteps(_ selected: String) -> (LadderStep, LadderStep) {
        func step(_ delta: Int, _ label: String, _ description: String) -> LadderStep {
            let value =
                WhiteBalanceKelvinPolicy.canFineAdjust(from: selected, delta: delta)
                ? WhiteBalanceKelvinPolicy.fineAdjust(from: selected, delta: delta) : nil
            return LadderStep(label: label, value: value, description: description, lands: true)
        }
        let fine = WhiteBalanceKelvinPolicy.fineStepKelvin
        return (
            step(-fine, "\u{2212}\(fine)", "Decrease Kelvin by \(fine)"),
            step(fine, "+\(fine)", "Increase Kelvin by \(fine)")
        )
    }

    static func codecSteps(rows: [PTPCameraCodecFamily], selected: String, activeDepth: Int?)
        -> (LadderStep, LadderStep)?
    {
        guard let row = rows.first(where: { $0.label == selected }),
            row.offersBitDepthChoice, let low = row.depths.first, let high = row.depths.last
        else { return nil }
        func step(_ depth: PTPCameraFileTypeMode) -> LadderStep {
            LadderStep(
                label: depth.bitDepthLabel, value: depth.label,
                description: "Record \(row.label) at \(depth.bitDepth) bit",
                selected: activeDepth == depth.bitDepth, lands: false)
        }
        return (step(low), step(high))
    }
}
