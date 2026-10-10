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
        let capabilities = host.captureCapabilities
        var readouts: [MonitorOperatorLiveReadout<CaptureSheet, Section>] = []
        func append(_ sheet: CaptureSheet, _ title: String, _ value: String,
            field: MonitorCaptureField? = nil, icon: MonitorIcon? = nil, badge: MonitorIcon? = nil,
            quickEnabled: Bool = true) {
            readouts.append(.init(id: sheet, title: title, value: value, section: section,
                field: field, valueIcon: icon, badgeIcon: badge, quickEnabled: quickEnabled,
                accessibilityIdentifier: "monitor.capture.\(sheet.rawValue)"))
        }
        let pendingISO = host.captureStripShowsPendingEdits && !(status.isoIndex == .auto && capabilities.isoLimit)
        let iso = status.isoIndex == .auto ? "Auto" : status.iso > 0 ? "\(status.iso)" : status.isoIndex?.label ?? "\u{2014}"
        let isoField = pendingISO ? host.control.captureField(.iso) : nil
        append(.iso, "ISO", pendingISO ? isoField?.label ?? "--" : iso, field: isoField,
            quickEnabled: !pendingISO || isoField != nil)
        if status.expoMode == .auto {
            append(.shutter, MonitorExposureReadout.autoEvCaption(shutterDenom: status.shutterDenom),
                status.evComp?.label ?? "\u{2014}", badge: host.facePriorityExposureEnabled ? CaptureLists.facePriorityBadgeIcon : nil)
        } else {
            let pendingShutter = host.captureStripShowsPendingEdits && !(host.shutterUsesAngle && !status.isPhoto)
            let field = pendingShutter ? host.control.captureField(.shutter) : nil
            append(.shutter, "SHUTTER", pendingShutter ? field?.label ?? "--" : CaptureQuickSnapshot.shutterReadout(
                status: status, shutterUsesAngle: host.shutterUsesAngle, shutterAngleDegrees: host.shutterAngleDegrees), field: field,
                quickEnabled: !pendingShutter || field != nil)
        }
        let exposure = host.autoExposureLocked ? CaptureLists.aeLock : status.expoMode == .manual ? "M" : status.expoMode == .auto ? "A" : "\u{2014}"
        append(.exposure, "EXPOSURE", exposure)
        let pendingWB = host.captureStripShowsPendingEdits && status.whiteBalance?.mode == .custom && !host.autoWhiteBalanceLocked
        let wbField = pendingWB ? host.control.captureField(.whiteBalance) : nil
        let displayedWB = host.displayStatus
        let wbValue: String
        if host.autoWhiteBalanceLocked { wbValue = CaptureLists.awbLockTile }
        else if let wb = displayedWB.whiteBalance {
            wbValue = wb.mode == .custom ? (displayedWB.whiteBalanceKelvin > 0 ? "\(displayedWB.whiteBalanceKelvin)K" : "Custom") : "Auto"
        } else { wbValue = "\u{2014}" }
        append(.wb, "WB", pendingWB ? wbField?.label ?? "--" : wbValue, field: wbField,
            icon: displayedWB.whiteBalance?.mode == .custom ? nil : .aperture,
            quickEnabled: !pendingWB || wbField != nil)
        if capabilities.focusMode {
            append(.focus, "FOCUS", FocusOption.resolve(mode: status.focusMode, track: status.focusTrack)?.chip ?? "\u{2014}")
        }
        if capabilities.aperture {
            append(.aperture, "APERTURE", status.irisHundredths.map(ApertureStrategy.fNumberLabel(hundredths:))
                ?? status.apertureStrategy?.label ?? "\u{2014}")
        }
        if capabilities.audio && !status.isPhoto { append(.audio, "AUDIO", status.audioChannel?.label ?? "\u{2014}") }
        let visibleCount = 4 + (capabilities.faceMetering ? 1 : 0) + (capabilities.focusMode ? 1 : 0)
            + (capabilities.aperture ? 1 : 0) + (capabilities.audio && !status.isPhoto ? 1 : 0)
        let presented = presentedSheet.map { $0() } ?? host.captureSheet
        let panel = presented.map { sheet in
            let ev = sheet == .shutter && status.expoMode == .auto
            return MonitorOperatorCameraPanel(key: sheet, top: sheet.isTopAnchored, chrome: .content,
                title: ev ? "EXPOSURE" : sheet.headerLabel,
                subtitle: ev ? "Compensation" : sheet == .shutter ? (status.isPhoto ? "Speed" : "Angle · speed")
                    : sheet == .resolution && status.isPhoto ? "Photo" : sheet.subtitle)
        }
        var ownedPreview: UUID?
        return Self(readouts: readouts, panel: panel,
            columns: columns == 3 ? 3 : max(1, visibleCount), haptics: host.hapticsEnabled,
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
            }, presentationOwner: { host.captureDrum?.id })
    }
}
#endif
