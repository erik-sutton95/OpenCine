import Foundation
import OpenCineGyro
import Testing

@testable import OpenCineCameraControls

@Suite struct GyroRingModelTests {
    /// A calibration with an identity rotation, decoded because the type has no public init.
    static func calibration() throws -> GyroMountCalibration {
        let json = """
            {"rotation":[{"x":1,"y":0,"z":0},{"x":0,"y":1,"z":0},{"x":0,"y":0,"z":1}],\
            "validationErrorDegrees":0.5,"separationDegrees":30}
            """
        return try JSONDecoder().decode(GyroMountCalibration.self, from: Data(json.utf8))
    }

    @Test func introIsEmpty() {
        let model = GyroRingModel.make(.intro)
        #expect(model.litFraction == 0)
        #expect(!model.dimmed)
        #expect(!model.checkmark)
        #expect(model.litTicks == 0)
    }

    @Test func holdFillsTheRing() {
        #expect(GyroRingModel.make(.posing(step: .level, inZone: false, hold: 0.9)).litFraction == 0.15)
        #expect(GyroRingModel.make(.posing(step: .level, inZone: true, hold: 0)).litFraction == 0.15)
        let half = GyroRingModel.make(.posing(step: .tiltUp, inZone: true, hold: 0.5))
        #expect(abs(half.litFraction - 0.575) < 1e-9)
        let full = GyroRingModel.make(.posing(step: .tiltUp, inZone: true, hold: 1))
        #expect(full.litFraction == 1)
        #expect(full.litTicks == 60)
        #expect(!full.checkmark)
    }

    @Test func blockedDims() {
        let model = GyroRingModel.make(.blocked(step: .level, reason: .moving))
        #expect(model.dimmed)
        #expect(!model.checkmark)
        #expect(GyroRingModel.make(.invalidated(.cameraChanged)).dimmed)
    }

    @Test func completeShowsTheCheckmark() throws {
        let model = GyroRingModel.make(.complete(try Self.calibration()))
        #expect(model.litFraction == 1)
        #expect(model.checkmark)
        #expect(!model.dimmed)
    }

    @Test func holdMilestonesAnnounceOncePerCrossing() {
        #expect(GyroHoldMilestones.bucket(0.24) == 0)
        #expect(GyroHoldMilestones.bucket(0.25) == 25)
        #expect(GyroHoldMilestones.bucket(0.8) == 75)
        #expect(GyroHoldMilestones.crossing(previousBucket: 0, hold: 0.3) == 25)
        #expect(GyroHoldMilestones.crossing(previousBucket: 25, hold: 0.4) == nil)
        #expect(GyroHoldMilestones.crossing(previousBucket: 75, hold: 0.1) == nil)
        #expect(GyroHoldMilestones.crossing(previousBucket: 0, hold: 0.6) == 50)
    }
}
