# Shared Multiview Plan 4: the screen and settings popup behind MultiviewHost

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift Pocket's Multiview screen composition (stage wiring, Add camera, network wizard,
Live View hand-off, options, close and cleanup prompts) and its camera settings popup into
OpenCine on both platforms, behind a grown `MultiviewHost`, so one screen can serve Pocket now and
OpenInstaCine and OpenZCine later. Pocket iOS shows no operator-visible change; Pocket Android
moves only toward iOS.

**Architecture:** Three layers, the same on both platforms.

1. `MultiviewHost` (AppKit, Swift protocol / Kotlin interface, no views) grows with the values
   only the app has: the tile readings, whether it edits camera settings and grades pictures with
   an Auto LUT, the LUT apply step, the settings editor (open, its state, what only the app admits).
   Every new requirement has a default, so existing adopters keep compiling.
2. The coordinator gains the screen's pure rules (picker rows from its found cameras and policy,
   close copy from the commissioner's presence, LUT toggles, the stage tile with the app's
   readings, the program readouts, tool availability). Tested on fakes, same test names.
3. The view layer: `MultiviewScreenHost` refines `MultiviewHost` with what is a view (the tile
   picture, the stage backdrop on iOS, the settings preview and controls, Live View, the network
   wizard's app values). `MultiviewScreen` and `MultiviewCameraSettingsPanel` compose the shared
   stage, picker, wizard, popup, alerts and Live View over a coordinator and such a host. Swift:
   `OpenCineAppKitApple` (it has the network wizard), Compose: `:appkit`.

Capability, not brand: the commissioner's presence decides the close copy, the picker footer and
whether the wizard scans through a camera (`scansNetworks`); the camera policy decides which
found cameras the picker lists and which join without a picture; the host decides the CAMERA tool
(`editsCameraSettings`), the LUT tool and option (`appliesAutoLUT`) and the categories each camera
offers (focus, aperture, photo mode, audio).

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing, Observation, SwiftUI), Kotlin 2.4 (JVM 17,
explicit API, Compose), XCTest in Pocket iOS, kotlin.test in Pocket Android.

**Spec:** `docs/superpowers/specs/2026-11-13-shared-multiview-design.md` (step 5, "Seams",
"Left to the builder"); series: `docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md`
("Carried from Plan 3"); Pocket handbook `guides/multiview-prototype.md`, Pocket `docs/PARITY.md`;
Plan 3 re-review `OpenCine-tasks/shared-multiview-3/REREVIEW.md` (N1 to N3).

## Global Constraints

- OpenCine `AGENTS.md`: twins with the same type and test names; no manufacturer or app name in
  AppKit or AppKitApple (`SharedUIRulesTests`); no em dash character (Kotlin strings write
  `\u2014`); Conventional Commits, no co-author trailers, explicit `git add`; behavior tests at
  contract boundaries on manual clocks, no sleeps.
- Boundaries: AppKit imports Core, Media, Multicam and UI only; AppKitApple builds on AppKit,
  MonitorUI, MonitorPresentation, OpenCineApple and the other edges AGENTS.md lists. The settings
  controls (`CapturePickerPanel`, `LiveControlSheet`) and the inspector preview stay in the app or
  camera controls and reach the popup as host views. No new third-party dependency.
- Pocket iOS: no operator-visible change: layout, copy, order, accessibility identifiers and
  labels used by `MultiviewUIFlowTests` and the UI review screens stay; the shared views keep
  Pocket's view tree and modifiers. Pocket Android: only toward iOS, keeping the handbook's named
  differences (24 probes, early identity read, decoder rebuild after Live View, repair only while a
  surface is mounted, phone hotspot and Local Wi-Fi wording, Keystore storage).
- Public API changes update snapshots in the branch (`atlas api --write --build`,
  `./gradlew updateKotlinAbi updateAndroidApi`).
- Scratch only under `/Volumes/OCScratch/smv4/`; iOS tests on the private simulator `opc-smv4`,
  deleted at the end.

## Review Focus

- Pocket iOS parity of `MultiviewScreen` against `MultiviewView.swift` and
  `MultiviewCameraSettings.swift` on `feat/shared-multiview-3`, modifier by modifier (hit testing,
  accessibility hiding, overlays, sheet and cover presentation, alert buttons, scene phase, persist
  on layout and focus changes, popups closing).
- The UI review screenshots before and after (pixel comparison), and `MultiviewUIFlowTests` per
  test against the base.
- The coordinator fixes N1 (a cancelled repair's result never acts), N2 (no repair on a closed
  link during a Reconnect search) with tests that fail before the fix, and N3 (Swift test for the
  older repair guard).
- `MultiviewHost` grows without breaking an adopter (every new requirement has a default).
- Capability rules, not brand: the commissioner, the policy and the host values each named above.

## Rulings taken while planning (recorded again in the report)

1. Views stay out of `MultiviewHost`: it lives in AppKit next to the coordinator and is the
   coordinator's seam. `MultiviewScreenHost` refines it with the view requirements (Swift
   associated types, Kotlin `@Composable` members). An app passes one object as both.
2. The Swift screen lives in `OpenCineAppKitApple` (it composes `StationNetworkSetupView`); the
   Compose screen in `:appkit` (it has `StationNetworkSetup`).
3. The settings categories become a shared value (`MultiviewSettingsCategory`) with iOS's order
   and titles (`Iso`, `Shutter`, `Exposure`, `WB`, `Focus`, `Aperture`, `Mode`, `Format`, `Color`,
   `Audio`; tabs display them upper-cased on both platforms), iOS's lock rule (mode, format and
   color while recording) and an `audio` input: Pocket iOS passes true in video modes as today;
   Pocket Android keeps its typed audio capability (PARITY's AUDIO admission continuation).
4. `coordinator.controlsAvailable(slot:)` also asks `host.admitsControls(slot:)` (Pocket: its own
   datalink is open and no Live View borrows the member), the rule both Pockets already combined.
5. The settings popup re-opens an editor only when the selected camera becomes ready (iOS's rule)
   on both platforms; Pocket Android's editor lease no longer snapshots the recording state (the
   popup locks mode, format and color live instead), as on iOS.
6. No Compose rendering harness exists in OpenCine (no compose ui-test dependency) and none is
   added (no new dependency): Kotlin is covered by value tests and Pocket Android's instrumented
   tests compile; Swift gets a hosted test in `OpenCineAppKitAppleTests`.

---

### Task 1: Plan 3 re-review leftovers in the coordinator (N1, N2, N3)

**Files:**
- Modify: `Sources/OpenCineAppKit/MultiviewCoordinator.swift`,
  `Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/MultiviewCoordinator.kt`
- Test: `Tests/OpenCineAppKitTests/MultiviewCoordinatorTests.swift`,
  `Android/appkit/src/test/kotlin/com/opencapture/opencine/appkit/MultiviewCoordinatorTest.kt`

**Interfaces:** none public. Behavior:
- N1: a repair's result is applied only while that repair is still the member's (Swift: Remove
  advances `repairGeneration`; the result switch checks it; Kotlin: the job identity check guards
  the result too).
- N2: `discoverPreview` clears `member.publishing` right after `link.close()`.
- N3: Swift test for the older-repair guard.

- [ ] Step 1: write the tests (Swift and Kotlin, same names):
  `aRemovedMembersCancelledRepairChangesNothing` (gated repair ignoring cancellation, Remove, open
  the gate returning `waitForOperator`: the emptied member has no failure and no exhausted budget),
  `aReconnectSearchStartsNoRepairOnTheClosedLink` (B's known address is A's control host, nothing
  answers, the search waits between passes; a monitor tick asks B's link for no repair),
  `anOlderRepairNeverClearsANewerOne` (Remove during a gated repair, add again, a new gated repair,
  open the old gate: the member still recovers).
- [ ] Step 2: run them; N1 and N2 fail on Swift, N2 fails on Kotlin.
- [ ] Step 3: implement; run the coordinator suites on both platforms; commit
  `fix(appkit): a cancelled repair and a closed link change nothing on the stage`.

### Task 2: Shared settings categories and screen copy (values)

**Files:**
- Create: `Sources/OpenCineAppKit/MultiviewScreenValues.swift`,
  `Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/MultiviewScreenValues.kt`
- Modify: `Sources/OpenCineAppKit/MultiviewStageState.swift` and the Kotlin twin
  (`MultiviewNetworkRestore.closingProgress`), `MultiviewCoordinator.swift` / `.kt`
  (`MultiviewCopy` picker and settings copy)
- Test: `Tests/OpenCineAppKitTests/MultiviewValuesTests.swift`, `MultiviewValuesTest.kt`

**Interfaces (Swift; Kotlin twins have the same names, enum cases upper-cased):**
```swift
public enum MultiviewSettingsCategory: String, CaseIterable, Hashable, Sendable {
    case iso, shutter, exposure, wb, focus, aperture, mode, resolution, color, audio
    public var title: String                      // iOS: "Iso" ... "WB", resolution "Format"
    public var identifier: String                 // "multiview.settings.control.<raw>"
    public static func offered(focus: Bool, aperture: Bool, photo: Bool, audio: Bool) -> [Self]
    public func locked(recording: Bool) -> Bool   // mode, resolution, color
}
public struct MultiviewCameraSettingsState: Hashable, Sendable {
    public var categories: [MultiviewSettingsCategory]
    public var recording: Bool
    public var note: String?
    public var described: Bool                    // the editor has described the camera once
}
extension MultiviewNetworkRestore { public var closingProgress: String }
extension MultiviewCopy {
    static func pickerFooter(network: String, commissioned: Bool) -> String
    static let previewUnavailable, reconnectBeforeSettings, waitingForControls,
        controlsUnavailable, lockedWhileRecording: String
}
```

- [ ] Step 1: tests `settingsCategoriesFollowTheCamerasCapabilitiesInIOSOrder`,
  `recordingLocksModeFormatAndColor`, `closeCopyFollowsWhetherCamerasReturn` (both platforms).
- [ ] Step 2: run, fail (types missing). Step 3: implement, run, commit
  `feat(appkit): shared Multiview settings categories and screen copy`.

### Task 3: MultiviewHost grows; the coordinator's screen rules

**Files:**
- Modify: `Sources/OpenCineAppKit/MultiviewCoordinator.swift`,
  `Sources/OpenCineAppKit/MultiviewCoordinator+Record.swift`, Kotlin `MultiviewCoordinator.kt`,
  `MultiviewCoordinatorRecord.kt`
- Test: `MultiviewCoordinatorTests.swift`, `MultiviewCoordinatorTest.kt`

**Interfaces:**
```swift
// MultiviewHost additions (defaults in the extension):
func readings(slot: Int) -> MultiviewTileReadings?              // nil
var editsCameraSettings: Bool { get }                            // false
var appliesAutoLUT: Bool { get }                                 // false
func lutChanged(slot: Int)                                       // no-op
func openCameraSettings(slot: Int)                               // no-op
func cameraSettings(slot: Int) -> MultiviewCameraSettingsState?  // nil
func admitsControls(slot: Int) -> Bool                           // true
// MultiviewCoordinator additions:
public func cameraName(slot: Int) -> String?
public func pickerRows() -> [MultiviewPickerRow]                 // found, qualified, not members
public var pickerFooter: String
@discardableResult public func enqueueAdd(pickerRow id: String, slot: Int) -> Bool
public var networkRestore: MultiviewNetworkRestore               // .cameraNetworks with a commissioner
public var scansNetworks: Bool
public func toggleLUT(slot: Int)                                 // member, host, journal
public func toggleLUT()                                          // every member, as one choice
public var lutOn: Bool
public func stageTile(_ slot: Int) -> MultiviewTile?             // host readings or the name only
public var programReadouts: [MultiviewReadout]?
public var toolAvailability: MultiviewToolAvailability
public var cameraSettingsSlots: [Int]
// controlsAvailable(slot:) also asks host.admitsControls(slot:)
```

- [ ] Step 1: tests (same names both): `thePickerListsFoundCamerasThatMayJoinAndAreNotMembers`,
  `pickingARowWithoutPreviewAddsItExperimentally`, `lutTogglesFollowTheMembersAndTheJournal`,
  `stageTilesUseTheHostsReadingsAndCapabilities`, `controlsWaitForWhatOnlyTheAppAdmits`.
- [ ] Step 2: run, fail. Step 3: implement; run; commit
  `feat(appkit): MultiviewHost grows into the screen's app seam`.

### Task 4: The SwiftUI screen and settings popup

**Files:**
- Create: `Sources/OpenCineAppKitApple/MultiviewScreen.swift`,
  `Sources/OpenCineAppKitApple/MultiviewCameraSettingsPanel.swift`
- Modify: `Package.swift` (AppKitApple names MonitorPresentation; its tests take
  `OpenCineCoreTestSupport`)
- Test: `Tests/OpenCineAppKitAppleTests/MultiviewScreenTests.swift` (hosted, iOS)

**Interfaces:**
```swift
@MainActor public protocol MultiviewScreenHost: MultiviewHost {
    associatedtype Picture: View; associatedtype Backdrop: ViewModifier
    associatedtype SettingsPreview: View; associatedtype SettingsControls: View
    associatedtype LiveView: View
    func picture(slot: Int, fill: Bool) -> Picture
    func backdrop(layout: MultiviewPresentationLayout, geometry: MultiviewStageGeometry, enabled: Bool) -> Backdrop
    func settingsPreview(slot: Int) -> SettingsPreview
    func settingsControls(slot: Int, category: MultiviewSettingsCategory, enabled: Bool,
        presented: @escaping () -> Bool, close: @escaping () -> Void) -> SettingsControls
    func liveView(slot: Int, exit: @escaping () -> Void) -> LiveView
    var stationBrand: StationNetworkBrand { get }
    var stationServices: StationNetworkServices { get }
    var cameraSSIDs: Set<String> { get }
    func settingsAccessibilityValue(slot: Int) -> String       // default ""
}
public struct MultiviewScreen<Link: MultiviewMemberLink, Host: MultiviewScreenHost>: View
    // init(coordinator:host:startsSession:)
public struct MultiviewCameraSettingsPanel<Link, Host>: View
    // init(coordinator:host:initialSlot:viewport:safeArea:close:)
```

- [ ] Step 1: hosted test `theScreenOpensTheWizardAndListsCamerasForAnEmptySlot` (fake coordinator
  and a host of plain views: without a configured network the wizard is named
  `multiview.networkSetup`; once configured the stage shows `multiview.add`, the picker row and its
  footer) and `theSettingsPanelShowsTheCamerasCategoriesInOrder`.
- [ ] Step 2: run on the private simulator; fail (types missing). Step 3: implement by lifting
  `MultiviewView.swift` and `MultiviewCameraSettings.swift` (Pocket, `feat/shared-multiview-3`)
  with the same modifiers; run; commit `feat(appkit): the shared Multiview screen and settings popup in SwiftUI`.

### Task 5: The Compose screen and settings popup

**Files:**
- Create: `Android/appkit/src/main/kotlin/com/opencapture/opencine/appkit/MultiviewScreen.kt`,
  `MultiviewCameraSettingsPanel.kt`

**Interfaces:**
```kotlin
public interface MultiviewScreenHost : MultiviewHost {
    @Composable public fun Picture(slot: Int, fill: Boolean)
    @Composable public fun SettingsPreview(slot: Int, modifier: Modifier)
    @Composable public fun SettingsControls(slot: Int, category: MultiviewSettingsCategory,
        locked: Boolean, maxHeight: Float, close: () -> Unit)
    @Composable public fun LiveView(slot: Int, exit: () -> Unit)
    @Composable public fun NetworkSetup(locked: StationNetwork?, cancel: () -> Unit, complete: () -> Unit)
    public val confirmsRecord ... (already in MultiviewHost)
}
@Composable public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewScreen(
    coordinator: MultiviewCoordinator<Camera, Link>, host: MultiviewScreenHost, onClose: () -> Unit)
@Composable public fun MultiviewCameraSettingsPanel(...)
```
(The Android wizard's app values are a permission gate and Android saved networks, so the host
supplies the wizard call itself; its locked page and close rules come from the screen.)

- [ ] Step 1: lift `MultiviewScreen.kt` and `MultiviewCameraSettings.kt` (Pocket Android) onto the
  coordinator and host, toward iOS (iOS copy and notes in the popup, upper-cased tabs, the shared
  close copy). Step 2: `:appkit` compiles, its tests and lint pass; commit
  `feat(appkit): the shared Multiview screen and settings popup in Compose`.

### Task 6: OpenCine docs and API snapshots

**Files:** `docs/appkit/README.md` (Multiview screen section with the capability table and the
test table), `docs/superpowers/plans/2026-11-13-shared-multiview-roadmap.md` ("Carried from Plan
4"), `atlas/api/swift/*.txt`, `Android/*/api/*.api`.

- [ ] Step 1: write docs; Step 2: `atlas api --write --build`, `updateKotlinAbi updateAndroidApi`;
  Step 3: `atlas check`; commit `docs: the shared Multiview screen` and
  `chore: API snapshots for the Multiview screen`.

### Task 7: Pocket iOS renders the shared screen

**Files (OpenPocketCine):** `ios/OpenPocketCine/MultiviewView.swift` (owner and review fixture
only), `MultiviewCameraSettings.swift` (editor only), `MultiviewTileValues.swift`,
`MultiviewSession.swift` (host conformance), delete `MultiviewNetworkSetup.swift`; xcodegen
project if files change.

- [ ] Step 1: run the base Pocket iOS unit and UI suites and the UI review screenshots on
  `feat/shared-multiview-3` (detached worktrees under the stream folder) and keep the results.
- [ ] Step 2: adopt; build; run the same suites and screenshots; compare per test and per pixel.
- [ ] Step 3: commit `refactor(ios): Multiview renders OpenCine's shared screen`.

### Task 8: Pocket Android renders the shared screen

**Files (OpenPocketCine):** `Apps/Android/app/.../multiview/MultiviewScreen.kt`,
`MultiviewCameraSettings.kt`, `MultiviewSession.kt`, `MultiviewSettingsPolicyTest.kt`,
`docs/PARITY.md`, handbook Android differences when a named difference changes.

- [ ] Step 1: categories test moves to the shared order (fails first); Step 2: adopt; Step 3:
  `:app:testDebugUnitTest --tests '*multiview*'`, `:app:lintDebug`, androidTest compile; commit
  `refactor(android): Multiview renders OpenCine's shared screen` and `docs: PARITY for the shared Multiview screen`.

### Task 9: Verification and hand-off

- [ ] OpenCine: strict-concurrency build and tests, iOS Simulator package build, Kotlin
  `:core :multicam :platform :appkit :dji` tests and lint, `atlas check`, snapshots.
- [ ] Pocket gates as in the brief; push both branches; draft PRs; report with the hardware list.
