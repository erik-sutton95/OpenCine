import Testing

@testable import MonitorPresentation

struct TeleprompterOverlayLayoutTests {
    @Test func selectedScriptGetsOneQuickSlotWithoutChangingOtherUsageOrder() {
        #expect(
            MonitorAssistPaletteReveal.prioritizedOrder(
                ranked: ["PEAK", "FALSE", "PROMPT", "ZEBRA"],
                priorityIDs: ["PROMPT", "PROMPT", "missing"])
                == ["PROMPT", "PEAK", "FALSE", "ZEBRA"])
        #expect(
            MonitorAssistPaletteReveal.prioritizedOrder(ranked: ["PEAK", "FALSE"], priorityIDs: [])
                == ["PEAK", "FALSE"])
    }

    @Test func promptStaysLastInTheCatalogEvenWhenItRanksFirst() {
        let ranked = ["PROMPT", "PEAK", "FALSE", "LUT"]
        #expect(
            MonitorAssistPaletteReveal.displayOrder(
                ranked: ranked, priorityIDs: ["PROMPT"], trailingIDs: ["PROMPT"])
                == ["PEAK", "FALSE", "LUT", "PROMPT"])
        #expect(
            MonitorAssistPaletteReveal.displayOrder(
                ranked: ranked, priorityIDs: [], trailingIDs: ["PROMPT"], compactToolCount: 2)
                == ["PEAK", "FALSE", "LUT", "PROMPT"])
    }

    @Test func loadedPromptOccupiesTheLastVisibleCompactSlot() {
        let ranked = ["PEAK", "FALSE", "PROMPT", "LUT"]
        let landscape = MonitorAssistPaletteReveal.displayOrder(
            ranked: ranked, priorityIDs: ["PROMPT", "PROMPT", "missing"],
            trailingIDs: ["PROMPT", "PROMPT", "missing"], compactToolCount: 2)
        #expect(Array(landscape.prefix(2)) == ["PEAK", "PROMPT"])
        #expect(landscape.filter { $0 != "PROMPT" } == ["PEAK", "FALSE", "LUT"])
        let portrait = MonitorAssistPaletteReveal.displayOrder(
            ranked: ranked, priorityIDs: ["PROMPT"], trailingIDs: ["PROMPT"], compactToolCount: 1)
        #expect(portrait.first == "PROMPT")
    }

    @Test func collapsingTheFrozenCatalogRestoresTheReservedPromptSlot() {
        let frozen = MonitorAssistPaletteReveal.pinnedOrder(
            ranked: ["FALSE", "PROMPT", "PEAK", "LUT"],
            pinned: ["PEAK", "LUT", "PROMPT", "FALSE"], frozen: true)
        #expect(
            MonitorAssistPaletteReveal.displayOrder(
                ranked: frozen, priorityIDs: ["PROMPT"], trailingIDs: ["PROMPT"])
                == ["PEAK", "LUT", "FALSE", "PROMPT"])
        #expect(
            Array(
                MonitorAssistPaletteReveal.displayOrder(
                    ranked: frozen, priorityIDs: ["PROMPT"], trailingIDs: ["PROMPT"],
                    compactToolCount: 2
                ).prefix(2))
                == ["PEAK", "PROMPT"])
        #expect(
            MonitorAssistPaletteReveal.displayOrder(
                ranked: ["PEAK", "LUT"], priorityIDs: ["missing"], trailingIDs: ["PROMPT"])
                == ["PEAK", "LUT"])
    }

    @Test func landscapeReaderKeepsCameraControlsAndAllEdgesClear() {
        let layout = FieldMonitorLayout(width: 852, height: 393)
        let shown: MonitorScopeChrome = [
            .status, .settings, .media, .record, .display, .values, .tools,
        ]
        let frame = TeleprompterOverlayLayout.frame(
            layout: layout,
            safeArea: .init(top: 0, leading: 44, bottom: 21, trailing: 44), shown: shown,
            motionCluster: false)
        #expect(frame.x >= 44 && frame.maxX <= 808)
        #expect(frame.y >= 0 && frame.maxY <= 372)
        #expect(frame.width >= 180 && frame.height >= 100)
        #expect(frame.y == layout.status.maxY + 8)
        for obstacle in layout.scopeObstacles(shown) {
            #expect(
                !(frame.x < obstacle.maxX && frame.maxX > obstacle.x
                    && frame.y < obstacle.maxY && frame.maxY > obstacle.y))
        }
    }
    @Test(arguments: [false, true])
    func portraitUsesLetterboxSpaceAndKeepsControlsClear(fill: Bool) {
        let safe = MonitorSafeArea(top: 59, leading: 0, bottom: 34, trailing: 0)
        let layout = FieldMonitorLayout(width: 393, height: 852, safeArea: safe, fill: fill)
        let shown: MonitorScopeChrome = [
            .status, .telemetry, .lock, .settings, .media,
            .record, .display, .values, .tools, .aspectToggle,
        ]
        let frame = TeleprompterOverlayLayout.frame(
            layout: layout, safeArea: safe,
            shown: shown, motionCluster: false, extraObstacles: [layout.appBadge])
        #expect(frame.width >= 330)
        #expect(frame.height >= 380)
        if !fill { #expect(frame.y < layout.picture.y && frame.maxY > layout.picture.maxY) }
        expectClear(
            frame, layout: layout, safe: safe,
            obstacles: layout.scopeObstacles(shown) + [layout.appBadge])
    }

    @Test(arguments: [false, true])
    func landscapeUsesSideMarginsWithoutTouchingRailsOrBadges(cutoutOnRight: Bool) {
        let safe = MonitorSafeArea(
            top: 0, leading: cutoutOnRight ? 0 : 62,
            bottom: 21, trailing: cutoutOnRight ? 62 : 0)
        let layout = FieldMonitorLayout(width: 956, height: 440, safeArea: safe)
        let shown: MonitorScopeChrome = [
            .status, .telemetry, .lock, .settings, .media,
            .record, .display, .values, .tools,
        ]
        let frame = TeleprompterOverlayLayout.frame(
            layout: layout, safeArea: safe,
            shown: shown, motionCluster: false, extraObstacles: [layout.appBadge])
        #expect(frame.width > 700)
        #expect(frame.width * frame.height > 190_000)
        expectClear(
            frame, layout: layout, safe: safe,
            obstacles: layout.scopeObstacles(shown) + [layout.appBadge])
    }

    @Test func motionAndNativeAccessoriesKeepTheirTouchTargets() {
        let safe = MonitorSafeArea(top: 0, leading: 59, bottom: 21, trailing: 0)
        let layout = FieldMonitorLayout(width: 852, height: 393, safeArea: safe)
        let shown: MonitorScopeChrome = [
            .status, .telemetry, .lock, .settings, .media,
            .record, .display, .values, .tools, .motion, .focusReset,
        ]
        let extra = [layout.aeUnlock, MonitorRect(x: 400, y: 240, width: 44, height: 44)]
        let frame = TeleprompterOverlayLayout.frame(
            layout: layout, safeArea: safe,
            shown: shown, motionCluster: true, extraObstacles: extra)
        #expect(frame.width >= 300 && frame.height >= 140)
        expectClear(
            frame, layout: layout, safe: safe,
            obstacles: layout.scopeObstacles(shown, motionCluster: true) + extra)
    }

    private func expectClear(
        _ frame: MonitorRect, layout: FieldMonitorLayout, safe: MonitorSafeArea,
        obstacles: [MonitorRect]
    ) {
        #expect(frame.x >= safe.leading && frame.maxX <= layout.viewport.width - safe.trailing)
        #expect(frame.y >= safe.top && frame.maxY <= layout.viewport.height - safe.bottom)
        for obstacle in obstacles {
            #expect(
                !(frame.x < obstacle.maxX + 8 && frame.maxX > obstacle.x - 8
                    && frame.y < obstacle.maxY + 8 && frame.maxY > obstacle.y - 8))
        }
    }

}
