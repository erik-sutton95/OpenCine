# Zoom Ruler and Go Live Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the half disc zoom dial with a slim vertical ruler (0.1x steps, presets beside it, other chrome hidden while open) and move a restyled Go Live control under the timecode block, in the shared iOS and Android UI used by all three apps.

**Architecture:** Pure geometry and text live in `MonitorPresentation` (Swift) and `monitor-ui` (Kotlin) as tested twins. The views keep their callers: Swift `MonitorZoomDial` keeps its name and callbacks; Kotlin `MonitorZoomDisc` is replaced by `MonitorZoomRuler` behind the unchanged camera-controls `MonitorZoomDial`. Zoom-open state already exists on iOS (`MonitorOperatorInteraction.zoomVisible`); on Android it is lifted out of `LiveZoomChip` into `MonitorOperatorSessionModel.zoomDialOpen`.

**Tech Stack:** SwiftUI (iOS 17+), Jetpack Compose, XCTest / Swift Testing as used by neighbors, JUnit.

**Spec:** `docs/superpowers/specs/2026-11-21-zoom-ruler-go-live-design.md`. Mockup: <https://claude.ai/artifact/QdGja1g4PzSWry6ChdN2HS>

## Global Constraints

- No em dash character anywhere (code comments, UI copy, commits, PR text).
- Commits as Erik Sutton <9084979+erik-sutton95@users.noreply.github.com>, no co-author trailer.
- Ruler step: 0.1x. Ticks: minor every 0.1x, mid every 0.5x, major with label every 1x.
- Ruler spacing is linear in zoom factor; bottom is the minimum, top the maximum.
- Minor ticks fall back to every 0.5x when one 0.1x step is under 4 pt (dp); drag still rounds to 0.1x.
- Readout text: one decimal, e.g. `2.5×` (multiplication sign U+00D7, as today).
- Live status line: `1080p · 6.0 Mbps · good` (middle dot U+00B7 with spaces).
- Public API changes update snapshots in the same PR: `atlas api --write --build` (Swift), `cd Android && ./gradlew updateKotlinAbi updateAndroidApi` (Kotlin).
- Worktrees and build scratch on `/Volumes/OCFast`; iOS tests on a private simulator (`xcrun simctl create opc-zoomruler "iPhone 16 Pro"`, delete after).

## Review Focus

- A camera with maximum 1x (no zoom) or a non-finite maximum: the ruler must not divide by zero; value stays 1.0. Test in Task 1.
- A long range (12x on a short landscape phone, about 300 pt): minor ticks fall back to 0.5x and labels do not collide. Test in Task 1.
- Rotating while the ruler is open or a finger is down: the edit ends cleanly (`onEditing(false)` once) and the ruler re-lays out. Existing cancel-on-viewport-change kept; covered in Task 2 step.
- Closing the ruler restores every hidden element (status, joystick cluster, Go Live) with no Go Live state reset. Test in Tasks 4 and 5.
- Go Live with the status row turned off in display settings still lands top right, never over the record button. Test in Task 6.

---

### Task 1: Ruler scale model (Swift and Kotlin twins)

**Files:**

- Create: `Sources/MonitorPresentation/MonitorZoomRulerScale.swift`
- Create: `Tests/MonitorPresentationTests/MonitorZoomRulerScaleTests.swift`
- Create: `Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/MonitorZoomRulerScale.kt`
- Create: `Android/monitor-ui/src/test/kotlin/com/opencapture/monitorui/MonitorZoomRulerScaleTest.kt`

**Interfaces (Swift; Kotlin mirrors names in camelCase, `Double`/`Float` for pt/dp):**

- Produces:
  - `public struct MonitorZoomRulerScale: Equatable, Sendable { init(minimum: Double, maximum: Double, length: Double) }`
  - `static let step = 0.1`
  - `func quantized(_ value: Double) -> Double` (clamp, round to 0.1, avoid float noise: `(v * 10).rounded() / 10`)
  - `func offset(for value: Double) -> Double` (0 at top = maximum, `length` at bottom = minimum)
  - `func value(atOffset: Double) -> Double` (quantized, clamped)
  - `var ticks: [MonitorZoomRulerTick]`; `struct MonitorZoomRulerTick: Equatable, Sendable { let value: Double; let offset: Double; let kind: Kind }`, `enum Kind { case minor, mid, major }`
  - `static func readout(_ value: Double) -> String` → `"2.5×"`
  - Kotlin: `data class MonitorZoomRulerScale(...)`, `MonitorZoomRulerTick`, `enum class Kind { MINOR, MID, MAJOR }`, `companion object { const val STEP = 0.1; fun readout(v: Double): String }`

- [ ] **Step 1: Write failing tests (Swift, then the same cases in Kotlin)**

```swift
@Test func endsMapToMinimumAndMaximum() {
    let s = MonitorZoomRulerScale(minimum: 1, maximum: 4, length: 300)
    #expect(s.offset(for: 4) == 0); #expect(s.offset(for: 1) == 300)
    #expect(s.value(atOffset: -20) == 4); #expect(s.value(atOffset: 999) == 1)
}
@Test func dragRoundsToTenths() {
    let s = MonitorZoomRulerScale(minimum: 1, maximum: 4, length: 300)  // 10 pt per 0.1x
    #expect(s.value(atOffset: 150) == 2.5); #expect(s.value(atOffset: 146) == 2.5)
    #expect(s.value(atOffset: 144) == 2.6)
}
@Test func tickKinds() {
    let t = MonitorZoomRulerScale(minimum: 1, maximum: 4, length: 300).ticks
    #expect(t.count == 31)
    #expect(t.filter { $0.kind == .major }.map(\.value) == [1, 2, 3, 4])
    #expect(t.filter { $0.kind == .mid }.map(\.value) == [1.5, 2.5, 3.5])
}
@Test func denseRangeDropsTenthTicks() {
    let t = MonitorZoomRulerScale(minimum: 1, maximum: 12, length: 300).ticks  // 2.7 pt per 0.1x
    #expect(!t.contains { $0.kind == .minor })
    #expect(t.filter { $0.kind == .mid }.count == 11)
    #expect(MonitorZoomRulerScale(minimum: 1, maximum: 12, length: 300).value(atOffset: 150) == 6.5)
}
@Test func noZoomRangeIsSafe() {
    let s = MonitorZoomRulerScale(minimum: 1, maximum: 1, length: 300)
    #expect(s.value(atOffset: 10) == 1); #expect(s.offset(for: 1).isFinite)
    let n = MonitorZoomRulerScale(minimum: 1, maximum: .nan, length: 300)
    #expect(n.value(atOffset: 0) == 1)
}
@Test func readoutHasOneDecimal() {
    #expect(MonitorZoomRulerScale.readout(2.5) == "2.5×"); #expect(MonitorZoomRulerScale.readout(1) == "1.0×")
}
```

Use the test framework the neighboring `MonitorZoomScaleTests.swift` uses (convert `#expect` to `XCTAssertEqual` if that file is XCTest).

- [ ] **Step 2: Run, expect compile failure**

Run: `swift build --build-tests -Xswiftc -strict-concurrency=complete --scratch-path /Volumes/OCFast/scratch/zoomruler-spm && swift test --skip-build --scratch-path /Volumes/OCFast/scratch/zoomruler-spm --filter MonitorZoomRulerScale`
Expected: FAIL, `MonitorZoomRulerScale` not found. Kotlin: `cd Android && ./gradlew :monitor-ui:testDebugUnitTest --tests '*MonitorZoomRulerScaleTest'` fails to compile.

- [ ] **Step 3: Implement both twins.** A non-finite or `<= minimum` maximum collapses to minimum; `length <= 0` maps every offset to minimum. Minor ticks exist only when `length / ((maximum - minimum) / 0.1) >= 4`.

- [ ] **Step 4: Run both test commands, expect PASS.**

- [ ] **Step 5: Commit** `feat(monitor): zoom ruler scale with 0.1x steps`

### Task 2: iOS ruler view

**Files:**

- Modify: `Sources/MonitorUI/MonitorZoomDial.swift` (replace disc drawing, radial gesture, half disc shape, canvas snapshot)
- Modify: `Sources/OpenCineCameraControls/LiveChrome/MonitorOperatorCaptureOverlays.swift:91-122` (`MonitorOperatorZoomDial` passes clearances)
- Modify: `Tests/MonitorUITests/CameraDeferredRenderingTests.swift` (drop references to the removed canvas snapshot, keep the dial construction test)
- Delete if Atlas shows no consumer outside OpenCine (`atlas consumers MonitorZoomGeometry`): `Sources/MonitorPresentation/MonitorZoomGeometry.swift` and `Tests/MonitorPresentationTests/MonitorZoomGeometryTests.swift`; also any `MonitorZoomRadialGesture`. Keep `MonitorZoomAttachment` (parameter stays, ignored).
- Update: `atlas/api/swift` snapshot.

**Interfaces:**

- Consumes: `MonitorZoomRulerScale` (Task 1).
- Produces: `MonitorZoomDial.init(...)` gains `topClearance: CGFloat = 0` after `bottomClearance`; all other parameters unchanged. Accessibility identifier stays `monitor.zoom.dial`; label becomes "Zoom".

- [ ] **Step 1: Write the view.** Layout inside the viewport:
  - Ruler rect: width 44, trailing edge at `viewport.width - max(safeArea.trailing, 0) - 12`, from `topClearance` to `viewport.height - bottomClearance`. Glass via `.monitorGlass(in: Capsule(), density: .zoom)`.
  - Ticks drawn in a `Canvas` from `scale.ticks`: major right 12%..left 52% at 2 pt, mid 60%..88% at 1.5 pt, minor 72%..88% at 1 pt white 0.32 opacity; major labels (`"\(Int(v))×"`) left of the ruler at 12 pt semibold; optical stop ticks use `MonitorTheme.edrAccent(gain:)`, values above the highest optical stop use `MonitorTheme.digitalCrop` (same rule as the disc).
  - Current value marker: a 3 pt accent bar across the ruler at `offset(for: value)`.
  - Readout: `MonitorZoomRulerScale.readout(value)` bold 22 pt plus caption 10 pt, trailing-aligned to the left of the ruler, top at `topClearance + 0.08 * rulerHeight`.
  - Presets: existing `MonitorZoomPresetStrip(controls:, maximum:, vertical: true, ...)`, trailing edge 12 pt left of the ruler, vertically centered on it.
  - Background tap closes (keep the existing clear `Button(action: onClose)`).
- [ ] **Step 2: Gesture.** `DragGesture(minimumDistance: 0)` on the ruler rect: on first change `drag.begin(at: value)` then `onEditing(true)`; each change sets `value = scale.value(atOffset: location.y - rulerTop)`; end/cancel paths and the existing `onChange` cancel triggers (viewport, safeArea, scale, clearances, scene phase) stay.
- [ ] **Step 3: Haptic.** Replace the whole-stop detent with a tick whenever `quantized(new) != quantized(old)` during a drag: `.sensoryFeedback(.impact(weight: .light), trigger: stepTick)` gated by `haptics`.
- [ ] **Step 4: Accessibility.** Adjustable action steps `MonitorZoomRulerScale.step`; value text `readout + ", " + caption`.
- [ ] **Step 5: Motion.** Enter: slide from trailing 24 pt plus fade using `MonitorMotion.discIn/discOut`; reduce motion fades only.
- [ ] **Step 6: Caller.** In `MonitorOperatorZoomDial`, portrait (`layout.presentation?.portrait`): `topClearance = layout.topDeck.maxY + 8`, `bottomClearance = viewport.height - (min(layout.capture.minY, layout.rail.minY) - 12)` when `layout.showsBottomBars`, else `safeArea.bottom + 12`. Landscape: `topClearance = max(layout.safeArea.top, 12)`, `bottomClearance = max(layout.safeArea.bottom, 12)`. Pass `attachment: .trailing` always.
- [ ] **Step 7: Verify.** `swift build --build-tests ... && swift test --skip-build ...` PASS; `xcodebuild -scheme MonitorUI -destination 'generic/platform=iOS Simulator' build` and `-scheme OpenCineApple` succeed; `atlas api --write --build` then `git diff --stat atlas/api` shows only the intended symbols.
- [ ] **Step 8: Commit** `feat(monitor-ui): vertical zoom ruler replaces the zoom disc (iOS)`

### Task 3: Android ruler view

**Files:**

- Create: `Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/MonitorZoomRuler.kt`
- Delete: `Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/MonitorZoomDisc.kt`; `MonitorZoomGeometry.kt` and its test if nothing else uses them (`MonitorZoomAttachment` stays if referenced by API, else removed).
- Modify: `Android/monitor-ui/src/androidTest/kotlin/com/opencapture/monitorui/MonitorZoomInputTest.kt` (drive the ruler: drag from bottom to middle of a 1..4 ruler lands on 2.5 within the callback values)
- Modify: `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorZoomDial.kt`
- Modify: `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/LiveZoomChrome.kt` (`LiveZoomChip`)
- Modify: `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorOperatorVocabularySurface.kt:271-285`
- Update: `Android/*/api/*.api`

**Interfaces:**

- Consumes: Kotlin `MonitorZoomRulerScale` (Task 1).
- Produces:
  - `@Composable fun MonitorZoomRuler(initial: Double, maximum: Double, onChange: (Double) -> Unit, onDismiss: () -> Unit, opticalStops: List<Double> = listOf(1.0), caption: (Double) -> String = { "ZOOM" }, clearance: MonitorZoomClearance = MonitorZoomClearance(), onStep: () -> Unit = {}, presets: MonitorZoomPresetControls? = null, driven: Double? = null)`
  - `data class MonitorZoomClearance(val top: Float = 0f, val bottom: Float = 0f)` (dp, in monitor-ui)
  - camera-controls `MonitorZoomDial(...)` gains `clearance: MonitorZoomClearance = MonitorZoomClearance()`; calls `MonitorZoomRuler`, `onStep = { haptics.selection() }`.
  - `LiveZoomChip(...)` gains `clearance: MonitorZoomClearance = MonitorZoomClearance()` and `onDialOpenChange: (Boolean) -> Unit = {}` (called with true on long-press open, false on dismiss, lock, orientation change and dispose).

- [ ] **Step 1: Update `MonitorZoomInputTest` to the ruler and run it to fail** (`./gradlew :monitor-ui:compileDebugAndroidTestKotlin` fails: `MonitorZoomRuler` missing).
- [ ] **Step 2: Implement `MonitorZoomRuler`** in the same `Popup` host the disc used (keeps it above the SurfaceView), with the Swift Task 2 layout values in dp, `detectDragGestures` mapping y to `scale.valueAtOffset`, `onStep` when the quantized value changes, semantics `setProgress` stepping 0.1, tap outside dismisses.
- [ ] **Step 3: Wire clearances** in `MonitorOperatorNativeControls`: same rule as Swift Task 2 Step 6 from `layout.topDeck`, `layout.capture`, `layout.rail`, `layout.safeTop`, `layout.safeBottom`, portrait when `viewportHeight > viewportWidth`.
- [ ] **Step 4: Verify.** `cd Android && ./gradlew :monitor-ui:testDebugUnitTest :camera-controls:testDebugUnitTest :monitor-ui:compileDebugAndroidTestKotlin lint` PASS; `./gradlew updateKotlinAbi updateAndroidApi` and review the `.api` diff.
- [ ] **Step 5: Commit** `feat(monitor-ui): vertical zoom ruler replaces the zoom disc (Android)`

### Task 4: Hide chrome while the ruler is open (iOS)

**Files:**

- Modify: `Sources/OpenCineCameraControls/LiveChrome/MonitorOperatorVocabularySurface.swift` (`MonitorOperatorMotionContent.controls`, `.feedback`)
- Modify: `Sources/OpenCineCameraControls/LiveChrome/MonitorOperatorLiveSurface.swift` (status block near line 627)
- Modify: `Sources/OpenCineAppKitApple/LiveStreamMonitorOverlay.swift` (`LiveStreamMonitorOverlay`)
- Modify: `Sources/OpenCineCameraControls/LiveChrome/MonitorOperatorLiveScreen.swift:227-233`
- Test: `Tests/OpenCineCameraControlsTests/` (or the module's existing live chrome test file) for the visibility rule

**Interfaces:**

- Produces:
  - `MonitorOperatorInteraction.chromeHiddenForZoom: Bool { zoomVisible }` (single name used by all callers)
  - `LiveStreamMonitorOverlay.init(coordinator:, hidden: Bool = false)`; when hidden: opacity 0, no hit testing, accessibility hidden, but still mounted (so `monitorControlsAppeared` does not flip and the app pill stays hidden).

- [ ] **Step 1: Failing test:** opening zoom sets `chromeHiddenForZoom` true; `closeZoom` sets it false immediately (before the 190 ms unmount).
- [ ] **Step 2: Apply.** Zoom chip, gimbal button, gimbal stick, head tracking calibrate, gimbal overlay: `.opacity(hidden ? 0 : 1)` and `.allowsHitTesting(!hidden)` using `MonitorMotion.dim(reduceMotion)`, replacing the 0.16 dim. Keep the zoom chip mounted (the dial is not its child on iOS, but keep identity stable). Status block in the live surface: same fade. `MonitorOperatorLiveScreen` passes `hidden: interaction.chromeHiddenForZoom`.
- [ ] **Step 3: Verify** with the Swift build/test commands and the two xcodebuild builds.
- [ ] **Step 4: Commit** `feat(monitor): hide the joystick, status and Go Live while the zoom ruler is open (iOS)`

### Task 5: Hide chrome while the ruler is open (Android)

**Files:**

- Modify: `Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/MonitorOperatorSessionModel.kt`
- Test: `Android/appkit/src/test/kotlin/com/opencapture/opencine/appkit/MonitorOperatorSessionModelTest.kt`
- Modify: `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorOperatorVocabularySurface.kt` (`MonitorOperatorNativeControls`)
- Modify: `Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorOperatorLiveSurface.kt` (status block)
- Modify: `Android/appkit-native/src/main/kotlin/com/opencapture/opencine/appkitnative/LiveStreamComposition.kt` (`LiveStreamOverlay`, scoped overload)

**Interfaces:**

- Consumes: `LiveZoomChip(onDialOpenChange:)` (Task 3).
- Produces:
  - `MonitorOperatorSessionModel.zoomDialOpen: Boolean` (Compose `mutableStateOf`, public get, public set); reset to false by the session's lock transition.
  - `LiveStreamOverlay(coordinator, modifier, hidden: Boolean = false)` and `MonitorLiveFeedScope.LiveStreamOverlay(coordinator, hidden: Boolean = false)`; hidden keeps it composed (alpha 0, no pointer input, `invisibleToUser` semantics).

- [ ] **Step 1: Failing test** in `MonitorOperatorSessionModelTest`: `zoomDialOpenClearsOnLock` (set true, lock, expect false).
- [ ] **Step 2: Apply** the same hide rule as Task 4 to the zoom chip (alpha only, it hosts the ruler Popup so it must stay composed), gimbal button, stick, status block.
- [ ] **Step 3: Verify** `cd Android && ./gradlew :appkit:testDebugUnitTest :camera-controls:testDebugUnitTest :appkit-native:testDebugUnitTest lint`; API dump.
- [ ] **Step 4: Commit** `feat(monitor): hide the joystick, status and Go Live while the zoom ruler is open (Android)`

### Task 6: Go Live under the timecode, restyled (both platforms)

**Files:**

- Create: `Sources/MonitorPresentation/LiveStreamOverlayPlacement.swift`, test `Tests/MonitorPresentationTests/LiveStreamOverlayPlacementTests.swift`
- Modify: `Sources/MonitorPresentation/LiveStreamPresentation.swift` (`LiveStreamStatusState.compactLine(quality:)`), tests in the existing `LiveStreamPresentationTests`
- Modify: `Sources/MonitorUI/LiveStream/LiveStreamMonitorControls.swift`
- Modify: `Sources/OpenCineCameraControls/LiveChrome/MonitorOperatorLiveScreen.swift:227-233`
- Kotlin twins: `Android/monitor-ui/src/main/kotlin/com/opencapture/monitorui/LiveStreamOverlayPlacement.kt` (+ test), `LiveStreamPresentation.kt` (`compactLine`), `livestream/LiveStreamViews.kt`, `appkit-native/.../LiveStreamComposition.kt`

**Interfaces:**

- Produces:
  - `public enum LiveStreamOverlayPlacement { public static func anchor(status: CGRect, viewport: CGSize, safeArea: EdgeInsets) -> CGPoint }` returning the top trailing point the control hangs from: `x = min(status.maxX, viewport.width - safeArea.trailing) - 8`, `y = status.maxY + 6`; when `status.height <= 1` (status row off), `x = viewport.width - safeArea.trailing - 8` and `y = max(safeArea.top, 8) + 8`. Kotlin: `object LiveStreamOverlayPlacement { fun anchor(status: MonitorRect, viewportWidth: Float, safeTop: Float, safeTrailing: Float): MonitorPoint` (use the existing point type if `monitor-ui` has one, else a small `data class`) }`.
  - `LiveStreamStatusState.compactLine(quality: LiveStreamQuality?) -> String`: `"\(quality.height)p · \(bitrate) · \(healthText.lowercased())"`, quality part omitted when nil, `"N dropped"` inserted before health only when `droppedGroups > 0`. Bitrate uses `LiveStreamCopy.bitrate`.

- [ ] **Step 1: Failing tests**

```swift
@Test func anchorsUnderStatusTrailing() {
    let p = LiveStreamOverlayPlacement.anchor(status: CGRect(x: 0, y: 47, width: 393, height: 44),
        viewport: CGSize(width: 393, height: 852), safeArea: EdgeInsets())
    #expect(p == CGPoint(x: 385, y: 97))
}
@Test func statusOffStillTopTrailing() {
    let p = LiveStreamOverlayPlacement.anchor(status: .zero, viewport: CGSize(width: 852, height: 393),
        safeArea: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59))
    #expect(p == CGPoint(x: 785, y: 16))
}
@Test func compactLine() {
    let s = LiveStreamStatusState(phase: .live, elapsedSeconds: 724, sentBitrateBps: 6_000_000, droppedGroups: 0, health: .good)
    #expect(s.compactLine(quality: .init(width: 1920, height: 1080, framesPerSecond: 30, videoBitrateBps: 6_000_000)) == "1080p · 6.0 Mbps · good")
    var d = s; d.droppedGroups = 3; d.health = .congested
    #expect(d.compactLine(quality: nil) == "6.0 Mbps · 3 dropped · \(d.healthText.lowercased())")
}
```

(If `LiveStreamCopy.bitrate(6_000_000)` does not produce `"6.0 Mbps"`, use its output in the expectation and note it; do not change the copy.) Same cases in Kotlin.

- [ ] **Step 2: Run, expect FAIL; implement; run, expect PASS** (Swift and Kotlin test commands from Task 1).
- [ ] **Step 3: Restyle `LiveStreamMonitorControls`** (both twins): `VStack(alignment: .trailing)`, max width 260. Idle and unavailable: glass capsule (`.monitorGlass(in: Capsule())` / Kotlin glass twin) with the radio icon and title. Live: `MonitorTheme.recording` capsule with title (`LIVE 12:04`) and an inline stop glyph button (same `confirmStop` flow), then one caption under it with `status.compactLine(quality: state.quality)` at 10.5 pt semibold muted, health dot colored as today. The separate multi-field `LiveStreamStatusReadout` row is no longer shown in the monitor control (keep the type public; the accessibility label stays on the caption). Notices, warnings and camera status stack under it, trailing aligned.
- [ ] **Step 4: Place it.** iOS `MonitorOperatorLiveScreen`: replace the `onFeed` frame and offset with a `ZStack(alignment: .topTrailing)` positioned so its top trailing corner is at `LiveStreamOverlayPlacement.anchor(status: layout.topDeck, viewport: layout.viewport, safeArea: layout.safeArea)`. Android `MonitorLiveFeedScope.LiveStreamOverlay`: same from `geometry.layout.topDeck`, controls aligned `TopEnd`.
- [ ] **Step 5: Verify** full Swift build/test, both xcodebuild builds, `cd Android && ./gradlew test lint`, API snapshots.
- [ ] **Step 6: Commit** `feat(streaming): Go live under the timecode, restyled to the monitor chrome`

### Task 7: Screenshots, full checks, OpenCine PR

- [ ] **Step 1:** Private simulator, scheme `OpenPocketCineUIReview` in the Pocket worktree pointed at this OpenCine branch, env `OPV_UI_REVIEW_SCREEN=live OPV_UI_REVIEW_ZOOM_CONTROLS=1 OPV_UI_REVIEW_CONNECTED=1`: portrait and landscape, ruler closed and open (long press `monitor.system.zoom`). Compare against the mockup; fix spacing until they match.
- [ ] **Step 2:** Full `AGENTS.md` verification block (Swift, both xcodebuilds, `./gradlew test lint assembleRelease`, `scripts/android-vulkan-sync-test.sh`, atlas tests and `atlas check`, `atlas consumers --write` if stale).
- [ ] **Step 3:** Push branch, open the OpenCine PR with the screenshots, body ending with the Claude Code line. Merge only with `CI gate` green.

### Task 8: App pins (after the OpenCine PR merges)

- [ ] **OpenPocketCine and OpenInstaCine:** bump the OpenCine pin. iOS needs no code change. Android `LiveViewScreen.kt`: `LiveStreamOverlay(it.coordinator, hidden = chrome.session.zoomDialOpen)` (Pocket line 126, Insta line 139). Run each app's own checks.
- [ ] **OpenZCine:** iOS `ios/Runner/MonitorUnified.swift:706`: pass `hidden:` from its `MonitorOperatorInteraction` and place with `LiveStreamOverlayPlacement.anchor` like Task 6 Step 4. Android `MonitorScreen.kt:2343`: replace `Alignment.TopCenter` with the anchor and pass `hidden = operatorSession.zoomDialOpen`. Rides with the pending #587 pin.
- [ ] **On device:** install Pocket on the owner's iPhone; check drag steps and haptics, chrome restore on close, Go Live position while live. Android reported `untested` unless a device is attached.
