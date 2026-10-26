import Foundation
import OpenCineGyro
import Testing

@testable import OpenCineCameraControls

/// Task 5 of Plan 3: the shared gyro screens read one copy table on both platforms. Android's
/// `GyroCopy.kt` must carry every fixed text of this Swift table as its own Kotlin literal, so the
/// parity test reads the Kotlin file through `#filePath` and checks the quotes around each text
/// (modeled on `MonitorSettingsCopyParityTests`).
struct GyroCopyParityTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let kotlinPath =
        "Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/gyro/GyroCopy.kt"

    private static func kotlin() throws -> String {
        try String(contentsOf: Self.root.appending(path: Self.kotlinPath), encoding: .utf8)
    }

    private static let statuses: [GyroTakeStatus] = [
        .recording, .mountMoved(offsetSeconds: 75), .cutShort, .smallGaps, .notCalibrated, .ready,
    ]

    /// Every fixed `GyroCopy` static value, read from the Swift table itself.
    private static var fixedTexts: [String] {
        [
            GyroCopy.pillArmed, GyroCopy.pillRecording, GyroCopy.pillSaving, GyroCopy.pillGaps,
            GyroCopy.pillError, GyroCopy.pillOffline, GyroCopy.pillMountMoved,
            GyroCopy.ibisTitle, GyroCopy.ibisReason, GyroCopy.ibisLens, GyroCopy.ibisTurnOff,
            GyroCopy.ibisKeep, GyroCopy.calibrateTitle, GyroCopy.calibrateBody, GyroCopy.getStarted,
            GyroCopy.useLastCalibration, GyroCopy.cancel, GyroCopy.holdHint, GyroCopy.retry,
            GyroCopy.completeTitle, GyroCopy.completeBody, GyroCopy.done, GyroCopy.driftTitle,
            GyroCopy.driftQuestion, GyroCopy.recalibrate, GyroCopy.notNow, GyroCopy.logsTitle,
            GyroCopy.tip, GyroCopy.today, GyroCopy.yesterday, GyroCopy.select, GyroCopy.shareLog,
            GyroCopy.separator, GyroCopy.deleteTitle, GyroCopy.delete, GyroCopy.emptyTitle,
            GyroCopy.emptyBody, GyroCopy.turnOnGyro, GyroCopy.calibratedMount,
            GyroCopy.notCalibrated, GyroCopy.details, GyroCopy.startsLabel,
            GyroCopy.smoothnessLabel, GyroCopy.sampleRateLabel, GyroCopy.settingsCalibrate, GyroCopy.phoneMount, GyroCopy.dismissTip,
        ]
    }

    /// The switch-style functions return whole literals; the parameterized ones are checked by
    /// their fixed parts in the second test.
    private static var functionTexts: [String] {
        var texts = GyroPillKind.allCases.flatMap {
            [GyroCopy.pill($0), GyroCopy.pillA11y($0, warning: false)]
        }
        texts += GyroRingStep.allCases.map(GyroCopy.step)
        texts += [GyroCalibrationBlock.cameraDisconnected, .recording, .moving, .waitingForCamera]
            .map(GyroCopy.block)
        texts += [GyroCalibrationInvalidation.cameraChanged, .recordingStarted, .connectionEnded]
            .map(GyroCopy.invalidation)
        texts += Self.statuses.filter {
            if case .mountMoved = $0 { return false }
            return true
        }.flatMap { [GyroCopy.status($0), GyroCopy.verdict($0), GyroCopy.smoothness($0)] }
        texts.append(GyroCopy.smoothness(.mountMoved(offsetSeconds: 75)))
        texts += GyroNotice.allCases.map(GyroCopy.notice)
        return texts.filter { !$0.isEmpty }
    }

    @Test func everyFixedTextIsAQuotedKotlinLiteral() throws {
        let kotlin = try Self.kotlin()
        for text in Self.fixedTexts + Self.functionTexts {
            #expect(kotlin.contains("\"\(text)\""), "\(text)")
        }
    }

    /// Interpolated functions keep each fixed part as its own literal, as in `"Step " + n + " of 3"`.
    @Test func everyInterpolatedFixedPartIsAQuotedKotlinLiteral() throws {
        let kotlin = try Self.kotlin()
        for part in [
            ". IBIS is still on", "Step ", " of 3", "Holding, ", " percent", " done",
            "Share (", ")", "Mount moved at ", " s before REC", " s after REC", " Hz", ":", "0",
        ] {
            #expect(kotlin.contains("\"\(part)\""), "\(part)")
        }
    }
}
