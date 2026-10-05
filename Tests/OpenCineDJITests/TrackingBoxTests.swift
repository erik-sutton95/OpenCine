import Foundation
import Testing

@testable import OpenCineDJI

@Suite struct TrackingBoxTests {
    @Test func setTrackingBoxMatchesMimoLayout() {
        let frame = Commands.setTrackingBox(
            id: 0x2726, x: 0.418, y: 0.525, width: 0.484, height: 0.461)
        #expect(frame.cmdSet == 0x02)
        #expect(frame.cmdId == 0xA6)
        #expect(frame.receiver == Duml.rxCamera)
        #expect(frame.flags == Duml.flagRequest)
        #expect(frame.payload.count == 21)
        #expect(Array(frame.payload.prefix(5)) == [0x01, 0x00, 0x00, 0x26, 0x27])
        #expect(Array(frame.payload[5..<9]) == floatLE(0.418))
        #expect(Array(frame.payload[9..<13]) == floatLE(0.525))
        #expect(Array(frame.payload[13..<17]) == floatLE(0.484))
        #expect(Array(frame.payload[17..<21]) == floatLE(0.461))
    }

    @Test func clearTrackingBoxIsTwentyOneZeros() {
        let frame = Commands.clearTrackingBox()
        #expect(frame.cmdId == 0xA6)
        #expect(frame.payload == [UInt8](repeating: 0, count: 21))
    }

    @Test func pollTrackingIsEmptyGet() {
        let frame = Commands.pollTracking()
        #expect(frame.cmdSet == 0x02)
        #expect(frame.cmdId == 0xA5)
        #expect(frame.payload == [0x00])
    }

    @Test func trackingPollParsesLockedAndIdle() {
        #expect(TrackingPoll.parse([0x00, 0x01, 0x00, 0x00]) == .locked(box: nil))
        #expect(TrackingPoll.parse([0x00, 0x00, 0x00, 0x00]) == .idle)
        #expect(TrackingPoll.parse([0x00]) == nil)
        #expect(TrackingPoll.parse([]) == nil)
    }

    @Test func livePushParsesMimoSubjectBox() throws {
        // /tmp/mimo-tracking-box-20260818.pcapng pkt#1 0x02/0x89 notify.
        let payload: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0xA0, 0x41,
            0x85, 0x10, 0x05, 0x3F, 0xC5, 0x4C, 0xC5, 0x3E,
            0xC0, 0x88, 0x3F, 0x3E, 0xCA, 0x30, 0xCA, 0x3E,
        ]
        let box = try #require(TrackingBox.parseLivePush(payload))
        // Wire is centre + size. Origin is centre − half extent.
        #expect(abs(box.width - 0.187) < 0.001)
        #expect(abs(box.height - 0.395) < 0.001)
        #expect(abs(box.centerX - 0.520) < 0.001)
        #expect(abs(box.centerY - 0.385) < 0.001)
        #expect(abs(box.x - (0.520 - 0.187 / 2)) < 0.001)
        #expect(abs(box.y - (0.385 - 0.395 / 2)) < 0.001)
    }

    @Test func livePushAcceptsAlternateHeaderTag() throws {
        // Same take, one `00 80 3f` header. Floats still at @7.
        let payload: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x3F,
            0xCE, 0x45, 0xCE, 0x3E, 0xD6, 0x9A, 0xD5, 0x3E,
            0xDE, 0x04, 0x5D, 0x3E, 0xD0, 0xB0, 0xD0, 0x3D,
        ]
        let box = try #require(TrackingBox.parseLivePush(payload))
        #expect(abs(box.centerX - 0.403) < 0.001)
        #expect(abs(box.height - 0.102) < 0.001)
    }

    @Test func livePushRejectsShortOrBadPrefix() {
        #expect(TrackingBox.parseLivePush([0x00, 0x01, 0x00, 0x00]) == nil)
        var bad = [UInt8](repeating: 0, count: 23)
        bad[0] = 0x01
        #expect(TrackingBox.parseLivePush(bad) == nil)
    }

    @Test func trackingPollReadsSubjectBoxWhenReplyCarriesFloats() {
        var payload: [UInt8] = [0x00, 0x01, 0x00, 0x00]
        payload += floatLE(0.40) + floatLE(0.30) + floatLE(0.18) + floatLE(0.22)
        let parsed = TrackingPoll.parse(payload)
        guard case .locked(let box) = parsed, let box else {
            Issue.record("expected locked subject box")
            return
        }
        #expect(abs(box.centerX - 0.40) < 0.0001)
        #expect(abs(box.centerY - 0.30) < 0.0001)
        #expect(abs(box.width - 0.18) < 0.0001)
        #expect(abs(box.height - 0.22) < 0.0001)
    }

    @Test func lensStateCarriesCameraFocusPoint() {
        // mimo-tap-focus-20260818 after tap (0.772, 0.483).
        let tapped: [UInt8] = [
            0xB1, 0xC6, 0xB5, 0x45, 0x3F, 0xF7, 0x14, 0xF7, 0x3E, 0x00, 0xD9, 0x00,
            0x2C, 0x0A, 0xD9, 0x00,
        ]
        let point = CamLensState.focusPoint(tapped)
        #expect(point != nil)
        #expect(abs((point?.x ?? 0) - 0.772) < 0.001)
        #expect(abs((point?.y ?? 0) - 0.483) < 0.001)
        let idle: [UInt8] = [
            0xB1, 0x00, 0xFF, 0xFF, 0x3E, 0x00, 0xFF, 0xFF, 0x3E, 0x00, 0xD9, 0x00,
        ]
        let centre = CamLensState.focusPoint(idle)
        #expect(abs((centre?.x ?? 0) - 0.5) < 0.002)
        #expect(abs((centre?.y ?? 0) - 0.5) < 0.002)
        #expect(CamLensState.focusPoint([0xB1]) == nil)
        #expect(
            CameraFocusPolicy.shouldAdopt(
                currentX: 0.50, currentY: 0.50, cameraX: 0.77, cameraY: 0.48))
        #expect(
            !CameraFocusPolicy.shouldAdopt(
                currentX: 0.772, currentY: 0.483, cameraX: 0.773, cameraY: 0.484))
        // A stale pre-tap point must not pull the fresh tap back.
        #expect(
            !CameraFocusPolicy.shouldAdopt(
                currentX: 0.77, currentY: 0.48, cameraX: 0.50, cameraY: 0.50, secondsSinceTap: 0.2))
        #expect(
            CameraFocusPolicy.shouldAdopt(
                currentX: 0.77, currentY: 0.48, cameraX: 0.50, cameraY: 0.50, secondsSinceTap: 2))

        var status = CameraStatus()
        #expect(
            CameraStatusDecoder.applySubscribePush(
                SubscribePush.pack(name: "cam_lens_state", value: tapped), to: &status))
        #expect(status.hasCameraFocusPoint)
        #expect(abs(status.focusX - 0.772) < 0.001)
        #expect(abs(status.focusY - 0.483) < 0.001)
        #expect(status.focusMode == .single)
    }

    private func floatLE(_ v: Float) -> [UInt8] {
        var le = v.bitPattern.littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }
}
