#if os(iOS)
import XCTest

/// The shared gallery as XCUITest sees it, read from one accessibility snapshot per call.
struct MediaGalleryProbe {
    struct Clip: Equatable {
        var id: String
        var frame: CGRect
    }

    let app: XCUIApplication

    /// Clips at least half inside the gallery viewport (their centre is, so a tap lands on them), in
    /// reading order. A landscape grid card can be taller than half the viewport, so "wholly inside"
    /// can leave no clip at all.
    func visibleClips() -> [Clip] { scan()?.clips ?? [] }

    /// One snapshot's gallery viewport and its visible clips.
    private func scan() -> (viewport: CGRect, clips: [Clip])? {
        guard let root = try? app.snapshot() else { return nil }
        var viewport: CGRect?
        var clips: [Clip] = []
        func walk(_ element: XCUIElementSnapshot) {
            if viewport == nil, element.identifier == "monitor.media.gallery" {
                viewport = element.frame
            }
            if element.identifier.hasPrefix("monitor.media.clip."),
                !clips.contains(where: { $0.id == element.identifier })
            {
                clips.append(Clip(id: element.identifier, frame: element.frame))
            }
            element.children.forEach(walk)
        }
        walk(root)
        guard let viewport else { return nil }
        let visible = clips.filter {
            !$0.frame.isEmpty && viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        return (viewport, visible)
    }

    /// Two neighbouring clips (reading order) wholly inside the viewport, for a selection sweep. A
    /// clip cut by the viewport's edge sits where a sweep autoscrolls the gallery and widens the
    /// selection (a tablet grid's first row under the header).
    func sweepPair() -> (Clip, Clip)? {
        guard let scanned = scan() else { return nil }
        let clips = scanned.clips
        return zip(clips, clips.dropFirst()).first { first, second in
            scanned.viewport.contains(first.frame) && scanned.viewport.contains(second.frame)
        }
    }

    /// The first visible clip once the gallery has stopped moving.
    func settledAnchor(timeout: TimeInterval = 10) -> Clip? {
        var last: Clip?
        var since = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = visibleClips().first
            if current != last {
                last = current
                since = Date()
            } else if current != nil, Date().timeIntervalSince(since) >= 0.6 {
                return current
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// The identifier of the selected control among `monitor.media.layout.*` or `.category.*`.
    func selected(_ group: String) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        func find(_ element: XCUIElementSnapshot) -> String? {
            if element.isSelected, element.identifier.hasPrefix("monitor.media.\(group).") {
                return element.identifier
            }
            return element.children.lazy.compactMap(find).first
        }
        return find(root)
    }

    /// Where a tap or drag reaches the clip: the centre of its snapshot frame, which
    /// `visibleClips()` keeps inside the viewport. Not a query by identifier: a cell partly outside
    /// the window has no activation point, and XCUITest rejects identifiers as long as Insta's
    /// offline asset IDs ("Invalid query - string identifier").
    func center(_ clip: Clip) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: clip.frame.midX, dy: clip.frame.midY))
    }

    /// Waits for staged clips, then scrolls the gallery at least two screens down.
    func scrollTwoScreens(file: StaticString = #filePath, line: UInt = #line) {
        let gallery = app.scrollViews["monitor.media.gallery"]
        XCTAssertTrue(
            gallery.waitForExistence(timeout: 15), "The staged gallery must appear", file: file,
            line: line)
        guard let top = settledAnchor() else {
            return XCTFail("The staged clips must show", file: file, line: line)
        }
        gallery.swipeUp()
        gallery.swipeUp()
        let scrolled = settledAnchor()
        XCTAssertNotNil(scrolled, file: file, line: line)
        XCTAssertNotEqual(
            scrolled?.id, top.id, "Two swipes must move the gallery away from its top", file: file,
            line: line)
    }
}
#endif
