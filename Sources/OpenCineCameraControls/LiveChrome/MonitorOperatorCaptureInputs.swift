#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineCore

// Existing camera-controls entry points retain their public names after moving the values below composition.
public typealias MonitorOperatorLiveReadout<Key: Hashable, Section: Hashable> = OpenCineAppKit.MonitorOperatorLiveReadout<Key, Section>
public typealias MonitorOperatorCameraPanel<Key: Hashable> = OpenCineAppKit.MonitorOperatorCameraPanel<Key>
public typealias MonitorOperatorCameraPanelChrome = OpenCineAppKit.MonitorOperatorCameraPanelChrome

/// The legacy adapter captures the exact native source previously held by its readout recognizer.
public struct MonitorOperatorLegacyCaptureIdentity: Hashable, Sendable {
    public let camera: UUID?
    public let phase: String
    public let sheet: CaptureSheet
    public let snapshot: CaptureQuickSnapshot
    public init(camera: UUID?, phase: String, sheet: CaptureSheet, snapshot: CaptureQuickSnapshot) {
        self.camera = camera; self.phase = phase; self.sheet = sheet; self.snapshot = snapshot
    }
}

extension MonitorOperatorCaptureInputs where Key == CaptureSheet, NativeIdentity == MonitorOperatorLegacyCaptureIdentity {
    /// Translate actual reported values and existing native snapshots; this adapter renders no chrome.
    @MainActor public static func captureSheetHost<Host: CaptureSheetHost>(_ host: Host,
        section: Section? = nil, columns: Int? = nil,
        presentedSheet: (() -> CaptureSheet?)? = nil,
        open: ((CaptureSheet) -> Void)? = nil, dismiss: (() -> Void)? = nil) -> Self {
        let status = host.cameraStatus
        let controls = host.controlCapabilities
        var readouts: [MonitorOperatorLiveReadout<CaptureSheet, Section>] = []
        func append(_ sheet: CaptureSheet, _ title: String, _ value: String,
            field: MonitorCaptureField? = nil, icon: MonitorIcon? = nil, badge: MonitorIcon? = nil,
            quickEnabled: Bool = true, marked: Set<String> = []) {
            readouts.append(.init(id: sheet, title: title, value: value, section: section,
                field: field, valueIcon: icon, badgeIcon: badge, quickEnabled: quickEnabled,
                accessibilityIdentifier: "monitor.capture.\(sheet.rawValue)", marked: marked))
        }
        let selection: MonitorCaptureSelection = host.captureStripShowsPendingEdits ? .pending : .reported
        func commonValue(_ key: SettingKey) -> String {
            host.control.captureValue(key, selection: selection).map(MonitorCapturePresentation.label) ?? "--"
        }
        let nativeISO = status.isoIndex == .auto && controls.nativeISO.ceiling == true
        let isoField = nativeISO ? nil : host.control.captureField(.iso, selection: selection)
        // The ISO drum stars the curve's native ISO whichever source owns it.
        append(.iso, "ISO", commonValue(.iso), field: isoField,
            quickEnabled: nativeISO || isoField != nil, marked: CaptureLists.isoMarkedLabels(from: status))
        // One rule for the tile and its panel: the common program, else the native report.
        let automatic = host.control.snapshot?.exposureProgram.value == .automatic || status.expoMode == .auto
        if automatic {
            append(.shutter, MonitorExposureReadout.autoEvCaption(shutterDenom: status.shutterDenom),
                host.captureRouting.commonExposureCompensation ? commonValue(.exposureCompensation) : status.evComp?.label ?? "--",
                badge: host.facePriorityExposureEnabled ? CaptureLists.facePriorityBadgeIcon : nil)
        } else {
            let nativeAngle = host.shutterUsesAngle && !status.isPhoto
            let field = nativeAngle ? nil : host.control.captureField(.shutter, selection: selection)
            append(.shutter, "SHUTTER", nativeAngle ? host.shutterAngleReadout(selection: selection).value
                : commonValue(.shutter), field: field,
                quickEnabled: nativeAngle || field != nil)
        }
        let exposure = host.autoExposureLocked ? CaptureLists.aeLock : host.control.snapshot?.exposureProgram.value.map(MonitorCapturePresentation.exposureProgram) ?? "--"
        append(.exposure, "EXPOSURE", exposure)
        let pendingWB = host.captureStripShowsPendingEdits && status.whiteBalance?.mode == .custom && !host.autoWhiteBalanceLocked
        let wbField = pendingWB ? host.control.captureField(.whiteBalance, selection: selection)?.kelvinScrub : nil
        let wbValue = host.autoWhiteBalanceLocked ? CaptureLists.awbLockTile : commonValue(.whiteBalance)
        let wbIcon: MonitorIcon?
        if case .whiteBalance(.auto)? = host.control.captureValue(.whiteBalance, selection: selection) {
            wbIcon = host.autoWhiteBalanceLocked ? nil : .aperture
        } else { wbIcon = nil }
        append(.wb, "WB", wbValue, field: wbField,
            icon: wbIcon,
            quickEnabled: !pendingWB || wbField != nil)
        if controls.focus.isOffered {
            let commonFocus: OpenCineCore.FocusMode?
            if case .focusMode(let value)? = host.control.captureValue(.focusMode, selection: selection) {
                commonFocus = value
            } else { commonFocus = nil }
            append(.focus, "FOCUS", CaptureNativeReadoutPresentation.focus(common: commonFocus,
                native: FocusOption.resolve(mode: status.focusMode, track: status.focusTrack)))
        }
        if controls.iris.isOffered {
            let iris: Double?
            if case .aperture(let value)? = host.control.captureValue(.aperture, selection: selection) { iris = value } else { iris = nil }
            append(.aperture, "APERTURE", CaptureNativeReadoutPresentation.aperture(
                common: iris, strategy: status.apertureStrategy))
        }
        if controls.audio.isOffered && !status.isPhoto { append(.audio, "AUDIO", status.audioChannel?.label ?? "\u{2014}") }
        let supplementary: [MonitorOperatorSupplementaryCaptureReadout<CaptureSheet, Section>]
        if let meter = host.nativeMeteringSource {
            supplementary = [.metering(meter, section: section)]
        } else { supplementary = [] }
        let presented = presentedSheet.map { $0() } ?? host.captureSheet
        let panel = presented.map { sheet in
            let ev = sheet == .shutter && automatic
            return MonitorOperatorCameraPanel(key: sheet, top: sheet.isTopAnchored, chrome: .content,
                title: ev ? "EXPOSURE" : sheet.headerLabel,
                subtitle: ev ? "Compensation" : sheet == .shutter ? host.shutterPanelSubtitle(selection: selection)
                    : sheet == .resolution && status.isPhoto ? "Photo" : sheet.subtitle)
        }
        var ownedPreview: UUID?
        return Self(readouts: readouts, panel: panel,
            columns: columns, haptics: host.hapticsEnabled,
            open: { sheet in
                guard !host.sessionLocked, !host.operatorPanelOpen, !host.coverOpen, host.captureDrum == nil else { return }
                if let open { open(sheet); return }
                host.captureSheet = CaptureReadoutAdmission.replacing(host.captureSheet,
                    with: CaptureReadoutAdmission.opening(sheet, isPhoto: host.cameraStatus.isPhoto))
            }, dismiss: { if let dismiss { dismiss() } else { host.captureSheet = nil } }, isTop: { $0.isTopAnchored }, nativeQuick: { sheet in
                guard let snapshot = host.quickSnapshot(sheet) else { return nil }
                return .init(identity: .init(camera: host.connectedCameraID, phase: host.sessionPhaseLabel,
                    sheet: sheet, snapshot: snapshot), snapshot: snapshot.display,
                    enabled: snapshot.enabled, delayed: snapshot.delayed)
            }, nativeCurrent: { sheet, identity in
                identity.camera == host.connectedCameraID && identity.phase == host.sessionPhaseLabel
                    && identity.sheet == sheet && identity.snapshot == host.quickSnapshot(sheet)
            }, nativeCommit: { sheet, identity, value in
                guard identity.sheet == sheet else { return }
                identity.snapshot.apply(value, host: host)
            }, previewChanged: { sheet, preview in
                if let preview {
                    let snapshot = preview.native?.snapshot ?? preview.field.map(CaptureQuickSnapshot.common)
                    guard let snapshot else { return }
                    ownedPreview = preview.id
                    host.captureDrum = .init(id: preview.id, sheet: sheet, snapshot: snapshot, position: preview.position)
                } else {
                    if let ownedPreview, host.captureDrum?.id == ownedPreview { host.captureDrum = nil }
                    ownedPreview = nil
                }
            }, commitAdmission: {
                !host.sessionLocked && !host.operatorPanelOpen && !host.coverOpen && host.captureSheet == nil
                    && (presentedSheet == nil || presentedSheet?() == nil)
            }, presentationOwner: { host.captureDrum?.id }, supplementaryReadouts: supplementary)
    }
}
extension MonitorOperatorSupplementaryCaptureReadout where Key == CaptureSheet {
    /// The face-priority metering toggle beside EXPOSURE: two values, so it switches in place.
    /// It speaks its full name and what a tap does, not the visual caption.
    @MainActor static func metering(_ meter: CaptureNativeMeteringSource, section: Section?) -> Self {
        .init(id: "native.metering", after: .exposure, title: "METER",
            value: meter.face.map { $0 ? "Face" : "Matrix" } ?? "--", accessibilityLabel: "Metering",
            accessibilityValue: meter.face.map { $0 ? "Face Priority" : "Matrix" } ?? "Unknown",
            accessibilityHint: "Switches between Matrix and Face Priority metering",
            accessibilityIdentifier: "monitor.capture.metering", section: section,
            enabled: meter.face != nil, isCurrent: meter.isCurrent,
            action: { if let face = meter.face { meter.setFace(!face) } })
    }
}
#endif
