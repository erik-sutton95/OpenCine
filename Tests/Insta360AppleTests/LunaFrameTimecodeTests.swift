import Insta360Apple
import OpenCineCore
import XCTest

/// Time-of-day timecode for Luna live frames, pinned to the phone clock by earliest arrival.
final class LunaFrameTimecodeTests: XCTestCase {
    private func text(_ timecode: CameraTimecode?) -> String? {
        timecode.map {
            XCTAssertNil($0.frames, "seconds precision: no frame field is invented")
            return String(format: "%02d:%02d:%02d", $0.hours, $0.minutes, $0.seconds)
        }
    }

    func testTimeOfDayIsWholeSecondsWithNoDerivedFrames() {
        // 2026-09-30 08:51:10.54 UTC, Stockholm (UTC+2).
        let t = 1_790_758_270.54
        func at(_ unix: Double, _ zone: Int) -> String? {
            text(LunaFrameTimecode.timecode(unixSeconds: unix, timeZoneSeconds: zone))
        }
        XCTAssertEqual(at(t, 7200), "10:51:10")
        // Wraps at midnight, west of GMT too.
        XCTAssertEqual(at(86_399.99, 0), "23:59:59")
        XCTAssertEqual(at(3600, -7200), "23:00:00")
        let value = LunaFrameTimecode.timecode(unixSeconds: t, timeZoneSeconds: 0)
        XCTAssertNil(value.frames)
        XCTAssertNil(value.dropFrame, "a seconds-only source does not claim a frame count mode")
    }

    func testFramesPinToTheEarliestArrivalAndReportOncePerSecond() throws {
        var clock = LunaFrameTimecode()
        XCTAssertNil(clock.offset)
        // Frame stamped 100 s arrives at 1000.5: the offset is 900.5 less 90 ms of latency.
        let first = clock.note(frameClock: 100_000, arrival: 1000.5, timeZoneSeconds: 0)
        let offset = try XCTUnwrap(clock.offset)
        XCTAssertEqual(offset, 900.41, accuracy: 1e-9)
        XCTAssertEqual(text(first), "00:16:40")

        // Arrives later than the pinned frame (the network was slower): the offset holds, and the
        // same second reports nothing.
        XCTAssertNil(clock.note(frameClock: 100_300, arrival: 1001.2, timeZoneSeconds: 0))
        XCTAssertEqual(clock.offset, offset)
        let next = clock.note(frameClock: 100_700, arrival: 1001.5, timeZoneSeconds: 0)
        XCTAssertEqual(text(next), "00:16:41")

        // Arrives sooner than any frame before: re-pins earlier.
        XCTAssertNil(clock.note(frameClock: 101_000, arrival: 1001.3, timeZoneSeconds: 0))
        XCTAssertEqual(try XCTUnwrap(clock.offset), 900.21, accuracy: 1e-9)

        clock.reset()
        XCTAssertNil(clock.offset)
        XCTAssertEqual(
            text(clock.note(frameClock: 101_000, arrival: 1001.3, timeZoneSeconds: 0)),
            "00:16:41", "a reset reports the current second again")
    }
}
