import Foundation
import OpenCineGyro
import Testing

@testable import OpenCineCameraControls

@Suite struct GyroCopyTests {
    private static let statuses: [GyroTakeStatus] = [
        .recording, .mountMoved(offsetSeconds: 75), .cutShort, .smallGaps, .notCalibrated, .ready,
    ]

    /// Every string the shared gyro screens can show, except the Details sample rate.
    private static var primaryCopy: [String] {
        var all: [String] = [
            GyroCopy.pillArmed, GyroCopy.pillRecording, GyroCopy.pillSaving, GyroCopy.pillGaps,
            GyroCopy.pillError, GyroCopy.pillOffline, GyroCopy.pillMountMoved,
            GyroCopy.ibisTitle, GyroCopy.ibisReason, GyroCopy.ibisLens, GyroCopy.ibisTurnOff,
            GyroCopy.ibisKeep, GyroCopy.calibrateTitle, GyroCopy.calibrateBody, GyroCopy.getStarted,
            GyroCopy.useLastCalibration, GyroCopy.cancel, GyroCopy.stepCounter(1), GyroCopy.holdHint,
            GyroCopy.retry, GyroCopy.completeTitle, GyroCopy.completeBody, GyroCopy.done,
            GyroCopy.holdProgressA11y(25), GyroCopy.stepDoneA11y(1), GyroCopy.driftTitle,
            GyroCopy.driftQuestion, GyroCopy.recalibrate, GyroCopy.notNow, GyroCopy.logsTitle,
            GyroCopy.tip, GyroCopy.today, GyroCopy.yesterday, GyroCopy.select, GyroCopy.shareCount(2),
            GyroCopy.shareLog, GyroCopy.separator, GyroCopy.deleteTitle, GyroCopy.delete,
            GyroCopy.emptyTitle, GyroCopy.emptyBody, GyroCopy.turnOnGyro, GyroCopy.calibratedMount,
            GyroCopy.notCalibrated, GyroCopy.details, GyroCopy.startsLabel, GyroCopy.smoothnessLabel,
            GyroCopy.sampleRateLabel, GyroCopy.startOffset(0.12), GyroCopy.length(61),
            GyroCopy.settingsCalibrate, GyroCopy.phoneMount, GyroCopy.dismissTip,
        ]
        for kind in GyroPillKind.allCases {
            all.append(GyroCopy.pill(kind))
            all.append(GyroCopy.pillA11y(kind, warning: false))
            all.append(GyroCopy.pillA11y(kind, warning: true))
        }
        all += GyroRingStep.allCases.map(GyroCopy.step)
        all += [GyroCalibrationBlock.cameraDisconnected, .recording, .moving, .waitingForCamera]
            .map(GyroCopy.block)
        all += [GyroCalibrationInvalidation.cameraChanged, .recordingStarted, .connectionEnded]
            .map(GyroCopy.invalidation)
        all += statuses.flatMap { [GyroCopy.status($0), GyroCopy.verdict($0), GyroCopy.smoothness($0)] }
        all += GyroNotice.allCases.map(GyroCopy.notice)
        return all
    }

    @Test func noCopyContainsTheEmDash() {
        for text in Self.primaryCopy + [GyroCopy.sampleRate(200)] {
            #expect(!text.contains("\u{2014}"), "\(text)")
        }
    }

    @Test func noPrimaryCopyContainsDegreesOrMilliseconds() {
        for text in Self.primaryCopy {
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter })
            #expect(!text.contains("\u{00B0}"), "\(text)")
            #expect(!words.contains("deg") && !words.contains("degrees"), "\(text)")
            #expect(!words.contains("ms") && !words.contains("hz"), "\(text)")
        }
    }

    @Test func lengthAndOffsetFormatting() {
        #expect(GyroCopy.length(48.4) == "0:48")
        #expect(GyroCopy.length(130) == "2:10")
        #expect(GyroCopy.length(3725) == "62:05")
        #expect(GyroCopy.length(-3) == "0:00")
        #expect(GyroCopy.length(1e300) == "35791394:07")
        #expect(GyroCopy.length(-1e300) == "0:00")
        #expect(GyroCopy.startOffset(0.123) == "0.12 s before REC")
        #expect(GyroCopy.startOffset(-0.3) == "0.30 s after REC")
        #expect(GyroCopy.status(.mountMoved(offsetSeconds: 75)) == "Mount moved at 1:15")
        #expect(GyroCopy.sampleRate(199.6) == "200 Hz")
        #expect(GyroCopy.sampleRate(.nan) == "0 Hz")
        #expect(GyroCopy.sampleRate(.infinity) == "0 Hz")
        #expect(GyroCopy.sampleRate(1e300) == "2147483647 Hz")
        #expect(GyroCopy.sampleRate(-.infinity) == "0 Hz")
    }

    @Test func pillA11yAppendsTheIbisWarning() {
        #expect(GyroCopy.pillA11y(.armed, warning: true) == "Gyro armed. IBIS is still on")
        #expect(GyroCopy.pillA11y(.hidden, warning: true) == "")
    }

    @Test func sampleRateMatchesKotlinRoundingAndSaturation() {
        let cases: [(Double, String)] = [
            (.nan, "0 Hz"), (.infinity, "0 Hz"), (-.infinity, "0 Hz"),
            (.greatestFiniteMagnitude, "2147483647 Hz"),
            (-.greatestFiniteMagnitude, "-2147483648 Hz"),
            (2147483646.5, "2147483647 Hz"), (-2147483648.5, "-2147483648 Hz"),
            (199.5, "200 Hz"), (-199.5, "-199 Hz"),
            (0.5, "1 Hz"), (-0.5, "0 Hz"), (-0.5000001, "-1 Hz"),
            (Double(0.5).nextDown, "0 Hz"), (Double(-0.5).nextUp, "0 Hz"),
            (0, "0 Hz"),
        ]
        for (rate, expected) in cases {
            #expect(GyroCopy.sampleRate(rate) == expected, "rate: \(rate)")
        }
    }

    @Test func verdictLeadsWithReadyForGyroflow() {
        #expect(GyroCopy.verdict(.ready) == "Ready for Gyroflow")
        #expect(GyroCopy.verdict(.recording) == "Still recording")
        #expect(GyroCopy.verdict(.smallGaps) == "Small gaps")
    }
}
