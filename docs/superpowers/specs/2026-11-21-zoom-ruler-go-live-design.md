# Zoom ruler and Go Live placement

Approved mockup: https://claude.ai/artifact/QdGja1g4PzSWry6ChdN2HS (version 3, owner approved 2026-11-21).

## Why

The zoom dial is a half disc that covers about a third of the live picture. The owner wants
a slim vertical ruler with the presets beside it, the same in all three apps (Pocket,
InstaCine, ZCine) on iOS and Android. The Go Live control sits top center over the picture
and looks unlike the rest of the chrome; it should live in the top right under the timecode
and match the glass chrome.

## Goals

- Replace the half disc with a vertical ruler on the trailing edge, in both orientations.
- When the ruler is open it runs nearly the full height of the screen, and the joystick
  cluster (zoom chip, gimbal button, gimbal stick, head tracking calibrate), the timecode and
  status block, and the Go Live control are hidden until it closes.
- Drag anywhere on the ruler to zoom in 0.1x steps, with a light haptic at each step.
- Ticks: short every 0.1x, longer every 0.5x, longest with a label every 1x.
- Presets sit in a column beside the ruler, on the picture side, vertically centered.
- A readout beside the top of the ruler shows the value with one decimal ("2.5x") and the
  camera's caption (for example "TELE").
- Go Live moves under the timecode in the top right (portrait: under the format readout in
  the same top right block). Idle: a glass "Go live" pill. Live: a red LIVE pill with the
  elapsed time and a stop button, and one small line under it with quality, bitrate and
  link health ("1080p · 6.0 Mbps · good").

## Non-goals

- No change to preset storage, preset save, the timed ramp, or how zoom commands reach a
  camera.
- No change to how the dial is opened (long press on the zoom chip) or closed.
- No change to the app-level Live pill shown when the monitor is not on screen.
- No change to Go Live behavior (start, stop, notices, network choice); only where it sits
  and how it looks.

## Anti-goals

- The ruler must never cover the bottom capture bar or the record button in portrait.
- Zooming must not feel coarser than today for a slow drag: 0.1x is the step, not a lag.
- Hidden chrome must come back exactly as it was when the ruler closes (no lost joystick
  state, no Go Live restart).

## Approaches

1. **Redraw the existing shared dial (chosen).** `MonitorZoomDial` (Swift, MonitorUI) and
   `MonitorZoomDisc` (Kotlin, monitor-ui) keep their callers and their value, editing,
   preset and close callbacks; only the drawing and the drag mapping change. No app uses
   the dial directly (Atlas: not used in openpocketcine, openinstacine, openzcine), so the
   apps get it through a pin bump with no app code changes.
2. A new ruler component next to the disc, with apps opting in. Rejected: the owner wants
   it everywhere, and keeping two dials doubles the twin work for nothing.
3. A per-app ruler. Rejected: the dial is shared core UI; per-app copies drift.

## Design

### Ruler (MonitorUI and monitor-ui twins)

- Always on the trailing edge. The `.bottom` attachment used for portrait goes away; the
  `attachment` parameter stays for source compatibility and is ignored, or is removed if no
  caller outside OpenCine passes it (builder checks).
- Height: portrait from below the top status row to just above the capture bar (mockup:
  13.5% to 77% of the screen); landscape from the top safe area to the bottom safe area
  (mockup: 4% to 96%). Width about 44 pt; the touch target is the full ruler plus a margin.
- Spacing is **linear in zoom factor**, so each 0.1x step is the same drag distance (my
  call, matching the approved mockup; the disc used `MonitorZoomScale`'s log mapping). The
  bottom is the minimum, the top the camera's maximum.
- Drag maps finger position to a value, rounded to 0.1x, sent through the existing
  `value` binding and `onEditing` begin and end. A haptic fires on each new 0.1x value when
  haptics are enabled.
- Very long ranges: if a 0.1x step would be under 4 pt, minor ticks are drawn every 0.5x
  instead, and the drag still rounds to 0.1x (builder's call on the exact threshold).
- Optical stops keep a highlight tick (brighter) as today.
- Preset column: the existing `MonitorZoomPresetControls` content (select, save by long
  press, ramp setting), laid out vertically beside the ruler.
- Accessibility: the ruler is an adjustable element; increment and decrement move 0.1x;
  the value is read as the label text.

### Hiding chrome while open

- Driven by the existing `interaction.zoomVisible` and `zoomMounted` (Swift) and the
  Compose equivalent. The zoom chip, gimbal button, gimbal stick, gimbal overlay, head
  tracking calibrate button, the status block holding the timecode, and the Go Live
  control fade out (same short dim animation, reduce motion respected) instead of dimming
  to 0.16, and do not take touches while hidden.

### Go Live placement and look

- `LiveStreamMonitorOverlay` (Swift) and `LiveStreamOverlay` (Kotlin) take an anchor point
  (the bottom trailing corner of the timecode block, or the format readout in portrait)
  from the live layout instead of centering over the feed. Trailing aligned under it.
- Styling uses the chrome glass (`liveChromeGlass` and the Kotlin twin), the chrome
  palette, and the chrome's type scale. Red is reserved for the live state.
- When the timecode section is turned off in display settings, the control takes the same
  top right position on its own.

### Apps

- OpenCine change first, then pin bumps in OpenPocketCine, OpenInstaCine and OpenZCine
  (iOS and Android). The ZCine pin currently waits on its iOS CI timeout (#587); this
  change rides the same pin.

## Left to the builder

- Exact point sizes, tick weights and the readout's type style within the chrome scale.
- The minor tick density threshold for long ranges.
- Where the anchor rect for Go Live comes from in each layout type, as long as it lands
  under the timecode block as in the mockup.

## Verification

- Unit tests for the linear value mapping and 0.1x rounding (both twins).
- Snapshot or UI review screenshots, portrait and landscape, open and closed, on iOS
  (`OpenPocketCineUIReview`) and Android, compared against the mockup.
- On device: drag steps and haptics feel right; chrome returns when the ruler closes; Go
  Live under the timecode while live.
