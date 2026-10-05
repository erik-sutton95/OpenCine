import Insta360Apple
import OpenCineCore
import XCTest

/// Time-of-day timecode for Luna live frames, pinned to the phone clock by earliest arrival.
final class LunaFrameTimecodeTests: XCTestCase {
    private func text(_ timecode: CameraTimecode?) -> String? {
        timecode.map {
            String(format: "%02d:%02d:%02d:%02d", $0.hours, $0.minutes, $0.seconds, $0.frames)
        }
    }

    func testTimeOfDayCountsFramesAtTheRecordingRateHalvedAbove30() {
        // 2026-09-30 08:51:10.54 UTC, Stockholm (UTC+2).
        let t = 1_790_758_270.54
        func at(_ unix: Double, _ zone: Int, _ fps: Int) -> String? {
            text(LunaFrameTimecode.timecode(unixSeconds: unix, timeZoneSeconds: zone, fps: fps))
        }
        XCTAssertEqual(at(t, 7200, 25), "10:51:10:13")
        XCTAssertEqual(at(t, 7200, 30), "10:51:10:16")
        XCTAssertEqual(at(t, 7200, 50), "10:51:10:13")
        XCTAssertEqual(at(t, 7200, 120), "10:51:10:16")
        XCTAssertEqual(at(t, 7200, 0), "10:51:10:13", "unknown rate counts 25s")
        // Wraps at midnight, west of GMT too.
        XCTAssertEqual(at(86_399.99, 0, 24), "23:59:59:23")
        XCTAssertEqual(at(3600, -7200, 24), "23:00:00:00")
        XCTAssertEqual(
            LunaFrameTimecode.timecode(unixSeconds: t, timeZoneSeconds: 0, fps: 25).dropFrame, false
        )
    }

    func testFramesPinToTheEarliestArrivalAndReportOncePerSecond() throws {
        var clock = LunaFrameTimecode()
        XCTAssertNil(clock.offset)
        // Frame stamped 100 s arrives at 1000.5: the offset is 900.5 less 90 ms of latency.
        let first = clock.note(frameClock: 100_000, arrival: 1000.5, timeZoneSeconds: 0, fps: 25)
        let offset = try XCTUnwrap(clock.offset)
        XCTAssertEqual(offset, 900.41, accuracy: 1e-9)
        XCTAssertEqual(text(first), "00:16:40:10")

        // Arrives later than the pinned frame (the network was slower): the offset holds, and the
        // same second reports nothing even though its frame count moved.
        XCTAssertNil(clock.note(frameClock: 100_300, arrival: 1001.2, timeZoneSeconds: 0, fps: 25))
        XCTAssertEqual(clock.offset, offset)
        let next = clock.note(frameClock: 100_700, arrival: 1001.5, timeZoneSeconds: 0, fps: 25)
        XCTAssertEqual(text(next), "00:16:41:02")

        // Arrives sooner than any frame before: re-pins earlier.
        XCTAssertNil(clock.note(frameClock: 101_000, arrival: 1001.3, timeZoneSeconds: 0, fps: 25))
        XCTAssertEqual(try XCTUnwrap(clock.offset), 900.21, accuracy: 1e-9)

        clock.reset()
        XCTAssertNil(clock.offset)
        XCTAssertEqual(
            text(clock.note(frameClock: 101_000, arrival: 1001.3, timeZoneSeconds: 0, fps: 25)),
            "00:16:41:05", "a reset reports the current second again")
    }
}
