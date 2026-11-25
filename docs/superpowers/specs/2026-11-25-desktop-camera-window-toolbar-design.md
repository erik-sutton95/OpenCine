# OpenCine desktop: camera window with a toolbar and status row

Date: 2026-11-25. The owner picked option A from the mockups at
<https://claude.ai/artifact/Dig7KK3neXTGsr3UQezpLb> ("A looks good"). This builds on
`2026-11-24-desktop-single-window-tabs-design.md`.

## Why

With a camera live in its tab, the phone layout of the monitor shows through on the Mac:

- The picture runs up under the title bar.
- The top strip (UI lock, card, format, log profile, mode) sits behind the window buttons and the
  tabs.
- The gear and media buttons are drawn in the title bar area. Clicks there often move the window
  instead.

The owner wants the window to feel like a desktop app while keeping the app's look.

## Goals

- The title bar is a Mac toolbar. It holds:
  - the tabs on the left;
  - the take's state and timecode;
  - real toolbar buttons for Media and Settings on the right.
- Under the title bar is one status row with what the phone shows on top of the picture:
  - link;
  - battery;
  - card;
  - format;
  - log profile;
  - mode;
  - audio meter.
- The picture starts below the status row. Nothing covers its top edge.
- The UI lock does not exist on the Mac.
- Keyboard shortcuts for the common actions.
- The same in all three modules: Pocket, Luna and Nikon Z. Same look: Sora, the theme surfaces,
  12 pt corners, the camera's accent.

## Non-goals

- A menu bar. Modules are background (accessory) apps, so that crashes stay isolated, and macOS gives
  those no menu bar.
- The inspector panel (option B) and the + tab.
- Any change on iPhone, iPad or Android.

## Design

**Desktop presentation of the live monitor.** The shared live monitor gets a desktop chrome mode. It
is on only when the app runs as a dock module on Mac (`DesktopModuleHost.current != nil`). In that mode:

- The top strip, the UI lock button and the in-picture gear and media buttons are not drawn.
- The interface is never locked.
- The picture's top edge is the bottom of the status row.
- These stay as today: the exposure strip, the record button, the gimbal joystick, DISP, the assists
  and alerts.
- Popups and sheets lay out against the new picture area.

**Status row.** A new shared view, 30 pt high, using the theme's surface chips. It shows the same
values the phone's top strip and side readouts show today, from the same presentation data. Order:
link (signal bars), battery, card, format, log profile (in the accent colour), mode, then the audio
meter at the trailing end. A value the camera does not report is left out, not shown as a dash.

**Toolbar.** The module's title bar toolbar, from left to right:

- tabs (today's tab item, restyled flat: the selected tab on a raised surface, no outer capsule);
- flexible space;
- the take state and timecode (STBY or REC in the recording colour, then the timecode);
- a separator;
- Media;
- Settings.

Media and Settings are real toolbar items with the app's own icons and a full-size click target.
They run the same actions as today's in-picture buttons. The driver notice keeps its place at the
trailing end when it shows.

**How the toolbar reaches the app.** The module host exposes desktop commands that the app's monitor
registers:

- open Settings;
- open Media;
- toggle record;
- the current take state and timecode.

Each app only wires its existing actions to them. The shared monitor owns the wiring where it can,
so that apps change as little as possible.

**Keyboard.** Key commands on the module window:

| Shortcut | Action |
|---|---|
| ⌘R | Start or stop recording |
| ⌘, | Camera settings |
| ⌘⇧M | Media |
| ⌘1 to ⌘9 | Switch to that tab (through the dock, like a tab click) |
| ⌃⇥ / ⌃⇧⇥ | Next / previous tab |
| D | Toggle display overlays (DISP), only while no text field has focus |

**Calls made for the owner to check:**

- The tab look is flattened to match the mockup.
- The audio meter is in the status row, not the toolbar.
- "D" is a single key without a modifier, like the DISP button.

## How it is checked

- Layout tests for the desktop mode: no lock, no in-picture gear or media, and the picture's top
  equals the status row's bottom.
- The phone layout is unchanged.
- Tests that status row values map from the presentation data, including missing values.
- A test of the key command table.
- Owner on hardware: each module live, toolbar buttons open Media and Settings on the first click,
  shortcuts work, nothing is hidden behind the window buttons.

## Left to the builder

- Whether the timecode is a hosted view toolbar item or text.
- The exact icon assets. Use the app's own MonitorIcon set where one exists.
- Where the desktop mode flag enters the monitor: an environment value is fine.
