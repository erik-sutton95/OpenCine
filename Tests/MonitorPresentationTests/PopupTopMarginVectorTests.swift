import Foundation
import MonitorPresentation
import Testing

/// The Swift half of `Fixtures/popup-top-margin.tsv`: every capture popup keeps one top margin.
/// Kotlin keeps the twin `MonitorLayoutPolicy.popupTopMargin` and reads the same rows
/// (`PopupTopMarginVectorTest`), so a popup opens at the same distance from the top everywhere.
@Suite struct PopupTopMarginVectorTests {
    static let rows: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MonitorPresentationTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/popup-top-margin.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    @Test func marginReadsTheSharedRule() throws {
        let rows = Self.rows.filter { $0.first == "margin" }
        #expect(rows.count > 5)
        for row in rows {
            let safeTop = try #require(Double(row[1]))
            #expect(MonitorCapturePopupLayout.topMargin(safeTop: safeTop) == Double(row[2]), "\(row)")
        }
    }

    @Test func landscapeDrawerAndTopPopupOpenAtTheMargin() throws {
        let rows = Self.rows.filter { $0.first == "landscape" }
        #expect(rows.count > 3)
        for row in rows {
            let width = try #require(Double(row[1]))
            let height = try #require(Double(row[2]))
            let safe = MonitorSafeArea(top: try #require(Double(row[3])))
            let tablet = min(width, height) >= 600
            let expected = try #require(Double(row[4]))
            let drawer = MonitorCapturePopupLayout(
                viewportWidth: width, viewportHeight: height, tablet: tablet, safeArea: safe)
            let top = MonitorCapturePopupLayout(
                viewportWidth: width, viewportHeight: height, tablet: tablet, safeArea: safe,
                edge: .top, topBoundary: 0)
            #expect(drawer.top == expected, "\(row)")
            #expect(top.top == expected, "\(row)")
        }
    }
}
