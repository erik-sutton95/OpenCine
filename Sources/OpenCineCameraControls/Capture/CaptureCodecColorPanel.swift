#if os(iOS)
    import MonitorUI
    import OpenCineCameraVocabulary
    import SwiftUI

    /// The one codec and colour popup body. It lays out only the sections the camera offers
    /// (`CaptureCodecColorChoices.sections`): the codec control, then the colour control for the
    /// selected codec. A host that already owns a richer codec control (a ladder with bit-depth
    /// steps) passes it as `codec`; otherwise the codec choices draw as a tab strip. The colour
    /// control is the host's drum, so each camera keeps its existing colour behaviour.
    /// Compose twin: `CaptureCodecColorPanel` in camera-controls.
    public struct CaptureCodecColorPanel<Codec: View, ColorContent: View>: View {
        public let choices: CaptureCodecColorChoices
        private let codec: Codec
        private let color: ColorContent

        public init(
            choices: CaptureCodecColorChoices,
            @ViewBuilder codec: () -> Codec,
            @ViewBuilder color: () -> ColorContent
        ) {
            self.choices = choices
            self.codec = codec()
            self.color = color()
        }

        public var body: some View {
            let labelled = choices.sections.count > 1
            VStack(alignment: .leading, spacing: 10) {
                ForEach(choices.sections, id: \.self) { section in
                    CaptureCodecColorSectionView(section, labelled: labelled) {
                        switch section {
                        case .codec: codec
                        case .color: color
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("monitor.capture.codecColor")
        }
    }

    /// One section of the codec and colour popup: its caption (when the popup shows more than
    /// one) and its control. A host that draws the codec control itself (a ladder) appends the
    /// colour section with this view so both popups read the same.
    public struct CaptureCodecColorSectionView<Content: View>: View {
        let section: CaptureCodecColorSection
        let labelled: Bool
        let content: Content

        public init(
            _ section: CaptureCodecColorSection, labelled: Bool = true,
            @ViewBuilder content: () -> Content
        ) {
            self.section = section
            self.labelled = labelled
            self.content = content()
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if labelled {
                    Text(section == .codec ? "CODEC" : "COLOR")
                        .font(MonitorTheme.font(11, weight: .semibold)).tracking(0.44)
                        .foregroundStyle(MonitorTheme.muted)
                        .accessibilityAddTraits(.isHeader)
                }
                content
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("monitor.capture.codecColor.\(section.rawValue)")
        }
    }

    extension CaptureCodecColorPanel where Codec == CaptureCodecColorTabs {
        /// Codec choices as a tab strip; `selectCodec` receives the choice identity.
        public init(
            choices: CaptureCodecColorChoices, enabled: Bool,
            selectCodec: @escaping (String) -> Void,
            @ViewBuilder color: () -> ColorContent
        ) {
            self.init(
                choices: choices,
                codec: {
                    CaptureCodecColorTabs(
                        choices: choices.codecs, selected: choices.selectedCodec,
                        enabled: enabled, select: selectCodec)
                },
                color: color)
        }
    }

    /// Choices as a tab strip, vertical past three entries so long camera names stay legible.
    /// A non-editable choice is shown and never sent.
    public struct CaptureCodecColorTabs: View {
        let choices: [CaptureCodecColorChoice]
        let selected: String?
        let enabled: Bool
        let select: (String) -> Void

        public init(
            choices: [CaptureCodecColorChoice], selected: String?, enabled: Bool,
            select: @escaping (String) -> Void
        ) {
            self.choices = choices
            self.selected = selected
            self.enabled = enabled
            self.select = select
        }

        public var body: some View {
            MonitorCaptureTabs(
                options: choices.map(\.id), selection: selected,
                title: { id in choices.first { $0.id == id }?.label ?? id },
                identifier: { "monitor.capture.codecColor.choice.\($0)" },
                vertical: choices.count > 3
            ) { id in
                guard enabled, id != selected, choices.first(where: { $0.id == id })?.isEditable == true
                else { return }
                select(id)
            }
            .disabled(!enabled)
        }
    }
#endif
