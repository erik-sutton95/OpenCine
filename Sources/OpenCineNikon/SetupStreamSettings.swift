/// What one camera setup asks the camera to send, and what it starts at before anyone asks.
///
/// Stream preset and quality bias were one global key per app. That reads fine until an operator
/// works two paths in a day: the camera's own access point is a genuinely narrower link than a
/// cable, so the bias they drop to survive it followed them onto USB-C the next morning and quietly
/// cost them detail on the path that had bandwidth to spare. The setting belongs to the setup,
/// because the constraint it answers to belongs to the path.
///
/// A stored value is the operator's; `nil` means they have never chosen one HERE, which is not the
/// same as choosing the default. Only the second case takes a default, and only the access point
/// gets one that differs — everything else starts from the app-wide seed, which is what the
/// settings rows edit while nothing is connected.
///
/// The Android shell carries a Kotlin twin of this rule in `SetupStreamSettings.kt`; both are
/// tested against the same table so a path can never mean one bias on iPhone and another on
/// Android. Change one, change both.
public enum SetupStreamSettings: Sendable {
    /// The bias a setup runs at: the operator's own choice, or what this path should start at.
    ///
    /// The access point starts Fast. It is the one path whose bandwidth is fixed by the camera's
    /// own radio rather than by the network someone built, and it is where dropped frames and
    /// stalls actually get reported from. Every other path — a router, a hotspot, a cable — starts
    /// from the seed, because nothing about them is known to be narrow.
    public static func qualityBias(
        stored: LiveViewQualityBias?,
        pathKind: CameraPath.Kind?,
        seed: LiveViewQualityBias
    ) -> LiveViewQualityBias {
        if let stored { return stored }
        return pathKind == .cameraAccessPoint ? .latency : seed
    }

    /// The preset a setup runs at: the operator's own choice, or the seed.
    ///
    /// No path override. The preset picks the frame SIZE, and the assists read that frame — the
    /// smallest preset is ~320×240, too little for focus and exposure detectors to read anything
    /// but compression structure. A narrow link is a reason to compress harder, not a reason to
    /// hand every detector a picture it cannot measure.
    public static func streamPreset(
        stored: LiveViewStreamPreset?,
        pathKind: CameraPath.Kind?,
        seed: LiveViewStreamPreset
    ) -> LiveViewStreamPreset {
        stored ?? seed
    }
}

/// Live-view frame size the operator asks the camera for (`LiveViewImageSize`). Protocol-level:
/// each case is one Nikon property byte. `OperatorPreferences.StreamPreset` is this type.
public enum LiveViewStreamPreset: String, CaseIterable, Codable, Equatable, Sendable {
    case fast = "Fast"
    case balanced = "Balanced"
    case quality = "Quality"

    /// `LiveViewImageSize` byte: 1 ≈ QVGA (≤320×240), 2 ≈ VGA (≤640×480), 3 ≈ XGA (≤1024×768).
    /// These bound the frame; a wide sensor readout fills the box, it does not match it.
    public var liveViewImageSize: UInt8 {
        switch self {
        case .fast: 1
        case .balanced: 2
        case .quality: 3
        }
    }
}

/// Live-view compression grade (`LiveViewImageCompression`). `OperatorPreferences.QualityBias`
/// is this type.
public enum LiveViewQualityBias: String, CaseIterable, Codable, Equatable, Sendable {
    case latency = "Latency"
    case balanced = "Balanced"
    case detail = "Detail"

    /// Operator-facing name. Deliberately the same Fast / Balanced / Quality vocabulary as
    /// ``LiveViewStreamPreset``: both controls step the same latency-against-detail axis — one by
    /// frame size, one by compression grade — so naming them differently only invited the
    /// operator to work out which scale they were on.
    ///
    /// Both shells read this, so a label can never mean one compression byte on iPhone and a
    /// different one on Android — which is what happened while the control had two positions
    /// and "Size" stood for both `latency` and `balanced`.
    public var settingsLabel: String {
        switch self {
        case .latency: "Fast"
        case .balanced: "Balanced"
        case .detail: "Quality"
        }
    }

    /// `LiveViewImageCompression` byte. The property is a 6-value enum folding two axes —
    /// a grade (Basic / Normal / **Fine**) and a tie-break (size priority vs quality
    /// priority) — so the operator's three steps walk the grades and take the quality-priority
    /// side wherever detail is what was asked for.
    ///
    /// Previously mapped to 1/2/3 on the assumption of a 3-value property, which meant the
    /// **Fine** grade was unreachable: the top setting was only Normal, and the "steps" landed
    /// mid-grade. Every assist that reads fine detail — peaking most of all — was capped by it.
    /// [verify-on-HW: 5 accepted, and visibly finer than 3]
    public var liveViewImageCompression: UInt8 {
        switch self {
        case .latency: 0  // Basic, size priority — smallest frames, lowest latency
        case .balanced: 3  // Normal, quality priority
        case .detail: 5  // Fine, quality priority
        }
    }
}
