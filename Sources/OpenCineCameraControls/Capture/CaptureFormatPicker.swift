import Foundation
import OpenCineCameraVocabulary

/// One optional presentation axis. Image area and recording aspect are distinct facts.
public struct CaptureFormatGroup: Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// An indivisible, supplied format choice. Grouping never constructs a new camera command.
public struct CaptureFormatChoice<Value: Hashable & Sendable>: Hashable, Sendable {
    public let value: Value
    public let title: String
    public let imageArea: CaptureFormatGroup?
    public let aspect: CaptureFormatGroup?
    public let resolution: CaptureFormatGroup?
    public let frameRate: CaptureFormatGroup?
    public let isEditable: Bool

    public init(
        value: Value, title: String, imageArea: CaptureFormatGroup? = nil,
        aspect: CaptureFormatGroup? = nil, resolution: CaptureFormatGroup? = nil,
        frameRate: CaptureFormatGroup? = nil, isEditable: Bool = true
    ) {
        self.value = value
        self.title = title
        self.imageArea = imageArea
        self.aspect = aspect
        self.resolution = resolution
        self.frameRate = frameRate
        self.isEditable = isEditable
    }

    public var drumTitle: String { frameRate?.title ?? title }
}

/// Local picker position over exact choices, independent of camera readback and write authority.
public struct CaptureFormatPickerState<Value: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var imageArea: CaptureFormatGroup?
    public private(set) var aspect: CaptureFormatGroup?
    public private(set) var resolution: CaptureFormatGroup?
    public private(set) var value: Value?

    public init(choices: [CaptureFormatChoice<Value>], current: Value?) {
        let reported = choices.first { $0.value == current }
        let seat = reported ?? choices.first
        imageArea = seat?.imageArea
        aspect = seat?.aspect
        resolution = seat?.resolution
        value = reported?.value
    }

    public func visibleChoices(_ choices: [CaptureFormatChoice<Value>]) -> [CaptureFormatChoice<Value>] {
        choices.filter { $0.imageArea == imageArea && $0.aspect == aspect && $0.resolution == resolution }
    }

    public func aspects(_ choices: [CaptureFormatChoice<Value>]) -> [CaptureFormatGroup?] {
        Self.groups(choices.filter { $0.imageArea == imageArea }.map(\.aspect))
    }

    public func resolutions(_ choices: [CaptureFormatChoice<Value>]) -> [CaptureFormatGroup?] {
        Self.groups(choices.filter { $0.imageArea == imageArea && $0.aspect == aspect }.map(\.resolution))
    }

    /// Preserve the actual selected rate if eligible; otherwise use the first supplied tuple.
    public mutating func select(
        imageArea: CaptureFormatGroup?, aspect: CaptureFormatGroup?, resolution: CaptureFormatGroup?,
        choices: [CaptureFormatChoice<Value>], enabled: Bool
    ) -> CaptureFormatChoice<Value>? {
        guard enabled else { return nil }
        let previous = choices.first { $0.value == value }
        let inArea = choices.filter { $0.imageArea == imageArea }
        guard !inArea.isEmpty else { return nil }
        let areaAspects = Self.groups(inArea.map(\.aspect))
        guard imageArea != self.imageArea || aspect == self.aspect || areaAspects.contains(aspect) else { return nil }
        let nextAspect = areaAspects.contains(aspect) ? aspect : areaAspects.first ?? nil
        let inAspect = inArea.filter { $0.aspect == nextAspect }
        let sizes = Self.groups(inAspect.map(\.resolution))
        guard imageArea != self.imageArea || aspect != self.aspect || sizes.contains(resolution) else { return nil }
        let nextResolution = sizes.contains(resolution)
            ? resolution : sizes.first(where: { $0?.title == resolution?.title }) ?? sizes.first ?? nil
        let candidates = inAspect.filter { $0.resolution == nextResolution && $0.isEditable }
        guard let next = candidates.first(where: { $0.frameRate == previous?.frameRate }) ?? candidates.first else {
            return nil
        }
        self.imageArea = imageArea
        self.aspect = nextAspect
        self.resolution = nextResolution
        guard value != next.value else { return nil }
        value = next.value
        return next
    }

    /// Drum admission resolves only one member of the current supplied bucket.
    public mutating func selectDrum(
        _ title: String, choices: [CaptureFormatChoice<Value>], enabled: Bool
    ) -> CaptureFormatChoice<Value>? {
        guard enabled else { return nil }
        let matches = visibleChoices(choices).filter { $0.drumTitle == title }
        guard Set(matches.map(\.value)).count == 1,
            let next = matches.first(where: \.isEditable), value != next.value
        else { return nil }
        value = next.value
        return next
    }

    public static func groups(_ values: [CaptureFormatGroup?]) -> [CaptureFormatGroup?] {
        var seen = Set<CaptureFormatGroup?>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Existing camera-vocabulary values projected without adding format fallback policy.
public enum CaptureVideoFormatChoices {
    public static func make(available: [VideoFormat], current: VideoFormat?) -> [CaptureFormatChoice<VideoFormat>] {
        var values = available
        if let current, !values.contains(current) { values.insert(current, at: 0) }
        return values.map { format in
            CaptureFormatChoice(
                value: format, title: format.chipLabel,
                aspect: format.resolution.aspect.map { CaptureFormatGroup(id: $0.rawValue, title: $0.label) },
                resolution: CaptureFormatGroup(id: String(format.resolution.rawValue), title: format.resolution.tabTitle),
                frameRate: CaptureFormatGroup(id: String(format.frameRate.rawValue), title: format.frameRate.drumLabel),
                isEditable: available.contains(format))
        }
    }
}

#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// The common format controls. The caller retains source, command, refusal and readback ownership.
    public struct CaptureFormatPicker<Value: Hashable & Sendable>: View {
        private let choices: [CaptureFormatChoice<Value>]
        private let current: Value?
        private let enabled: Bool
        private let haptics: Bool
        private let followsReadback: Bool
        private let sourceIdentity: AnyHashable
        private let isCurrent: () -> Bool
        private let onSelect: (CaptureFormatChoice<Value>) -> Void
        @State private var position: CaptureFormatPickerState<Value>
        @State private var revision: UInt64 = 0

        public init(
            choices: [CaptureFormatChoice<Value>], current: Value?, enabled: Bool,
            haptics: Bool, sourceIdentity: AnyHashable, followsReadback: Bool = true, isCurrent: @escaping () -> Bool,
            onSelect: @escaping (CaptureFormatChoice<Value>) -> Void
        ) {
            self.choices = choices
            self.current = current
            self.enabled = enabled
            self.haptics = haptics
            self.followsReadback = followsReadback
            self.sourceIdentity = sourceIdentity
            self.isCurrent = isCurrent
            self.onSelect = onSelect
            _position = State(initialValue: CaptureFormatPickerState(choices: choices, current: current))
        }

        public var body: some View {
            let visible = position.visibleChoices(choices)
            let shown = visible.first { $0.value == position.value }?.drumTitle ?? ""
            VStack(alignment: .leading, spacing: 8) {
                MonitorValueDrum(
                    options: visible.map(\.drumTitle),
                    selection: Binding(get: { shown }, set: { title in
                        if let next = position.selectDrum(title, choices: choices, enabled: enabled && isCurrent()) {
                            onSelect(next)
                        }
                    }),
                    isInteractive: enabled && visible.contains(where: \.isEditable), haptics: haptics,
                    interactionIdentity: { AnyHashable(Interaction(source: sourceIdentity, choices: choices, revision: revision)) })
                let areas = CaptureFormatPickerState<Value>.groups(choices.map(\.imageArea))
                if areas.contains(where: { $0 != nil }) {
                    tabs(areas, selected: position.imageArea, identifier: "monitor.capture.format.area") { area in
                        select(area: area, aspect: position.aspect, resolution: position.resolution)
                    }
                }
                let aspects = position.aspects(choices)
                if aspects.count > 1 {
                    tabs(aspects, selected: position.aspect, identifier: "monitor.capture.format.aspect") { aspect in
                        select(area: position.imageArea, aspect: aspect, resolution: position.resolution)
                    }
                }
                let sizes = position.resolutions(choices)
                if !sizes.isEmpty {
                    tabs(sizes, selected: position.resolution, identifier: "monitor.capture.format.resolution") { size in
                        select(area: position.imageArea, aspect: position.aspect, resolution: size)
                    }
                }
            }
            .onChange(of: current) { _, _ in if followsReadback { reseat() } }
            .onChange(of: followsReadback) { _, follows in if follows { reseat() } }
            .onChange(of: choices) { _, _ in reseat() }
            .onChange(of: sourceIdentity) { _, _ in reseat() }
            .onChange(of: enabled) { _, _ in revision &+= 1 }
            .accessibilityIdentifier("monitor.capture.format.groups")
        }

        private struct Interaction: Hashable {
            let source: AnyHashable
            let choices: [CaptureFormatChoice<Value>]
            let revision: UInt64
        }

        private func tabs(
            _ groups: [CaptureFormatGroup?], selected: CaptureFormatGroup?, identifier: String,
            select: @escaping (CaptureFormatGroup?) -> Void
        ) -> some View {
            MonitorCaptureTabs(options: groups, selection: .some(selected), title: { $0?.title ?? "Other" },
                identifier: { identifier + "." + ($0?.id ?? "unclassified") }, select: select)
                .disabled(!enabled)
        }

        private func select(area: CaptureFormatGroup?, aspect: CaptureFormatGroup?, resolution: CaptureFormatGroup?) {
            guard isCurrent() else { return }
            revision &+= 1
            if let next = position.select(imageArea: area, aspect: aspect, resolution: resolution,
                choices: choices, enabled: enabled) { onSelect(next) }
        }

        private func reseat() {
            revision &+= 1
            position = CaptureFormatPickerState(choices: choices, current: current)
        }
    }
#endif
