#if os(iOS)
import OpenCineAppKit
import OpenCineCameraVocabulary

/// The status row's readouts after the colour fold: one codec control carries the colour in its
/// popup, as portrait already does, and a camera without a codec readout keeps its own colour
/// readout and target. Values only, never a brand test. Kotlin twin: `MonitorHeaderReadoutPlan`.
public struct MonitorHeaderReadoutPlan<Key: Hashable, Section: Hashable> {
    public let format: [MonitorOperatorLiveReadout<Key, Section>]
    /// The separate colour readout the header still shows, when the colour did not fold.
    public let color: MonitorOperatorLiveReadout<Key, Section>?
    /// The colour readout the codec control absorbed, when the fold happened.
    public let foldedColor: MonitorOperatorLiveReadout<Key, Section>?
    /// The landscape codec control that also speaks the folded colour. Portrait keeps its spoken
    /// codec value, as it already showed it.
    public let combined: MonitorHeaderCombinedCodec<Key, Section>?
    /// The readout that carries the accent: the declared slot, only while the header shows it.
    /// Nil otherwise; the accent never moves to another readout.
    public let accented: Key?

    public init(format: [MonitorOperatorLiveReadout<Key, Section>],
        color: MonitorOperatorLiveReadout<Key, Section>?,
        foldedColor: MonitorOperatorLiveReadout<Key, Section>?,
        combined: MonitorHeaderCombinedCodec<Key, Section>?, accented: Key?) {
        self.format = format; self.color = color
        self.foldedColor = foldedColor; self.combined = combined; self.accented = accented
    }

    public var foldsColor: Bool { foldedColor != nil }

    /// The codec readout speaks both reported values, so the colour is still announced after its
    /// own target disappears. Nil for every other readout and when the colour stays separate.
    public func accessibility(for value: MonitorOperatorLiveReadout<Key, Section>)
        -> (label: String, value: String)? {
        guard let combined, value.id == combined.codec.id else { return nil }
        return (combined.title, combined.value)
    }
}

/// The one codec control that carries the colour: the shown value stays the codec, while the
/// spoken value covers both. Kotlin twin: `MonitorHeaderCombinedCodec`.
public struct MonitorHeaderCombinedCodec<Key: Hashable, Section: Hashable> {
    public let codec: MonitorOperatorLiveReadout<Key, Section>
    public let color: MonitorOperatorLiveReadout<Key, Section>

    public init(codec: MonitorOperatorLiveReadout<Key, Section>,
        color: MonitorOperatorLiveReadout<Key, Section>) {
        self.codec = codec; self.color = color
    }

    public var title: String { "Codec and color" }
    /// The separator is the one the apps use for combined values (`6K · 25p`).
    public var value: String { "\(codec.value) · \(color.value)" }
}

public enum MonitorHeaderReadoutPolicy {
    /// The status row's mounted format readouts and the separate colour readout. Portrait and
    /// landscape both fold colour into a codec readout; portrait photography keeps its existing
    /// stack because its quality readout is not the video codec. Landscape also speaks both
    /// values from the one control.
    public static func plan<Key: Hashable, Section: Hashable>(
        format: [MonitorOperatorLiveReadout<Key, Section>],
        color: MonitorOperatorLiveReadout<Key, Section>?,
        mode: MonitorOperatorLiveReadout<Key, Section>?,
        accent: MonitorHeaderAccent,
        portrait: Bool, photo: Bool,
        isMounted: (Section) -> Bool, codecSection: Section
    ) -> MonitorHeaderReadoutPlan<Key, Section> {
        let shownFormat = format.filter { $0.section.map(isMounted) ?? true }
        let shownColor = color.flatMap { value in
            (value.section.map(isMounted) ?? true) ? value : nil
        }
        let codec = shownFormat.first { $0.section == codecSection }
        let foldedColor = !(portrait && photo) && codec != nil ? shownColor : nil
        let combined = !portrait ? foldedColor.flatMap { color in
            codec.map { MonitorHeaderCombinedCodec(codec: $0, color: color) }
        } : nil
        let accented: Key? = switch accent {
        case .shootingMode: mode?.id
        case .codec: codec?.id
        }
        return MonitorHeaderReadoutPlan(
            format: shownFormat, color: foldedColor == nil ? shownColor : nil,
            foldedColor: foldedColor, combined: combined, accented: accented)
    }
}
#endif
