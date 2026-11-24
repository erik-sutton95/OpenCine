# OpenCine Desktop, Part 1: Dock, Shared Driver and Nikon Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One OpenCine Mac app whose Nikon Z module feeds a stable input from a new shared driver, verified with real frames in the owner's receiving app before the podcast.

**Architecture:** A native macOS dock owns the driver extension and starts one Catalyst process per camera module. Modules feed their slot's sink stream directly through CMIO. Portable rules live in `OpenCineDesktopKit`, the Apple producer and frame policy in `OpenCineVirtualCamera`.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, Mac Catalyst, AppKit, Core Media IO extensions, SystemExtensions, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-05-opencine-desktop-design.md`

## The series

| Part | Delivers |
| --- | --- |
| **1 (this plan)** | Catalyst base, Nikon module, driver, dock, verified Nikon input |
| 2 | Pocket and Luna modules, in parallel lanes, reusing this plan's seams |
| 3 | Signed catalog, **+** tab downloads, thin-app downloads, Developer ID and notarization |

Part 2 starts once Task 3 proves the hidden-module approach, and runs alongside Tasks 4 to 8.

## Clock

The owner has not yet given a show time. Plan to the earliest case until told: **show 20:00 CET on 2026-11-05, tab decision at 18:30, freeze at 19:00.** After the freeze, nothing changes on this Mac except what the owner asks for. Recompute these when the show time is known.

## Global Constraints

- Core worktree: a task-owned OpenCine worktree on branch `erik-sutton95/opencine-desktop-design`. Z worktree: create with Orca, branch of the same name, with its package sibling resolving to the Core worktree. Never edit shared checkouts.
- Conventional Commits. No co-author trailers. Never the em dash character. Stage files explicitly.
- Pushing, PRs, merging and pin moves need the owner's explicit go-ahead.
- No third-party package. iOS defaults and behavior stay unchanged: every new behavior sits behind a Catalyst guard or an explicit host value.
- `OpenCineDesktopKit` imports Foundation only. `OpenCineVirtualCamera`, the dock and the driver name no manufacturer.
- Team `4V4EGQ6LZA`. New bundle IDs: dock `com.opencapture.opencine`, driver `com.opencapture.opencine.camera`, Z module `com.opencapture.openzcine.module`. App group `4V4EGQ6LZA.com.opencapture.opencine`.
- The installed `OpenZCine.app`, `OpenZCine Camera.app` and driver version 15 stay in place until Task 9. The old driver is never deactivated or replaced before then.
- Activate the new driver as few times as possible, and never while a previous version is mid-replacement.
- Only received frames prove a webcam. Activation proves nothing.
- Every build and test run has a timeout. A stalled test is killed and only that test restarted.

## Review Focus

1. **A module crashes or hangs mid-show.** Its input shows a slate within 500 ms, the other inputs are unaffected. Test: `producerDeathOnlyAffectsItsSlot` (Task 6).
2. **OBS opens an input before the module is running or connected.** It gets a slate, not an error or black. Test: `sourceWithoutProducerShowsSlate` (Task 6).
3. **The same module launched twice, or the dock opened twice.** The second producer is refused, and the first keeps feeding. Tests: `secondProducerIsRefused` (Task 5), `dockIsSingleInstance` (Task 7).
4. **A corrupted or missing slot table.** Assignments are never silently reassigned, since saved OBS scenes bind to them. Test: `corruptTableIsPreservedNotOverwritten` (Task 4).
5. **The Mac sleeps and wakes during a session.** The module resumes feeding without a restart. Checked in Task 8's hardware list, since sleep cannot be simulated in a test.

---

### Task 1: Bring Core's Catalyst support forward

**Files:**

- Modify: as commit `f6dba6d52` does (`Package.swift`, `Sources/OpenCineApple/{CameraHotspotSystem,MonitorPlaybackAudioMeterRuntime,UVCVideoSource}.swift`, `Sources/OpenCineCameraControls/Settings/*`, `Sources/OpenCineWatch/*`)
- Create: `Sources/OpenCineApple/UVCCaptureSelection.swift`, its tests, `docs/native-runtime/mac-catalyst-capture.md` (from that commit)

**Interfaces:**

- Produces: `UVCCaptureSelection`, optional sharing groups in `MonitorOperatorSettingsConfiguration`, Catalyst guards.

- [ ] **Step 1: Cherry-pick**

Run: `git cherry-pick f6dba6d52`
Expected: one conflict, in `Sources/OpenCineApple/UVCVideoSource.swift` (`git merge-tree` already showed this).

- [ ] **Step 2: Resolve keeping both**

Keep main's newer behavior and add the commit's explicit Catalyst device and mode selection. No automatic fallback to the built-in or virtual camera on Mac.

- [ ] **Step 3: Verify**

Run: `swift test --filter "UVCCaptureSelectionTests|OpenCineAppleTests" 2>&1 | tail -5`
Expected: pass.

Run: `xcodebuild -scheme OpenCineApple -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -2`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

Complete the cherry-pick, keeping the original subject.

---

### Task 2: Rebuild the Z Catalyst port on today's main

**Files (Z worktree):**

- Apply: the October Mac Catalyst rebuild patch for OpenZCine (2026-10-22), from the maintainer's local archive
- Add from the same archive's untracked OpenZCine Mac rebuild files (2026-10-22): `ios/Runner/MacVirtualCamera.swift`, `ios/Runner/Runner-Mac.entitlements`, `scripts/macos-build.sh`, `docs/macos-host.md`. **Not** `macos/` (Tasks 5 and 6 move what is useful into OpenCine).

**Interfaces:**

- Produces: `scripts/macos-build.sh` building a signed Catalyst `Runner.app`, with the Mac bundle ID `com.opencapture.openzcine.module`, feeding `OpenZCine.VirtualCamera` (the active old driver) until Task 8 repoints it.

- [ ] **Step 1: Apply with three-way merge**

Run: `git apply --3way <the October patch>`
Expected: conflicts in `ios/Runner/Info.plist`, `ios/Runner/NativeAppRoot.swift`, `ios/Runner/StartupDesign.swift`, `justfile` (the dry run listed these four). The other 12 files apply.

- [ ] **Step 2: Resolve conflicts**

Keep main's behavior everywhere and re-add only Catalyst guards and the Sharing rows. Set the Mac bundle ID through `PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]`, so the iOS ID is untouched.

- [ ] **Step 3: Build for Catalyst**

Run: `scripts/macos-build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`. Fix new Catalyst breaks with guards only. Known candidate: code added since October around AccessorySetupKit and MetalFX.

- [ ] **Step 4: Build for iOS, unchanged**

Run: `just native-check 2>&1 | tail -3`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add <resolved files> ios/Runner/MacVirtualCamera.swift ios/Runner/Runner-Mac.entitlements scripts/macos-build.sh docs/macos-host.md
git commit -m "feat(mac): rebuild the Catalyst port on current main"
```

---

### Task 3: Spike: does a hidden module keep feeding, and do swapped windows feel like tabs?

This is throwaway code that decides the tab design. No restart and no driver change: it feeds the active old driver.

**Files:**

- Create: `Desktop/Tools/virtual-receiver/main.swift` (kept: a command-line receiver used by Tasks 6 and 8)
- Create: `docs/desktop/spike-1-results.md`

**Interfaces:**

- Produces: `virtual-receiver --uid <legacy UID> --seconds <n>`, which selects only that exact device, never a physical camera, and prints JSON `{ "frames": Int, "uniqueFrames": Int, "slateFrames": Int, "maxGapMs": Int, "width": Int, "height": Int }`. Uniqueness is a hash of sampled pixels. It exits non-zero if the device is absent.

- [ ] **Step 1: Write the receiver and prove it against the old driver**

Run with the old app closed: `virtual-receiver --uid OpenZCine.VirtualCamera --seconds 5`
Expected: `slateFrames` near `frames`, proving a real connection with no producer.

- [ ] **Step 2: Run the module on its demo feed, window visible**

Start the Task 2 build with `DemoHarness`'s feed and webcam on. Run the receiver for 30 seconds.
Expected: `uniqueFrames` is at least 90% of the feed rate and `slateFrames` is 0.

- [ ] **Step 3: Test each hidden state**

Repeat for the window covered by another app's window, moved behind a second module's window at the same frame, and the app deactivated. Log scene phase changes.
Pass: same numbers as Step 2 in every state. On failure, record which state and try `NSProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)` and treating the scene as active on Catalyst, then retest.

- [ ] **Step 4: Prove window swapping**

Build a small AppKit bridge bundle loaded by the Catalyst app, which sets a window's frame and level and orders it. Set `LSUIElement` so the module shows no Dock icon. Run two instances of the module under different test bundle IDs at the same frame, and swap them with a key press.
Record: whether `LSUIElement` works on Catalyst, swap flicker, and which app owns the menu bar.

- [ ] **Step 5: Owner judges the swap**

Ping the owner to press the key and answer: does it feel like tabs? Pass or fail is theirs. If they are unavailable by 18:30, or hidden feeding fails, ship plain windows for the show (see the spec's fallback).

- [ ] **Step 6: Write `docs/desktop/spike-1-results.md` and commit only the receiver and results**

State the decision: `tabs` or `plain windows`. Later tasks read it.

```bash
git add Desktop/Tools/virtual-receiver docs/desktop/spike-1-results.md
git commit -m "docs(desktop): record hidden module and window swap results"
```

---

### Task 4: `OpenCineDesktopKit`

**Files:**

- Create: `Sources/OpenCineDesktopKit/{VirtualCameraSlot,VirtualCameraSlotTable,ModuleManifest,DockMessage}.swift`, `Tests/OpenCineDesktopKitTests/*.swift`
- Modify: `Package.swift`, `atlas/repos/opencine/meta.json` (`layers.core`)

**Interfaces:**

- Produces (all `public`, all `Sendable`):
  - `struct VirtualCameraSlot: Hashable { let number: Int /* 1...8 */; var legacyDeviceID: String; var deviceUUID: UUID; var sourceStreamUUID: UUID; var sinkStreamUUID: UUID; var sinkStreamName: String }`, `static let all: [VirtualCameraSlot]`
  - `struct VirtualCameraSlotTable: Codable, Equatable { static let currentVersion = 1; var version: Int; var assignments: [Assignment]; struct Assignment: Codable, Equatable { let slot: Int; let moduleID: String; var displayName: String }; mutating func assign(moduleID: String, displayName: String) -> VirtualCameraSlot?; func slot(forModule: String) -> VirtualCameraSlot? }`
  - `enum VirtualCameraSlotTableFile { static func load(from: URL) throws -> VirtualCameraSlotTable; static func save(_:to:) throws }` (atomic write; on undecodable content, `load` moves the file to `<name>.corrupt` once, throws `.corrupt`, and never writes over it)
  - `struct ModuleManifest: Codable, Equatable { let id: String; let displayName: String; let inputName: String; let version: String; let minimumDockVersion: String; let bundleName: String }`, `func isCompatible(withDock: String) -> Bool`
  - `enum DockMessage: Codable, Equatable { case show(frame: WindowFrame), hide, quit }`, `enum ModuleMessage: Codable, Equatable { case ready(moduleID: String), status(ModuleStatus), crashed }`, `struct WindowFrame: Codable, Equatable { x, y, width, height: Double }`, `enum ModuleStatus: Codable, Equatable { case idle, connecting, live(cameraName: String?), failed(String) }`
  - `enum LengthPrefixedJSON { static func encode<T: Encodable>(_: T) throws -> Data; static func decodeAll<T: Decodable>(_ buffer: inout Data, maxMessageBytes: Int) throws -> [T] }`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func slotIdentifiersAreFixedForever() {
    let s = VirtualCameraSlot.all[0]
    #expect(VirtualCameraSlot.all.count == 8)
    #expect(s.legacyDeviceID == "OpenCine.Camera.1")
    #expect(s.deviceUUID.uuidString == "6F70656E-6369-4E65-8000-000000000010")
    #expect(s.sourceStreamUUID.uuidString == "6F70656E-6369-4E65-8000-000000000011")
    #expect(s.sinkStreamUUID.uuidString == "6F70656E-6369-4E65-8000-000000000012")
    #expect(s.sinkStreamName == "OpenCine.Camera.1.sink")
}
@Test func assigningTwiceKeepsTheSlot() { /* same moduleID returns slot 1 both times; updated displayName kept */ }
@Test func removedModuleNeverGivesItsSlotAway() { /* no remove API exists; a 9th module gets nil */ }
@Test func corruptTableIsPreservedNotOverwritten() throws {
    /* write "{oops" to the file; load throws .corrupt; "<name>.corrupt" holds "{oops" */
}
@Test func missingTableLoadsEmpty() throws { /* no file gives empty table, version 1 */ }
@Test func futureVersionIsRefused() { /* version 2 throws .unsupportedVersion, file untouched */ }
@Test func manifestCompatibility() { /* minimumDockVersion "1.2.0": dock "1.10.0" true, "1.1.9" false; numeric compare */ }
@Test func messagesRoundTripAcrossFragments() throws { /* two messages split at every byte offset decode to both */ }
@Test func oversizedMessageThrows() { /* length over maxMessageBytes throws, buffer not grown */ }
```

Add a source rule test as in `GyroSourceRulesTests`: Foundation only, no mutable statics, no manufacturer or app names.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OpenCineDesktopKitTests 2>&1 | tail -10`
Expected: FAIL, no such module.

- [ ] **Step 3: Implement**

Slot UUIDs are `6F70656E-6369-4E65-8000-0000000000ST`, with `S` the slot in hex and `T` 0 for device, 1 for source and 2 for sink.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OpenCineDesktopKitTests 2>&1 | tail -3 && python3 atlas/tools/atlas.py check`
Expected: all pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Package.swift atlas/repos/opencine/meta.json Sources/OpenCineDesktopKit Tests/OpenCineDesktopKitTests
git commit -m "feat(desktop): add slot table, module manifest and dock messages"
```

---

### Task 5: `OpenCineVirtualCamera`

**Files:**

- Create: `Sources/OpenCineVirtualCamera/{FrameCadence,FrameFormat,FramePolicy,ProducerAdmission,SampleEnvelope}.swift` (moved from the archive's `macos/CameraPolicy`), `VirtualCameraPublisher.swift` (from `MacVirtualCamera.swift`), `Tests/OpenCineVirtualCameraTests/*.swift` (the archive's five suites and its `scripts/mac-virtual-camera-tests/PublisherTests.swift`)
- Modify: `Package.swift`, `atlas/repos/opencine/meta.json`

**Interfaces:**

- Consumes: `VirtualCameraSlot`.
- Produces:
  - Policy types unchanged but `public`.
  - `public final class VirtualCameraPublisher: @unchecked Sendable`: `init(slot: VirtualCameraSlot)`, `var isEnabled: Bool`, `var statusText: String`, `func setEnabled(_: Bool)`, `func resetSource() -> UInt64`, `func submit(_: CVPixelBuffer, timestamp: CMTime, generation: UInt64?)`, `func submit(_: CIImage, timestamp: CMTime, generation: UInt64)`. No `shared` instance. The companion-opening code is dropped, since the dock owns the driver.

- [ ] **Step 1: Move the archive's tests in and add the failing ones**

```swift
@Test func publisherTargetsOnlyItsSlot() { /* slot 3 looks up "OpenCine.Camera.3" and its sink; never another device */ }
@Test func secondProducerIsRefused() { /* admission: second client while first holds sink is denied, first unaffected */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OpenCineVirtualCameraTests 2>&1 | tail -10`
Expected: FAIL, missing module.

- [ ] **Step 3: Implement the move**

Replace the fixed October UID and sink name with `slot` values. Guard Apple-only code with `canImport(CoreMediaIO)`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OpenCineVirtualCameraTests -Xswiftc -strict-concurrency=complete 2>&1 | tail -3`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift atlas/repos/opencine/meta.json Sources/OpenCineVirtualCamera Tests/OpenCineVirtualCameraTests
git commit -m "feat(desktop): move the virtual camera producer and policy to shared code"
```

---

### Task 6: The shared driver

**Files:**

- Create: `Desktop/project.yml`, `Desktop/OpenCineCamera/{main,CameraProvider,SlotDevice,SlotStream,SlotTableWatcher}.swift`, `Desktop/OpenCineCamera/{Info.plist,OpenCineCamera.entitlements}`, `Desktop/Tools/simulated-producer/main.swift`, `Tests/OpenCineVirtualCameraTests/SlotIsolationTests.swift`

**Interfaces:**

- Consumes: `VirtualCameraSlot`, `VirtualCameraSlotTableFile`, policy types.
- Produces: extension `com.opencapture.opencine.camera`, publishing one device per table assignment; `simulated-producer --slot <n> --seconds <n> [--die-after <n>]`, labeled SIMULATED, with a burned-in frame counter.

- [ ] **Step 1: Write the failing test**

Extract the per-slot state machine from the October `CameraDevice` so it is testable without CMIO, as `SlotOutputState` in `OpenCineVirtualCamera`.

```swift
@Test func producerDeathOnlyAffectsItsSlot() {
    var a = SlotOutputState(); var b = SlotOutputState()
    /* both admit frames; a's producer disconnects at t */
    #expect(a.output(at: t + .milliseconds(1)) == .slate(.feedOff))
    #expect(b.output(at: t + .milliseconds(1)) == .picture)
}
@Test func sourceWithoutProducerShowsSlate() { /* new state outputs .slate(.waiting), never nil */ }
@Test func staleProducerSlatesAfter500ms() { /* last frame older than 500 ms gives .slate(.waiting) */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SlotIsolationTests 2>&1 | tail -10`
Expected: FAIL, missing type.

- [ ] **Step 3: Implement `SlotOutputState` and the extension**

The provider adapts the October source. Each assignment gets its own device with a serial queue, source stream and sink stream at 1920x1080 BGRA and 30 or 60 fps. Slates read "<display name> not connected". Display names come from the table in the app group container. `SlotTableWatcher` watches the file and adds devices when an assignment appears; it never removes one while running.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SlotIsolationTests 2>&1 | tail -3`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Desktop/project.yml Desktop/OpenCineCamera Desktop/Tools/simulated-producer Sources/OpenCineVirtualCamera Tests/OpenCineVirtualCameraTests/SlotIsolationTests.swift
git commit -m "feat(desktop): add the shared driver with one device per module"
```

The hardware proof of this driver runs at the end of Task 7, when the dock can install it.

---

### Task 7: The dock

**Files:**

- Create: `Desktop/OpenCine/{OpenCineApp,DockWindow,TabStrip,DriverController,ModuleRegistry,ModuleProcess,ModuleChannel}.swift`, `Desktop/OpenCine/{Info.plist,OpenCine.entitlements}`, `Desktop/scripts/{build,install-local}.sh`
- Test: `Tests/OpenCineDesktopKitTests/ModuleRegistryTests.swift`, with `ModuleRegistry`'s rules in `OpenCineDesktopKit`

**Interfaces:**

- Consumes: Task 4's types, the spike's decision and window bridge.
- Produces:
  - `struct ModuleRegistry` in `OpenCineDesktopKit`: `init(modulesDirectory: URL, dockVersion: String)`, `func installed() throws -> [InstalledModule]`, `struct InstalledModule { manifest: ModuleManifest; bundleURL: URL; compatible: Bool }`
  - Modules live at `~/Library/Application Support/OpenCine/Modules/<id>/`, each with `module.json` and the app bundle.
  - Channel: a Unix socket at `<group container>/dock.sock`, using `LengthPrefixedJSON`.
  - `Desktop/scripts/install-local.sh <module bundle> <manifest>` copies a built module in.

- [ ] **Step 1: Write the failing registry tests**

```swift
@Test func listsModulesWithManifests() throws { /* a dir with module.json and bundle is listed */ }
@Test func skipsFolderWithoutManifest() throws { /* no crash; not listed */ }
@Test func flagsIncompatibleModule() throws { /* minimumDockVersion above dock gives compatible false */ }
@Test func badManifestDoesNotHideOthers() throws { /* one corrupt module.json; the other still listed */ }
```

Run: `swift test --filter ModuleRegistryTests 2>&1 | tail -10`
Expected: FAIL, missing type.

- [ ] **Step 2: Implement the registry and pass**

Run: `swift test --filter ModuleRegistryTests 2>&1 | tail -3`
Expected: pass.

- [ ] **Step 3: Build the dock**

- **Single instance:** a second launch activates the first and exits (`dockIsSingleInstance`, in Step 5's hardware list).
- **Tabs:** a tab per installed module, each with a status dot from `ModuleStatus`, and a **+** tab that says downloads are coming and lists what is installed. For `plain windows` from the spike, the strip becomes a launcher with the same statuses.
- **Modules:** started at launch. A crashed module shows `Failed` with a **Restart** button and is not restarted in a loop. The dock sends `show`, `hide` and `quit`.
- **Driver:** `DriverController` adapts the October `CameraExtensionController`. On first run, it explains the System Settings approval before requesting it. Installing a module assigns its slot and saves the table first.
- **Closing:** closing the window asks first if any module is live. Quitting ends every module.

- [ ] **Step 4: Build**

Run: `Desktop/scripts/build.sh 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`, with `Contents/Library/SystemExtensions/com.opencapture.opencine.camera.systemextension` embedded and both signed by team `4V4EGQ6LZA`. If signing fails for the new App IDs, ping the owner with the exact portal step.

- [ ] **Step 5: Restart, then activate once (needs the owner)**

Ping the owner, naming each step and why:

  1. Restart the Mac, which clears the 8 old driver entries waiting to uninstall.
  2. Open `/Applications/OpenCine.app` and approve the camera extension in System Settings.

Then run `systemextensionsctl list | grep opencine`.
Expected: `activated enabled`, with `OpenZCine Camera` version 15 still `activated enabled` too.

- [ ] **Step 6: Prove three inputs with simulated producers**

Assign three test modules, then for each slot run `simulated-producer --slot <n> --seconds 40`, with `virtual-receiver --uid OpenCine.Camera.<n> --seconds 30` at once. Then rerun with `--die-after 10` on slot 2.
Expected: three inputs listed with their names. `uniqueFrames` is at least 90% of the feed rate on each. In the second run, slots 1 and 3 are unaffected, while slot 2 reports `slateFrames` after its producer dies.

- [ ] **Step 7: Second launch and commit**

Open the dock again.
Expected: the first window comes forward, with no second process.

```bash
git add Desktop Sources/OpenCineDesktopKit/ModuleRegistry.swift Tests/OpenCineDesktopKitTests/ModuleRegistryTests.swift
git commit -m "feat(desktop): add the dock with tabs, driver install and module control"
```

---

### Task 8: Nikon as a module (the podcast gate)

**Files (Core worktree):**

- Modify: `Sources/OpenCineApple/MonitorVideoDemand.swift` (add neutral demand for webcam output), `Package.swift` as needed

**Files (Z worktree):**

- Create: `ios/Runner/MacModuleHost.swift` (Catalyst only): the channel client, window bridge, `LSUIElement` behavior and the publisher
- Modify: `ios/Runner/NativeAppRoot.swift` (send clean frames to `VirtualCameraPublisher` for the assigned slot; do not stop live view on Mac when hidden), `ios/Runner/MacVirtualCamera.swift` (delete: replaced), `ios/Runner.xcodeproj/project.pbxproj`
- Create: `macos/module.json`

**Interfaces:**

- Consumes: `VirtualCameraPublisher(slot:)`, `VirtualCameraSlotTableFile`, `DockMessage`, `ModuleMessage`, `LengthPrefixedJSON`.
- Produces: module `{ "id": "nikon-z", "displayName": "Nikon Z", "inputName": "OpenCine Nikon Z", "bundleName": "OpenZCine.app" }`, plus the pattern Part 2 copies for Pocket and Luna.

- [ ] **Step 1: Write the failing shared test**

```swift
@Test func webcamDemandRequestsDecodeWithNoPresentedPicture() { /* demand on with no layer attached asks for decoded samples */ }
@Test func defaultDemandIsUnchangedForPhones() { /* webcam demand off gives the same answers as before */ }
```

Run: `swift test --filter MonitorVideoDemand 2>&1 | tail -10`
Expected: FAIL, missing member.

- [ ] **Step 2: Implement and pass**

Run: `swift test --filter MonitorVideoDemand 2>&1 | tail -3`
Expected: pass.

- [ ] **Step 3: Implement the module host**

The module reads its slot from the table by module ID, and shows a clear error if none. `didEnterBackground` no longer stops live view while webcam output is on, under Catalyst only. The Sharing row controls output, on by default in a module. Connection copy points to System Settings where the Mac cannot join a network.

- [ ] **Step 4: Build, install and prove on the demo feed**

Run: `scripts/macos-build.sh 2>&1 | tail -2 && <core>/Desktop/scripts/install-local.sh <built app> macos/module.json`
Then start the dock and run `virtual-receiver --uid OpenCine.Camera.1 --seconds 30` with the tab showing, then with another tab showing.
Expected: `uniqueFrames` at least 90% of the feed rate and `slateFrames` 0, in both.

- [ ] **Step 5: Confirm iOS is unaffected**

Run: `just native-check 2>&1 | tail -3`
Expected: pass.

- [ ] **Step 6: Commit both repositories**

```bash
git add Sources/OpenCineApple/MonitorVideoDemand.swift Tests/OpenCineAppleTests
git commit -m "feat(apple): let webcam output demand decoded frames with no view"
# in the Z worktree
git add ios/Runner/MacModuleHost.swift ios/Runner/NativeAppRoot.swift ios/Runner.xcodeproj/project.pbxproj macos/module.json
git rm ios/Runner/MacVirtualCamera.swift
git commit -m "feat(mac): run OpenZCine as an OpenCine camera module"
```

- [ ] **Step 7: Publish the hands-on checklist and ping the owner**

Publish a live page (pass, skip or note per item, state readable back) with:

  1. Connect the Z by the show's route. The tab shows a live picture.
  2. `OpenCine Nikon Z` is listed in the receiving app used for the show. It shows the camera, with the chosen LUT and no overlays.
  3. Switch tabs, or cover the window: the receiver's picture keeps moving.
  4. Camera controls work while feeding.
  5. Pull the camera connection: the slate shows, and reconnecting restores the picture without restarting the receiver.
  6. Sleep and wake the Mac: the picture returns without restarting.
  7. Kill the module process: the slate shows, **Restart** in the dock restores the feed.
  8. One hour on the real setup, watching for stutter, heat and memory growth. Record `virtual-receiver` numbers at the start and end.
  9. A saved OBS scene finds the input after quitting and reopening everything.
  10. The decision: new Nikon path or old OpenZCine for the show.

- [ ] **Step 8: Read results back, fix blockers, then freeze**

Fix anything failing before the freeze time. After it, make no changes on this Mac without the owner's say-so.

---

### Task 9: Clean up after verification

Runs only after the owner has passed Task 8 and said which path they used. The old stack stays through the show if they chose it, or if anything is unresolved.

**Files:**

- Modify: `docs/desktop/README.md` (create: area guide, status, how to build and install, known limits), `AGENTS.md` (boundary bullets), `README.md`, `atlas/api/swift/*` (generated)

- [ ] **Step 1: Remove the old stack, with the owner's confirmation at the time**

From `OpenZCine Camera.app`, deactivate the old driver, then move `OpenZCine Camera.app` and `OpenZCine.app` to the Trash. The September `OpenPocketCine.app` goes after its one test launch (Part 2). Confirm with `systemextensionsctl list`.
Expected: no active `openzcine` entry; `OpenCine` still `activated enabled`.

- [ ] **Step 2: Prove the input survives**

Run: `virtual-receiver --uid OpenCine.Camera.1 --seconds 10` with the module running.
Expected: `uniqueFrames` above 0, `slateFrames` 0.

- [ ] **Step 3: Docs and API snapshots**

Run: `python3 atlas/tools/atlas.py api --write --build && python3 atlas/tools/atlas.py check && scripts/check-repository-hygiene.sh`
Expected: exit 0 each. Report status, per the guide: what changed in OpenCine, what each app gained, and why Pocket and Insta are unaffected in this part.

- [ ] **Step 4: Commit**

```bash
git add docs/desktop/README.md AGENTS.md README.md atlas/api/swift
git commit -m "docs(desktop): add the area guide and boundaries"
```
