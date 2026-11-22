import Foundation
import MonitorPresentation
import Testing

struct MonitorReferenceLayoutTests {
    @Test func compatiblePreviewAndProxy() {
        #expect(MonitorReferenceLayout.matches(saved: 1920.0 / 1080, live: 1280.0 / 720))
        #expect(!MonitorReferenceLayout.matches(saved: 16.0 / 9, live: 4.0 / 3))
        #expect(!MonitorReferenceLayout.matches(saved: .infinity, live: 16.0 / 9))
    }

    @Test func splitStaysOnTheLeftWhenTheFeedRotates() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        #expect(
            MonitorReferenceLayout.splitRect(in: rect, fraction: 0.25, clockwiseTurns: 0)
                == CGRect(x: 10, y: 20, width: 50, height: 100))
        #expect(
            MonitorReferenceLayout.splitRect(in: rect, fraction: 0.25, clockwiseTurns: 1)
                == CGRect(x: 10, y: 95, width: 200, height: 25))
        #expect(
            MonitorReferenceLayout.splitRect(in: rect, fraction: 0.25, clockwiseTurns: -1)
                == CGRect(x: 10, y: 20, width: 200, height: 25))
        #expect(
            MonitorReferenceLayout.fraction(at: CGPoint(x: 10, y: 95), in: rect, clockwiseTurns: 1)
                == 0.25)
    }
}
