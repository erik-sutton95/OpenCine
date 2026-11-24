# OpenCine desktop: one window, tabs inside the camera window

Date: 2026-11-24. Owner chose this approach (A) the same day. Builds on
`2026-11-05-opencine-desktop-design.md`; only the Tabs section changes.

## Why

On the first hardware pass the dock read as two windows: the dock's own tab strip, with the selected
camera's window held under it. Dragging moves the strip first and the camera window follows through
dock messages, so it lags; switching tabs is slow and shows the seam. The owner wants one window that
drags and switches like a native one.

## Goals

- One visible window: the selected camera's own window, with its own window buttons and the tabs in its
  title bar area.
- Dragging and resizing are native: no window follows another.
- Switching tabs shows the next camera at the same place with no visible gap or desktop flash.
- Keep one process per module (crash isolation, no shared statics) and keep the iPhone apps unchanged.

## Non-goals

- Merging modules into one process (ruled out in the 5 Nov design and again by the owner).
- Full screen, the + tab and catalog downloads (later; the tab bar leaves room for +).
- Any change to the driver, slots or frame path.

## Approaches considered

- **A, chosen: tabs drawn inside each module's window.** The dock has no visible window. Every module
  shows the same tab bar; the visible module's window is the window.
- B: all modules in one process. A real single window, but the apps' shared defaults keys, Sentry
  start, process-wide statics and USB browser singleton clash, and one crash ends every input.
- Keep the strip and make following faster: still two windows and still a seam, so it does not meet
  the goal.

## Design

**Tab bar in the module.** `DesktopModuleHost` adds a tab bar view on top of the module's window and
pushes the app's content down by the bar's height (additional safe area on the root view controller), so
no app code changes. The bar sits in a transparent, full-size-content title bar, starts after the window
buttons, and shows each module's display name from its manifest with a status dot (live or idle). It
names no camera brand; the names come from the modules. The window keeps normal buttons and is movable
and resizable.

**Messages** (`OpenCineDesktopKit`, portable):
- Dock to module: `tabs([Tab], selectedID)` whenever the list, a status or the selection changes;
  `place(frame)` for hidden modules; `show(frame)` and `hide` as today.
- Module to dock: `selectTab(id)` when a tab is clicked; `windowFrame(frame)` when the visible window
  moves or resizes (coalesced to one per display frame while dragging, and once at the end);
  `shown` once its window is on screen after `show`; `closeRequested` from the close button.

**Frame ownership.** The visible module owns the frame. The dock keeps the latest `windowFrame` and
sends `place(frame)` to the hidden modules, which keep their hidden windows at that frame. A tab switch
is then only ordering: the dock sends `show` to the new module, waits for `shown` (or 150 ms), then
sends `hide` to the old one. The new window is in front before the old one leaves, so nothing flashes.

**Focus and app behaviour.** Modules stay accessory apps (no Dock icon). The dock stays a regular app
with the Dock icon and menu bar: clicking its icon brings the visible module forward; Quit ends every
module. A module's close button sends `closeRequested`; the dock asks first if an input is in use
(as in the 5 Nov design), then quits all. Minimize applies to the visible window; switching tabs while
minimized restores at the same frame. Full screen is turned off for now.

**Dock.** The strip window and its drag tracking go. The dock keeps module processes, the driver and
the tab model, and its first launch picks a centred default frame.

## Measures

- Tab switch: time from tab click to the new window being on screen, logged by the dock; target under
  100 ms, and no frame where neither window is visible.
- Drag: no follower window exists, so nothing to measure beyond it being one native window.

## Left to the builder

- UIKit or hosted SwiftUI for the bar, its exact height and look (match the shared monitor UI theme).
- How the host finds the module's main window across scene updates (the existing AppKit bridge
  approach is fine).
- Where the default frame is stored.
