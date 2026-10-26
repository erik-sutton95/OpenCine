import Foundation
import Testing

@testable import OpenCineGyro

@Suite struct GyroDriftDetectorTests {
    private static let cameraDown = GyroVector3(x: -1, y: 0, z: 0)
    private static let leftAxis = GyroVector3(x: 0, y: 1, z: 0)
    private static let mountAxis = GyroVector3(x: 0.3, y: -0.5, z: 0.8)
    private static let mountDegrees = 37.0

    /// Aligned reading: the phone sees the camera down through the mount rotation.
    private static func alignedPhoneDown() -> GyroVector3 {
        GyroTestRig.rotate(cameraDown, axis: mountAxis, degrees: mountDegrees)
    }

    /// Tilted reading: rotate the camera-frame down first, then apply the mount rotation.
    private static func tiltedPhoneDown(degrees: Double) -> GyroVector3 {
        let tiltedCamera = GyroTestRig.rotate(cameraDown, axis: leftAxis, degrees: degrees)
        return GyroTestRig.rotate(tiltedCamera, axis: mountAxis, degrees: mountDegrees)
    }

    private static func reading(
        step: Int, phoneDown: GyroVector3, rotationRate: Double = 0, accelerationG: Double = 1
    ) -> GyroDriftReading {
        GyroDriftReading(
            timestamp: Double(step) * 0.02, phoneDown: phoneDown, rotationRate: rotationRate,
            accelerationG: accelerationG)
    }

    @Test func sustainedSteadyDisagreementConfirmsOnceAfterOneSecond() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let aligned = Self.alignedPhoneDown()
        #expect(calibration.mapping(aligned).angle(to: Self.cameraDown) < 0.01)
        let tilted = Self.tiltedPhoneDown(degrees: 3)
        #expect(abs(calibration.mapping(tilted).angle(to: Self.cameraDown) - 3) < 0.01)

        var detector = GyroDriftDetector(calibration: calibration)
        #expect(!detector.hasDrifted)
        var confirmations = 0
        for step in 0...100 {
            detector.observeCamera(
                down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(Self.reading(step: step, phoneDown: tilted))
            if step < 50 {
                #expect(!confirmed, "confirmed before one second at step \(step)")
                #expect(!detector.hasDrifted)
            } else if step == 50 {
                #expect(confirmed)
                #expect(detector.hasDrifted)
                confirmations += 1
            } else {
                #expect(!confirmed)
                #expect(detector.hasDrifted)
            }
        }
        #expect(confirmations == 1)
    }

    @Test func belowThresholdNeverConfirms() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let phoneDown = Self.tiltedPhoneDown(degrees: 2.4)
        #expect(
            calibration.mapping(phoneDown).angle(to: Self.cameraDown)
                < GyroDriftDetector.thresholdDegrees)
        var detector = GyroDriftDetector(calibration: calibration)
        for step in 0...250 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(Self.reading(step: step, phoneDown: phoneDown))
            #expect(!confirmed)
        }
        #expect(!detector.hasDrifted)
    }

    @Test func movingReadingsAreIgnored() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let phoneDown = Self.tiltedPhoneDown(degrees: 10)
        var detector = GyroDriftDetector(calibration: calibration)
        for step in 0...250 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(
                Self.reading(step: step, phoneDown: phoneDown, rotationRate: 0.2))
            #expect(!confirmed)
        }
        #expect(!detector.hasDrifted)
    }

    @Test func accelerationAwayFromOneGIsNotSteady() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let phoneDown = Self.tiltedPhoneDown(degrees: 10)
        var detector = GyroDriftDetector(calibration: calibration)
        for step in 0...250 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(
                Self.reading(step: step, phoneDown: phoneDown, accelerationG: 1.1))
            #expect(!confirmed)
        }
        #expect(!detector.hasDrifted)
    }

    @Test func agreementResetsTheRun() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let aligned = Self.alignedPhoneDown()
        let tilted = Self.tiltedPhoneDown(degrees: 3)
        var detector = GyroDriftDetector(calibration: calibration)
        var confirmations = 0
        for step in 0...40 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            if detector.observePhone(Self.reading(step: step, phoneDown: tilted)) {
                confirmations += 1
            }
        }
        detector.observeCamera(down: Self.cameraDown, at: 41 * 0.02)
        let agreed = detector.observePhone(Self.reading(step: 41, phoneDown: aligned))
        #expect(!agreed)
        #expect(!detector.hasDrifted)
        for step in 42...82 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(Self.reading(step: step, phoneDown: tilted))
            #expect(!confirmed)
        }
        #expect(confirmations == 0)
        #expect(!detector.hasDrifted)
    }

    @Test func staleCameraReadingNeverConfirmsDrift() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let phoneDown = Self.tiltedPhoneDown(degrees: 3)
        var detector = GyroDriftDetector(calibration: calibration)
        detector.observeCamera(down: Self.cameraDown, at: 0)
        for step in 0...150 {
            let confirmed = detector.observePhone(Self.reading(step: step, phoneDown: phoneDown))
            #expect(!confirmed)
        }
        #expect(!detector.hasDrifted)
    }

    @Test func gapBetweenSteadyReadingsRestartsTheRun() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let phoneDown = Self.tiltedPhoneDown(degrees: 3)
        var detector = GyroDriftDetector(calibration: calibration)
        for step in 0...30 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(Self.reading(step: step, phoneDown: phoneDown))
            #expect(!confirmed)
        }
        for step in 45...70 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(Self.reading(step: step, phoneDown: phoneDown))
            #expect(!confirmed)
        }
        #expect(!detector.hasDrifted)
    }

    @Test func resetClearsDriftedState() throws {
        let calibration = try GyroTestRig.solvedCalibration()
        let phoneDown = Self.tiltedPhoneDown(degrees: 3)
        var detector = GyroDriftDetector(calibration: calibration)
        for step in 0...50 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            let confirmed = detector.observePhone(Self.reading(step: step, phoneDown: phoneDown))
            if step == 50 { #expect(confirmed) } else { #expect(!confirmed) }
        }
        #expect(detector.hasDrifted)

        detector.reset()
        #expect(!detector.hasDrifted)
        let ignoredWithoutCamera = detector.observePhone(
            Self.reading(step: 51, phoneDown: phoneDown))
        #expect(!ignoredWithoutCamera)

        var confirmations = 0
        for step in 51...101 {
            detector.observeCamera(down: Self.cameraDown, at: Double(step) * 0.02)
            if detector.observePhone(Self.reading(step: step, phoneDown: phoneDown)) {
                confirmations += 1
                #expect(step == 101)
            }
        }
        #expect(confirmations == 1)
        #expect(detector.hasDrifted)
    }
}
