#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineCore
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// A snapshot of the same primary choices used by CapturePickerPanel. It holds
    /// presentation values only; camera status stays authoritative throughout a drag.
    public struct CaptureQuickSnapshot: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case iso, isoLimit, ev, shutter, angle, whiteBalanceMode, kelvin, focus, aperture
            case exposure, audio
            case format, color, shootingMode
        }
        public let kind: Kind
        public let title: String
        public let options: [String]
        public let selection: String
        public var marked: Set<String> = []
        public var context = ""
        public var enabled = true
        public var commonField: MonitorCaptureField? = nil
        public var nativeEditor: MonitorControlModel.Editor? = nil
        public var audioControl: CaptureAudioControl? = nil
        public var audioSourceID: CaptureAudioSourceID? = nil
        /// The sheet an integration-owned quick choice commits through the host slot (format or
        /// colour), never as camera-vocabulary wire enums; `nil` for every vocabulary choice.
        public var nativeSheet: CaptureSheet?

        /// An integration-owned format (`.resolution`) or colour (`.color`) choice; `nil` for any
        /// other sheet, which has no native quick slot.
        public static func native(sheet: CaptureSheet, title: String, options: [String], selection: String,
            context: String, enabled: Bool) -> Self? {
            let kind: Kind
            switch sheet {
            case .resolution: kind = .format
            case .color: kind = .color
            default: return nil
            }
            var result = Self(kind: kind, title: title, options: options, selection: selection,
                context: context, enabled: enabled)
            result.nativeSheet = sheet
            return result
        }

        public static func common(_ field: MonitorCaptureField) -> Self {
            Self(
                kind: field.key == .iso
                    ? .iso
                    : field.key == .shutter
                        ? .shutter : field.key == .exposureCompensation ? .ev : .kelvin,
                title: field.title, options: field.choices.map(\.label),
                selection: field.label ?? "",
                enabled: field.isEditable, commonField: field)
        }

        public var index: Int {
            if let exact = options.firstIndex(of: selection) { return exact }
            switch kind {
            case .kelvin: return options.firstIndex(of: "5600K") ?? 0
            case .ev: return options.firstIndex(of: "0.0") ?? 0
            case .shutter:
                guard let current = CamCapShutter.denom(from: selection),
                    let nearest = CamCapShutter.nearestDenom(
                        current, in: options.compactMap { CamCapShutter.denom(from: $0) })
                else { return 0 }
                return options.firstIndex(of: CamCapShutter.label(nearest)) ?? 0
            default: return 0
            }
        }
        public var delayed: Bool { [.iso, .isoLimit, .ev, .shutter, .angle].contains(kind) }

        /// Options and capability for an in-flight gesture. Live HUD selection is
        /// excluded so an optimistic Auto/Manual write cannot cancel a drag or settle.
        public var sourceIdentity: SourceIdentity {
            SourceIdentity(
                kind: kind, title: title, options: options, marked: marked, context: context,
                enabled: enabled, nativeEditor: nativeEditor, nativeSheet: nativeSheet)
        }

        public struct SourceIdentity: Hashable, Sendable {
            public var kind: Kind
            public var title: String
            public var options: [String]
            public var marked: Set<String>
            public var context: String
            public var enabled: Bool
            public var nativeEditor: MonitorControlModel.Editor? = nil
            public var nativeSheet: CaptureSheet? = nil
        }

        public var display: MonitorReadoutSnapshot {
            MonitorReadoutSnapshot(
                title: title, options: options, selection: selection, marked: marked,
                fallbackIndex: index)
        }

        public var chipValue: String { selection.isEmpty ? "\u{2014}" : selection }

        /// Angle HUD: preferred only when it maps to live 1/N, else the nearest live label.
        public static func shutterReadout(
            status: CameraStatus, shutterUsesAngle: Bool, shutterAngleDegrees: Double,
            facePriorityExposureEnabled: Bool = false
        ) -> String {
            primary(
                .shutter, status: status, facePriorityExposureEnabled: facePriorityExposureEnabled,
                shutterUsesAngle: shutterUsesAngle, shutterAngleDegrees: shutterAngleDegrees
            )?.chipValue ?? "\u{2014}"
        }

        public static func persistPreferredAngle(
            afterDenom denom: Int, fps: Int, usesAngle: Bool, isPhoto: Bool, expoIsAuto: Bool
        ) -> Double? {
            guard
                GamepadShutterSync.shouldPersistPreferredAngle(
                    usesAngle: usesAngle, isPhoto: isPhoto, expoIsAuto: expoIsAuto)
            else { return nil }
            return GamepadShutterSync.preferredAngle(afterDenom: denom, fps: fps)
        }

        public func changedValue(translation: Double, current: Self?) -> String? {
            guard self == current, enabled else { return nil }
            return display.changedValue(at: display.position(translation: translation))
        }

        /// The primary choices of `sheet` for the camera `controls` describe: focus and iris
        /// follow the one capability model.
        public static func primary(
            _ sheet: CaptureSheet, status: CameraStatus, controls: ControlCapabilities,
            cameraModel: CameraModel? = nil, facePriorityExposureEnabled: Bool = false,
            shutterUsesAngle: Bool = false, shutterAngleDegrees: Double = 180, aeLocked: Bool = false,
            awbLocked: Bool = false, offersAwbLock: Bool = false,
            focusOptions: [FocusOption] = FocusOption.allCases, profile: CameraLabelProfile = .standard,
            audioField: CaptureAudioField? = nil, audioSourceID: CaptureAudioSourceID? = nil
        ) -> Self? {
            primary(sheet, status: status, cameraModel: cameraModel,
                supportsFocusMode: controls.focus.isOffered, supportsAperture: controls.iris.isOffered,
                facePriorityExposureEnabled: facePriorityExposureEnabled, shutterUsesAngle: shutterUsesAngle,
                shutterAngleDegrees: shutterAngleDegrees, aeLocked: aeLocked, awbLocked: awbLocked,
                offersAwbLock: offersAwbLock, focusOptions: focusOptions, profile: profile,
                audioField: audioField, audioSourceID: audioSourceID)
        }

        public static func primary(
            _ sheet: CaptureSheet, status: CameraStatus, cameraModel: CameraModel? = nil,
            supportsFocusMode: Bool = false, supportsAperture: Bool? = nil,
            facePriorityExposureEnabled: Bool = false,
            shutterUsesAngle: Bool = false, shutterAngleDegrees: Double = 180,
            aeLocked: Bool = false,
            awbLocked: Bool = false, offersAwbLock: Bool = false,
            focusOptions: [FocusOption] = FocusOption.allCases,
            profile: CameraLabelProfile = .standard, audioField: CaptureAudioField? = nil,
            audioSourceID: CaptureAudioSourceID? = nil
        ) -> Self? {
            switch sheet {
            case .iso:
                if CaptureLists.offersIsoAuto(from: status), status.isoIndex == .auto {
                    let choices = CaptureLists.isoAutoLabels(
                        from: status, model: cameraModel)
                    return Self(
                        kind: .isoLimit, title: "ISO", options: choices,
                        selection: CaptureLists.isoAutoLabel(
                            from: status, model: cameraModel))
                }
                return Self(
                    kind: .iso, title: "ISO", options: CaptureLists.isoDrumLabels(from: status),
                    selection: status.isoIndex?.label ?? (status.iso > 0 ? String(status.iso) : ""),
                    marked: CaptureLists.isoMarkedLabels(from: status))
            case .shutter:
                if status.expoMode == .auto {
                    return Self(
                        kind: .ev, title: "EV", options: CaptureLists.evLabels,
                        selection: status.evComp?.label ?? "",
                        enabled: !facePriorityExposureEnabled)
                }
                if shutterUsesAngle, !status.isPhoto {
                    let preferred = shutterAngleDegrees
                    let mapped = ShutterAngle.denom(
                        degrees: preferred, fps: status.fps,
                        available: CaptureLists.shutterDenoms(from: status))
                    return Self(
                        kind: .angle, title: "SHUTTER", options: ShutterAngle.labels,
                        selection: status.shutterDenom <= 0
                            ? ""
                            : mapped == status.shutterDenom
                                ? ShutterAngle.label(preferred)
                                : ShutterAngle.nearestLabel(
                                    denom: status.shutterDenom, fps: status.fps) ?? "",
                        context: "\(status.fps):\(CaptureLists.shutterDenoms(from: status))")
                }
                return Self(
                    kind: .shutter, title: "SHUTTER",
                    options: CaptureLists.shutterLabels(from: status),
                    selection: status.shutterDenom > 0
                        ? CamCapShutter.label(status.shutterDenom) : "",
                    context: String(status.fps))
            case .wb:
                if status.whiteBalance?.mode == .custom, !awbLocked {
                    return Self(
                        kind: .kelvin, title: "WB", options: CaptureLists.kelvinLabels,
                        selection: "\(status.whiteBalanceKelvin)K",
                        context: String(status.whiteBalanceTint ?? 0))
                }
                return Self(
                    kind: .whiteBalanceMode, title: "WB",
                    options: CaptureLists.whiteBalanceModeLabels(
                        offersLock: awbLocked || offersAwbLock),
                    selection: CaptureLists.whiteBalanceModeSelection(
                        status.whiteBalance, awbLocked: awbLocked) ?? "")
            case .focus:
                guard supportsFocusMode else { return nil }
                return Self(
                    kind: .focus, title: "FOCUS", options: focusOptions.map(\.chip),
                    selection: CaptureLists.focusOption(from: status)?.chip ?? "",
                    context: String(describing: status.focusTrack))
            case .aperture:
                guard supportsAperture ?? (cameraModel?.captureProfile?.supportsAperture == true)
                else { return nil }
                return Self(
                    kind: .aperture, title: "APERTURE",
                    options: CaptureLists.apertureStrategies(from: status).map(\.label),
                    selection: status.apertureStrategy?.label ?? "")
            case .exposure:
                return Self(
                    kind: .exposure, title: "EXPOSURE",
                    options: CaptureLists.exposureLabels(aeLocked: aeLocked),
                    selection: CaptureLists.exposureSelection(status.expoMode, aeLocked: aeLocked)
                        ?? "")
            case .audio:
                guard !status.isPhoto, let audioField else { return nil }
                return Self(
                    kind: .audio, title: "AUDIO", options: audioField.choices.map(\.label),
                    selection: audioField.observed?.label ?? "",
                    context: audioField.id.rawValue + (audioSourceID.map { "\($0.session):\($0.epoch)" } ?? ""), enabled: audioField.isEditable,
                    audioControl: audioField.id, audioSourceID: audioSourceID)
            case .resolution:
                if status.isPhoto {
                    return Self(
                        kind: .format, title: "FORMAT", options: [], selection: "Photo",
                        enabled: false)
                }
                return formatSnapshot(status: status, cameraModel: cameraModel)
            case .color:
                guard !status.isPhoto else { return nil }
                return colorSnapshot(status: status, cameraModel: cameraModel, profile: profile)
            case .mode:
                return shootingModeSnapshot(
                    status: status, cameraModel: cameraModel, profile: profile)
            }
        }

        private static func formatSnapshot(status: CameraStatus, cameraModel: CameraModel?) -> Self?
        {
            let formats = CamCapVideoFormat.pickerFormats(
                available: status.availableVideoFormats, model: cameraModel,
                shootingMode: status.shootingMode)
            guard let resolution = status.videoFormat?.resolution ?? status.videoResolution
            else { return nil }
            let currentRate = status.videoFormat?.frameRate ?? VideoFrameRate.fromFps(status.fps)
            let rates = CamCapVideoFormat.frameRates(
                available: formats, resolution: resolution, current: currentRate)
            let options = rates.map(\.drumLabel)
            guard !options.isEmpty else { return nil }
            let live = currentRate?.drumLabel ?? ""
            return Self(
                kind: .format, title: "FORMAT", options: options,
                selection: options.contains(live) ? live : "",
                context:
                    "\(resolution.rawValue):\(status.shootingMode):\(options.joined(separator: ","))",
                enabled: !formats.isEmpty
            )
        }

        private static func colorSnapshot(
            status: CameraStatus, cameraModel: CameraModel?, profile: CameraLabelProfile
        ) -> Self? {
            let family = cameraModel?.family ?? .other
            let modes = CamCapColorMode.wheel(
                available: status.availableColorModes,
                order: profile.colorModes ?? cameraModel?.captureProfile?.labels.colorModes ?? [])
            let options = CaptureLists.colorDrumLabels(
                offered: modes, current: status.colorMode, family: family, profile: profile)
            guard !options.isEmpty else { return nil }
            let live = status.colorMode?.label(for: family, in: profile) ?? ""
            return Self(
                kind: .color, title: "COLOR", options: options,
                selection: options.contains(live) ? live : "",
                context: "\(family):\(options.joined(separator: ",")):\(status.isRecording)")
        }

        private static func shootingModeSnapshot(
            status: CameraStatus, cameraModel: CameraModel?, profile: CameraLabelProfile
        ) -> Self {
            let options = CaptureLists.operatorShootingModes(from: status, model: cameraModel).map {
                $0.label(for: cameraModel, in: profile)
            }
            let live =
                ShootingMode.fromStatus(status.shootingMode)?.label(for: cameraModel, in: profile)
                ?? ""
            return Self(
                kind: .shootingMode, title: "MODE", options: options,
                selection: options.contains(live) ? live : "",
                context: "\(status.shootingMode):\(status.isRecording)",
                enabled: !status.isRecording)
        }

        /// Typed camera calls retain the production capability lists, Kelvin/tint
        /// preservation, and shutter-angle conversion; the host routes each to its session.
        @MainActor public func apply<Host: CaptureSheetHost>(_ value: String, host: Host) {
            guard enabled, options.contains(value), value != selection, !host.sessionLocked else {
                return
            }
            if let sheet = nativeSheet {
                guard host.quickSnapshot(sheet) == self else { return }
                host.commitNativeCaptureQuick(sheet, selection: value)
                return
            }
            if let commonField {
                guard let choice = commonField.choices.first(where: { $0.label == value }) else {
                    return
                }
                host.control.commit(choice, from: commonField)
                return
            }
            let status = host.displayStatus
            let origin = CaptureCommitOrigin.readout(nativeEditor)
            switch kind {
            case .iso:
                if let iso = IsoIndex.allCases.first(where: { $0.label == value }),
                    CaptureLists.isoIndices(from: status).contains(iso)
                {
                    host.commit(.iso(iso), from: origin)
                }
            case .isoLimit:
                if let limit = CaptureLists.isoLimit(
                    from: value, status: status, model: host.connectedBody)
                {
                    host.commit(.isoLimit(limit), from: origin)
                }
            case .ev:
                if !host.facePriorityExposureEnabled, let ev = EvComp(label: value) {
                    host.commit(.ev(ev), from: origin)
                }
            case .shutter:
                if let denom = CamCapShutter.denom(from: value),
                    CaptureLists.shutterDenoms(from: status).contains(denom)
                {
                    host.commit(.shutterDenom(denom), from: origin)
                }
            case .angle:
                if let degrees = ShutterAngle.parse(value) {
                    host.commit(.shutterAngle(degrees), from: origin)
                }
            case .whiteBalanceMode:
                if value == CaptureLists.awbLock {
                    host.commit(.autoWhiteBalanceLock, from: origin)
                } else if value == WhiteBalanceMode.auto.label {
                    host.commit(.whiteBalanceAuto, from: origin)
                } else {
                    let kelvin =
                        (2_000...10_000).contains(status.whiteBalanceKelvin)
                        ? status.whiteBalanceKelvin : 5_600
                    host.commit(
                        .whiteBalanceCustom(
                            kelvin: kelvin, tint: min(100, max(-100, status.whiteBalanceTint ?? 0))),
                        from: origin)
                }
            case .kelvin:
                if let kelvin = CaptureLists.kelvin(from: value) {
                    host.commit(
                        .whiteBalanceCustom(
                            kelvin: kelvin, tint: min(100, max(-100, status.whiteBalanceTint ?? 0))),
                        from: origin)
                }
            case .focus:
                if let option = host.focusOptions.first(where: { $0.chip == value }) {
                    host.commit(.focus(option, label: value), from: origin)
                }
            case .aperture:
                if let strategy = CaptureLists.apertureStrategies(from: status).first(where: {
                    $0.label == value
                }) {
                    host.commit(.aperture(strategy), from: origin)
                }
            case .exposure:
                if let mode = ExpoMode.allCases.first(where: { $0.label == value }) {
                    host.commit(.expoMode(mode), from: origin)
                }
            case .audio:
                guard let service = host.audioService, service.sourceID == audioSourceID,
                    let field = service.fields.first(where: { $0.id == audioControl }),
                    field.isEditable,
                    let choice = field.choices.first(where: { $0.label == value })
                else { return }
                _ = service.commit(choice)
            case .format:
                let formats = CamCapVideoFormat.pickerFormats(
                    available: status.availableVideoFormats,
                    model: host.connectedBody,
                    shootingMode: status.shootingMode)
                guard let resolution = status.videoFormat?.resolution ?? status.videoResolution
                else { return }
                let currentRate = status.videoFormat?.frameRate ?? VideoFrameRate.fromFps(status.fps)
                let rates = CamCapVideoFormat.frameRates(
                    available: formats, resolution: resolution, current: currentRate)
                if let rate = VideoFrameRate(drumLabel: value), rates.contains(rate) {
                    host.commit(
                        .videoFormat(VideoFormat(resolution: resolution, frameRate: rate)),
                        from: origin)
                }
            case .color:
                // The drum's extra entry is the current mode: selecting it sends nothing.
                if let mode = ColorMode(label: value, in: host.labelProfile), mode != status.colorMode {
                    host.commit(.colorMode(mode), from: origin)
                }
            case .shootingMode:
                guard !status.isRecording else { return }
                if let mode = CaptureLists.operatorShootingModes(
                    from: status, model: host.connectedBody
                ).first(where: {
                    $0.label(for: host.connectedBody, in: host.labelProfile) == value
                }), mode != .livePhoto {
                    host.commit(.shootingMode(mode), from: origin)
                }
            }
        }
    }

    public struct CaptureDrumPresentation: Equatable {
        public let id: UUID
        public let sheet: CaptureSheet
        public let snapshot: CaptureQuickSnapshot
        public var position: Double

        public init(id: UUID, sheet: CaptureSheet, snapshot: CaptureQuickSnapshot, position: Double)
        {
            self.id = id
            self.sheet = sheet
            self.snapshot = snapshot
            self.position = position
        }

        /// The origin is only a visual anchor when native state is unknown. A
        /// stationary hold (or a drag back to that origin) must keep it unselected.
        public var selection: String { snapshot.display.selection(at: position) }
    }

    /// Capture adapter for the shared readout gesture. It derives native options and
    /// owns delayed SET admission; pointer timing, ownership and lifecycle live in MonitorUI.
    public struct CaptureSheetReadoutGesture<Host: CaptureSheetHost>: ViewModifier {
        public let sheet: CaptureSheet
        public let locked: Bool
        @Binding public var ownership: MonitorReadoutOwnership
        public let onTap: () -> Void
        @Environment(Host.self) private var host
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.monitorWindowGeometry) private var windowGeometry
        @State private var commitTask: Task<Void, Never>?

        private struct Source: Hashable, Sendable {
            let cameraID: UUID?
            let phase: String
            let controlID: String
            let snapshot: CaptureQuickSnapshot?
        }

        private var source: Source {
            Source(
                cameraID: host.connectedCameraID, phase: host.sessionPhaseLabel,
                controlID: sheet.rawValue, snapshot: host.quickSnapshot(sheet))
        }

        private var canBegin: Bool {
            CaptureReadoutAdmission.canBegin(
                locked: locked, sessionLocked: host.sessionLocked,
                sceneActive: scenePhase == .active, operatorPanel: host.operatorPanelOpen)
        }

        private var canCommit: Bool {
            CaptureReadoutAdmission.canCommit(canBegin: canBegin, captureSheet: host.captureSheet)
        }

        public init(
            sheet: CaptureSheet, locked: Bool, ownership: Binding<MonitorReadoutOwnership>,
            onTap: @escaping () -> Void
        ) {
            self.sheet = sheet
            self.locked = locked
            _ownership = ownership
            self.onTap = onTap
        }

        public func body(content: Content) -> some View {
            let current = source
            return content.modifier(
                MonitorReadoutGesture(
                    snapshot: current.snapshot.flatMap { $0.enabled ? $0.display : nil },
                    sourceIdentity: current, isEnabled: canBegin, ownership: $ownership,
                    presentationOwner: { host.captureDrum?.id }, onEvent: handleEvent))
        }

        private func handleEvent(_ event: MonitorReadoutEvent<Source>) {
            switch event {
            case .open(let admittedSource):
                if canBegin, admittedSource == source,
                    ownership.owner == nil, host.captureDrum == nil
                {
                    onTap()
                }
            case .preview(let preview):
                guard canBegin, ownership.owns(preview.id), preview.sourceIdentity == source,
                    let snapshot = preview.sourceIdentity.snapshot, snapshot.enabled,
                    host.captureDrum == nil || host.captureDrum?.id == preview.id
                else { return }
                host.captureSheet = nil
                host.captureDrum = CaptureDrumPresentation(
                    id: preview.id, sheet: sheet, snapshot: snapshot, position: preview.position)
            case .commit(let release, let revision):
                guard host.captureDrum?.id == release.id else { return }
                host.captureDrum = nil
                scheduleCommit(release, revision: revision)
            case .cancel(let identity):
                commitTask?.cancel()
                commitTask = nil
                if host.captureDrum?.id == identity { host.captureDrum = nil }
            }
        }

        private func scheduleCommit(_ release: MonitorReadoutValue<Source>, revision: UInt64) {
            let admittedSource = release.sourceIdentity
            let admittedWindow = windowGeometry
            guard canCommit, admittedSource == source,
                let snapshot = admittedSource.snapshot, snapshot.enabled,
                let value = release.changedValue
            else { return }
            commitTask?.cancel()
            commitTask = Task { @MainActor in
                if snapshot.delayed { try? await Task.sleep(for: .milliseconds(80)) }
                guard !Task.isCancelled, canCommit, admittedSource == source,
                    admittedWindow == windowGeometry, ownership.permitsDeferredCommit(revision),
                    host.captureDrum == nil
                else { return }
                commitTask = nil
                snapshot.apply(value, host: host)
            }
        }
    }

    public enum CaptureReadoutAdmission {
        public static func canBegin(
            locked: Bool, sessionLocked: Bool, sceneActive: Bool, operatorPanel: Bool
        ) -> Bool {
            !locked && !sessionLocked && sceneActive && !operatorPanel
        }

        public static func canCommit(canBegin: Bool, captureSheet: CaptureSheet?) -> Bool {
            canBegin && captureSheet == nil
        }

        public static func replacing(_ current: CaptureSheet?, with next: CaptureSheet)
            -> CaptureSheet?
        {
            current == next ? nil : next
        }

        /// Photo has no video FORMAT / COLOR sheet. Open shooting mode instead so the slot stays useful.
        public static func opening(_ sheet: CaptureSheet, isPhoto: Bool) -> CaptureSheet {
            guard isPhoto else { return sheet }
            switch sheet {
            case .resolution, .color: return .mode
            default: return sheet
            }
        }

        /// Persistent pickers follow the live mode. Video-only AUDIO closes; FORMAT / COLOR become MODE.
        public static func retained(_ sheet: CaptureSheet?, isPhoto: Bool) -> CaptureSheet? {
            guard let sheet else { return nil }
            if !isPhoto { return sheet }
            switch sheet {
            case .resolution, .color: return .mode
            case .audio: return nil
            default: return sheet
            }
        }

        /// A held video drum cannot remap to MODE mid-gesture; drop it on stills.
        public static func retainedDrum(_ sheet: CaptureSheet?, isPhoto: Bool) -> CaptureSheet? {
            guard let sheet else { return nil }
            if !isPhoto { return sheet }
            switch sheet {
            case .resolution, .color, .audio: return nil
            default: return sheet
            }
        }

        public static func hidesLowerCaptureValues(sheet: CaptureSheet?, drum: CaptureSheet?)
            -> Bool
        {
            if let drum { return !drum.isTopAnchored }
            if let sheet { return !sheet.isTopAnchored }
            return false
        }
    }
#endif
