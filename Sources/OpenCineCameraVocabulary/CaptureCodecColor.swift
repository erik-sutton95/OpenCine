import Foundation

/// The two header readouts that describe how a clip is recorded. Both open the same popup:
/// codec and colour are one decision on a camera whose colour choices depend on the codec.
/// Kotlin twin: `CaptureCodecColorReadout`.
public enum CaptureCodecColorReadout: String, CaseIterable, Sendable {
    case codec
    case color

    /// The popup a tap on this readout opens. There is only one.
    public var popup: CaptureCodecColorPopup { .codecColor }
}

/// The one codec and colour popup.
public enum CaptureCodecColorPopup: Hashable, Sendable {
    case codecColor
}

/// The popup's sections, in display order.
public enum CaptureCodecColorSection: String, CaseIterable, Sendable {
    case codec
    case color
}

/// One choice the camera offers. The identity is integration-owned (an advertised raw value,
/// a profile name), never a label match; the label is the camera's own name for it.
/// Kotlin twin: `CaptureCodecColorChoice`.
public struct CaptureCodecColorChoice: Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// False for a value the camera reports but does not let the operator change, such as a
    /// colour fixed by the codec (R3D records Log3G10 only).
    public let isEditable: Bool

    public init(id: String, label: String, isEditable: Bool = true) {
        self.id = id
        self.label = label
        self.isEditable = isEditable
    }
}

/// What the codec and colour popup lists: only what the camera offers. A camera without codec
/// choices shows colour alone; colour choices are the ones valid for the selected codec, as the
/// camera reports them. An unknown selection is `nil`, never the first choice.
/// Kotlin twin: `CaptureCodecColorChoices`.
public struct CaptureCodecColorChoices: Hashable, Sendable {
    public typealias Choice = CaptureCodecColorChoice

    public let codecs: [Choice]
    public let selectedCodec: String?
    public let colors: [Choice]
    public let selectedColor: String?

    public init(
        codecs: [Choice] = [], selectedCodec: String? = nil,
        colors: [Choice] = [], selectedColor: String? = nil
    ) {
        let codecs = Self.unique(codecs)
        let colors = Self.unique(colors)
        self.codecs = codecs
        self.colors = colors
        self.selectedCodec = selectedCodec.flatMap { id in codecs.contains { $0.id == id } ? id : nil }
        self.selectedColor = selectedColor.flatMap { id in colors.contains { $0.id == id } ? id : nil }
    }

    public static let empty = CaptureCodecColorChoices()

    public var showsCodec: Bool { !codecs.isEmpty }
    public var showsColor: Bool { !colors.isEmpty }
    public var isEmpty: Bool { codecs.isEmpty && colors.isEmpty }

    public var sections: [CaptureCodecColorSection] {
        (showsCodec ? [.codec] : []) + (showsColor ? [.color] : [])
    }

    /// The popup header: names only the sections the camera offers.
    public var title: String {
        switch (showsCodec, showsColor) {
        case (true, true): "CODEC · COLOR"
        case (true, false): "CODEC"
        default: "COLOR"
        }
    }

    public var codecEditable: Bool { codecs.contains(where: \.isEditable) }
    public var colorEditable: Bool { colors.contains(where: \.isEditable) }

    public var selectedCodecChoice: Choice? { selectedCodec.flatMap { id in codecs.first { $0.id == id } } }
    public var selectedColorChoice: Choice? { selectedColor.flatMap { id in colors.first { $0.id == id } } }

    /// The camera's order; a repeated identity keeps its first entry.
    private static func unique(_ choices: [Choice]) -> [Choice] {
        var seen = Set<String>()
        return choices.filter { seen.insert($0.id).inserted }
    }
}
