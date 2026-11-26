# OpenCine desktop: clean tabs, the take in the feed, one set of Media and Settings, right-click, nothing under the title bar

Date: 2026-11-26. Five changes the owner approved or reported for the Mac camera window. This builds on
`2026-11-25-desktop-camera-window-toolbar-design.md` and
`2026-11-25-desktop-mac-sized-ui-and-scroll-dials-design.md`.

## 1. Tabs

What the owner saw: the tab group sat in a tall system glass capsule, the selected tab was a
separate 8 pt rounded rectangle inside it (the radii did not match), and every tab had a grey dot
that read like a list bullet.

- The tab group's toolbar item is unbordered (`NSToolbarItem.isBordered = false`), so macOS 26
  draws no glass capsule behind it. The notice item is unbordered too.
- The selected tab is one soft capsule (white at 11 % over the title bar) with full-brightness
  text. Other tabs are muted text with no fill, and a faint capsule (5 %) under the pointer.
- The capsule is 28 pt high, a standard toolbar control, centred with the window buttons. Text is
  13 pt Sora Medium (the monitor's font family).
- A status dot only where it means something (`DockTab.statusDot`): live green, connecting
  amber, failed or stopped red. An idle tab shows its name alone. Stopped keeps its "Restart"
  hint; the accessibility labels are unchanged.
- Media and Settings stay real toolbar buttons on the right, with the native glass, at the
  trailing edge: the notice item is in the toolbar only while there is a notice (it used to keep
  an empty place after Settings, a blank gap before the window's edge).

## 2. The take in the feed

- The toolbar no longer holds the take (STBY or REC and the timecode) or the separator after it.
- In desktop chrome the monitor draws the take at the top trailing corner of the picture, with
  the phone's landscape readout (`MonitorTakeReadout`: the recording chip, then the clock, under
  the readout shadow, 12 pt from the picture's edge). The landscape status row on iPhone and
  iPad now uses the same view, so both draw identically.
- Its place is a layout value, `FieldMonitorLayout.take`: a 44 pt band across the picture's top
  edge in desktop chrome, empty on a device. Floating scopes keep clear of it (it joins the status
  obstacle), and the live stream control hangs under it (`liveStreamDeck`) instead of covering
  it. Every app's monitor draws through the shared live surface, so Pocket, Luna and Nikon Z get
  it alike; Nikon Z anchors its live stream control through `liveStreamDeck` too.
- What the camera does not report is left out: no recording chip while the recording state is
  unknown, and no clock when the source sends no timecode (Nikon over an HDMI capture device),
  never a dash (`MonitorStatusPresentation.reportedClock`).
- It follows the phone's visibility: hidden with the status bar section, in command mode (the
  dashboard carries the take) and while the zoom ruler is open.
- ⌘R is unchanged. iPhone and iPad layouts do not change.

## 3. One set of Media and Settings on the cameras page

- On a Mac the cameras page leaves its own Media and Settings buttons out and keeps Multi-view
  (`CamerasPageHeaderButton.buttons(chrome:multiview:watchFeed:)`).
- The page registers its Media and Settings actions with the window's toolbar (the same desktop
  command sink the live monitor uses), so the toolbar buttons and ⌘, and ⇧⌘M work on that page
  and open what the page's buttons opened. Leaving the page clears only its own registration.
- iPhone and iPad keep their buttons.

## 4. Right-click does what a long press does

- One shared helper in MonitorUI: `View.monitorSecondaryClick(enabled:perform:)` for SwiftUI and
  `MonitorSecondaryClick.register(_:enabled:action:)` for a UIKit view. On Mac Catalyst a
  secondary click (right-click or Control-click) runs the long-press action; click-and-hold keeps
  working. On iPhone and iPad nothing is attached.
- How: one `UITapGestureRecognizer` per window with `buttonMaskRequired = .secondary`, which
  recognizes beside every other recognizer and cancels no touches. A SwiftUI view registers its
  frame through a background view that takes no touches; the click runs the smallest registered
  region under the pointer that is on screen and enabled. A first attempt attached the recognizer
  to each SwiftUI view (`UIGestureRecognizerRepresentable`); in the owner's test no right-click
  arrived, so the click is now taken at the window, before SwiftUI's gestures see it. Each click
  and each window install is logged (subsystem `com.opencapture.opencine.monitor`, category
  `secondary-click`), so a hands-on test leaves a trace.
- Existing `contextMenu` uses already open on right-click and are left as they are. A saved
  camera card on the cameras page gets a Mac right-click menu with what its "..." button offers
  (Rename, Remove); its setup chips keep their Forget menu.

Per site:

| Site | Long press | Right-click on a Mac |
|---|---|---|
| Watcher tool strip button | tool options | tool options |
| Zoom chip (`LiveZoomControls`) | continuous zoom dial | the dial |
| False color reference | false color options | the options |
| Audio meter overlay | audio options | the options |
| Ladder sheet hold (Nikon shutter) | shutter lock on the camera | the same |
| Record button (`MonitorCaptureButton`) | capture mode, where offered | the same |
| Zoom preset slot | save the current zoom | save |
| Assist palette tool | tool options | the options |
| Floating scope panel | panel options | the options |
| Media cell (browsing) | start selecting | start selecting |
| Media grid (UIKit selection) | hold to select, then sweep | selects the clicked clip |
| Camera card (cameras page) | none ("..." button) | Rename, Remove menu |
| Photo screen picture | lock or unlock focus | the same |
| Pocket and Luna assist tool row | tool options | the options |
| Command dashboard tile | hold, then drag to reorder | not wired: a drag; click-and-hold works |
| Playback frame scrub | hold, then drag to scrub | not wired: a drag; click-and-hold works |

Nikon Z's iOS sources have no long press of their own.

## 5. Nothing under the title bar

What the owner saw: the clip viewer (opened from Media) drew its top bar under the title bar, with
the window buttons over the back button and file name, the tabs over the file name and the
toolbar's Media and Settings over SHARE.

- Cause: the module window's content ran under the title bar (a full-size content view), and a
  full-screen page laid out for a landscape phone (where the top has no safe area) placed its
  corner controls at the top edge.
- Fix, in one place for all three modules (`DesktopModuleHost`): the module window no longer has a
  full-size content view, so every page, cover and sheet in the window starts below the title bar.
  The title bar is transparent over the window background, set to the theme background, so it
  still reads as one surface. The window keeps its frame when the mask changes (AppKit would
  otherwise grow it by the title bar's height).
- Covered by construction, since all of them present inside the module's window: the AppShell
  covers (Settings, Media, Multiview), the cameras and pair pages, the live monitor, the clip and
  photo viewers presented from Media (Pocket and Luna `MediaLibraryStub`, Nikon Z `MediaBrowser`:
  clip, photo and series), Nikon Z's link experience and RED download covers, the gyro screens,
  Multiview's live slot and every sheet (LUT picker and the others).
- iPhone and iPad are unchanged: the change is in the Mac module host only.

## How it is checked

- Layout tests: desktop take band at the picture's top across window shapes and picture
  aspects, live stream control below it, scopes clear of it; no take band on a device; missing
  timecode prints nothing.
- Cameras page buttons per chrome style; tab dot per state; the secondary click attaches on the
  Mac only.
- Phone and tablet layout tests unchanged.
- On the Mac: screenshots of each module window (tabs, toolbar, the cameras page and a live feed
  where a camera is on).

## Calls for the owner to check

- The take uses the phone's sizes (23 pt clock, 25 pt where the window is tablet-sized) because
  the brief asked for the phone's look, not a new one.
- The elapsed time beside STBY or REC shows as on the phone (`--:--` until the camera reports one).
- A right-click runs the action directly rather than opening a one-item menu.
