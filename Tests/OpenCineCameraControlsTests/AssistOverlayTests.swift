#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineMedia
    import XCTest

    @testable import OpenCineCameraControls

    /// Pins GRID to OpenZCine `AssistConfiguration.Grid` + `FeedGridView` (no fourths).
    final class GridAssistTests: XCTestCase {
        func testLongPressOptionsMatchOpenZCine() {
            XCTAssertEqual(
                MonitorGridOption.allCases.map(\.rawValue),
                ["Thirds", "Phi Grid", "Diagonal"]
            )
        }

        func testThirdsSegmentsCrossTheFeed() {
            let feed = CGRect(x: 10, y: 20, width: 900, height: 600)
            let lines = GridAssist.segments(in: feed, thirds: true, phi: false, diagonal: false)
            XCTAssertEqual(lines.count, 4)
            XCTAssertEqual(lines[0].from, CGPoint(x: 310, y: 20))
            XCTAssertEqual(lines[0].to, CGPoint(x: 310, y: 620))
            XCTAssertEqual(lines[1].from, CGPoint(x: 10, y: 220))
            XCTAssertEqual(lines[1].to, CGPoint(x: 910, y: 220))
            XCTAssertEqual(lines[2].from, CGPoint(x: 610, y: 20))
            XCTAssertEqual(lines[2].to, CGPoint(x: 610, y: 620))
            XCTAssertEqual(lines[3].from, CGPoint(x: 10, y: 420))
            XCTAssertEqual(lines[3].to, CGPoint(x: 910, y: 420))
        }

        func testPhiSegmentsUseOpenZCineLiterals() {
            let feed = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            let lines = GridAssist.segments(in: feed, thirds: false, phi: true, diagonal: false)
            XCTAssertEqual(lines.count, 4)
            XCTAssertEqual(lines[0].from.x, 382, accuracy: 0.001)
            XCTAssertEqual(lines[2].from.x, 618, accuracy: 0.001)
        }

        func testDiagonalIsBothFeedCorners() {
            let feed = CGRect(x: 0, y: 0, width: 100, height: 50)
            let lines = GridAssist.segments(in: feed, thirds: false, phi: false, diagonal: true)
            XCTAssertEqual(
                lines,
                [
                    MonitorGridSegment(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 50)),
                    MonitorGridSegment(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 0, y: 50)),
                ]
            )
        }

        func testEmptySelectionDrawsNothing() {
            let feed = CGRect(x: 0, y: 0, width: 100, height: 100)
            XCTAssertTrue(
                GridAssist.segments(in: feed, thirds: false, phi: false, diagonal: false).isEmpty
            )
        }

        func testPlaybackGridStaysInsideTheLetterboxedFeed() {
            let screen = CGRect(x: 0, y: 0, width: 844, height: 390)
            let feed = PlaybackVideoLayout.aspectFitRect(
                videoSize: CGSize(width: 3840, height: 2160), in: screen)
            XCTAssertLessThan(feed.width, screen.width)
            let lines = GridAssist.segments(in: feed, thirds: true, phi: true, diagonal: true)
            XCTAssertFalse(lines.isEmpty)
            for segment in lines {
                XCTAssertGreaterThanOrEqual(segment.from.x, feed.minX - 0.01)
                XCTAssertLessThanOrEqual(segment.from.x, feed.maxX + 0.01)
                XCTAssertGreaterThanOrEqual(segment.from.y, feed.minY - 0.01)
                XCTAssertLessThanOrEqual(segment.from.y, feed.maxY + 0.01)
                XCTAssertGreaterThanOrEqual(segment.to.x, feed.minX - 0.01)
                XCTAssertLessThanOrEqual(segment.to.x, feed.maxX + 0.01)
                XCTAssertGreaterThanOrEqual(segment.to.y, feed.minY - 0.01)
                XCTAssertLessThanOrEqual(segment.to.y, feed.maxY + 0.01)
            }
        }
    }

    /// Pins the reference monitor's `AssistConfiguration.Guides` + `rectForRatio`.
    final class GuidesAssistTests: XCTestCase {
        func testFilmAndSocialListsMatchOpenZCine() {
            XCTAssertEqual(
                MonitorGuideAspect.ratios(for: .film).map(\.rawValue),
                [
                    "2.76:1", "2.39:1", "2.35:1", "2.00:1", "1.85:1", "16:9", "1.66:1", "1.43:1",
                    "4:3",
                ]
            )
            XCTAssertEqual(
                MonitorGuideAspect.ratios(for: .social).map(\.rawValue),
                ["9:16", "4:5", "1:1", "2:3", "16:9", "1.91:1"]
            )
            XCTAssertTrue(MonitorGuideAspect.ratios(for: .social).contains(.vertical))
            XCTAssertFalse(MonitorGuideAspect.ratios(for: .film).contains(.vertical))
            XCTAssertTrue(MonitorGuideAspect.ratios(for: .film).contains(.cinema))
            XCTAssertFalse(MonitorGuideAspect.ratios(for: .social).contains(.cinema))
        }

        func testAspectRatioValueParsesLabel() {
            XCTAssertEqual(MonitorGuideAspect.cinema.ratio, 2.39, accuracy: 1e-9)
            XCTAssertEqual(MonitorGuideAspect.vertical.ratio, 0.5625, accuracy: 1e-9)
            XCTAssertEqual(MonitorGuideAspect.square.ratio, 1.0, accuracy: 1e-9)
            XCTAssertEqual(MonitorGuideAspect.hd.ratio, 16.0 / 9.0, accuracy: 1e-9)
        }

        func testSummaryLabelReflectsSelection() {
            XCTAssertEqual(GuidesAssist.summaryLabel(for: []), "\u{2014}")
            XCTAssertEqual(GuidesAssist.summaryLabel(for: [.cinema]), "2.39:1")
            XCTAssertEqual(GuidesAssist.summaryLabel(for: [.cinema, .wide]), "2 ratios")
        }

        func testRectForRatioLetterboxesWideGuide() {
            let feed = CGRect(x: 10, y: 20, width: 1920, height: 1080)
            let frame = GuidesAssist.rectForRatio(feed, 2.39)
            XCTAssertEqual(frame.width, 1920, accuracy: 0.01)
            XCTAssertEqual(frame.height, 1920 / 2.39, accuracy: 0.01)
            XCTAssertEqual(frame.midX, feed.midX, accuracy: 0.01)
            XCTAssertEqual(frame.midY, feed.midY, accuracy: 0.01)
        }

        func testRectForRatioPillarboxesTallGuide() {
            let feed = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let frame = GuidesAssist.rectForRatio(feed, 9.0 / 16.0)
            XCTAssertEqual(frame.height, 1080, accuracy: 0.01)
            XCTAssertEqual(frame.width, 1080 * 9.0 / 16.0, accuracy: 0.01)
            XCTAssertEqual(frame.midX, feed.midX, accuracy: 0.01)
            XCTAssertEqual(frame.midY, feed.midY, accuracy: 0.01)
        }

        func testSixteenNineGuideStaysInsideOneOnePicture() {
            let well = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let picture = PlaybackVideoLayout.aspectFitRect(
                videoSize: CGSize(width: 1, height: 1), in: well)
            let frame = GuidesAssist.rectForRatio(picture, 16.0 / 9.0)
            XCTAssertEqual(frame.width, picture.width, accuracy: 0.01)
            XCTAssertLessThan(frame.maxX, well.maxX - 1)
            XCTAssertGreaterThan(frame.minX, well.minX + 1)
            XCTAssertEqual(frame.midX, picture.midX, accuracy: 0.01)
        }
    }

    final class MirrorAssistTests: XCTestCase {
        func testFeedScaleIsHorizontalNotVertical() {
            let off = MirrorAssist.feedScale(mirrored: false)
            XCTAssertEqual(off.width, 1)
            XCTAssertEqual(off.height, 1)

            let on = MirrorAssist.feedScale(mirrored: true)
            XCTAssertEqual(on.width, -1, "OpenZCine mirror is a negative X scale")
            XCTAssertEqual(on.height, 1, "Y must stay +1: a negative Y is a vertical flip")
        }

        func testVerticalFlipIsNegativeYAndComposesWithMirror() {
            let v = MirrorAssist.feedScale(mirrored: false, flippedVertically: true)
            XCTAssertEqual(v.width, 1)
            XCTAssertEqual(v.height, -1)
            let both = MirrorAssist.feedScale(mirrored: true, flippedVertically: true)
            XCTAssertEqual(both.width, -1, "both axes is a 180° turn")
            XCTAssertEqual(both.height, -1)
        }

        func testFeedScalePreservesDesqueezeOnXOnly() {
            let squeeze = CGSize(width: 1.33, height: 1)
            let on = MirrorAssist.feedScale(mirrored: true, squeeze: squeeze)
            XCTAssertEqual(on.width, -1.33, accuracy: 0.0001)
            XCTAssertEqual(on.height, 1)
        }
    }

    final class DesqueezeAssistTests: XCTestCase {
        func testPresetsAndHundredthStepsDoNotSelectANeighboringPreset() {
            XCTAssertEqual(
                MonitorDesqueezePreset.allCases.map(\.factor), [1.1, 1.2, 1.33, 1.5, 1.6, 1.8, 2])
            for step in 100...200 {
                let factor = Double(step) / 100
                XCTAssertEqual(DesqueezeAssist.snap(factor), factor, accuracy: 0.000_001)
            }
            XCTAssertNil(MonitorDesqueezePreset.matching(1.32))
            XCTAssertNil(MonitorDesqueezePreset.matching(1.34))
            XCTAssertEqual(DesqueezeAssist.snap(1.337), 1.34)
            XCTAssertEqual(DesqueezeAssist.snap(1.005), 1.01)
            XCTAssertEqual(DesqueezeAssist.snap(1.335), 1.34)
            XCTAssertEqual(DesqueezeAssist.snap(0.5), 1)
            XCTAssertEqual(DesqueezeAssist.snap(3), 2)
            XCTAssertEqual(DesqueezeAssist.snap(.nan), 1.33)
            XCTAssertEqual(DesqueezeAssist.snap(.infinity), 1.33)
        }

        func testHorizontalAndVerticalFitTheEntireCorrectedRaster() {
            let source = CGSize(width: 1920, height: 1080)
            let viewport = CGRect(x: 20, y: 10, width: 800, height: 600)
            var fx = MonitorFrameEffects()
            fx.desqueezeFactor = 2
            let wide = DesqueezeAssist.presentationRect(
                sourceSize: source, in: viewport, effects: fx)
            XCTAssertEqual(wide.width, 800)
            XCTAssertEqual(wide.height, 225)
            XCTAssertEqual(wide.midX, viewport.midX)
            XCTAssertEqual(wide.midY, viewport.midY)
            fx.desqueezeHorizontal = false
            let tall = DesqueezeAssist.presentationRect(
                sourceSize: source, in: viewport, effects: fx)
            XCTAssertEqual(tall.height, 600)
            XCTAssertEqual(tall.width, 533.333_333, accuracy: 0.000_1)
            XCTAssertEqual(tall.midX, viewport.midX)
            XCTAssertEqual(tall.midY, viewport.midY)
        }
    }
#endif
