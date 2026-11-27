# OpenCine desktop: Mac-sized interface, centred feed and scroll-wheel dials

Date: 2026-11-25. These are the owner's requests after the first live pass with the toolbar build.
The calls made here are listed at the end for the owner to check.

## What the owner saw

1. The live feed is not vertically centred. It hangs under the status row, with all the spare height
   below it.
2. There are black bars above the top bar.
3. Text is very small across the whole app. It should be standard Mac size and able to follow macOS
   localization.
4. Settings that open a dial popup (ISO, shutter, WB, focus and the like) should change with the
   scroll wheel while the pointer hovers over them.

## Cause of the small text (verified)

The three module bundles have no `UIApplicationSupportsMacCatalystOptimizedForMac`. Mac Catalyst
therefore runs them in "Scaled to match iPad" mode, which draws everything at 77 %. A 13 pt label
shows at about 10 pt, and the title bar and toolbar get iPad metrics.

## Design

**1. Optimize for Mac.**

- Each module's Mac build sets `UIApplicationSupportsMacCatalystOptimizedForMac` (the "Optimize
  Interface for Mac" setting). Points then map 1:1, text shows at its real size, and the title bar
  and toolbar take native Mac heights.
- With this mode, `UIDevice.current.userInterfaceIdiom` becomes `.mac`. All shared and app code that
  branches on `.pad` (or on `.phone` versus not) is audited, and `.mac` takes the iPad, large-screen
  path wherever layout is concerned.
- Controls that the system restyles for Mac (pickers, switches, sliders) are checked on screen.
- iPhone and iPad are unchanged.
- Text sizes stay the theme's sizes. They now render at full size on the Mac. Where a size was tuned
  down to compensate for the 77 % scale, it is restored.

**2. Centred feed, no stray bars.**

- In the desktop chrome, the picture is centred both ways in the space between the status row and
  the window's bottom edge. The letterbox bars are then equal top and bottom, or left and right.
- The bottom controls keep their place over the picture area as today.
- Anything solid black between the window's top edge and the status row that is not the title bar is
  removed.
- The title bar's background matches the theme background.

**3. Scroll-wheel dials.**

- While the pointer hovers a setting that opens a dial popup, the scroll wheel steps that setting
  through the same value list the dial uses. Open popups accept the scroll wheel too.
  - Mouse: one wheel detent is one step.
  - Trackpad: deltas add up, and a step is taken every fixed distance.
  - Scrolling down or right goes to the next value, and up or left to the previous one, in the same
    direction as the dial's own drag.
- Camera writes go through the existing setter, coalesced so that a fast spin sends the latest value
  instead of every step. The Luna answers about 2 % of SET commands late or never, and the current
  write rate already sets how smooth changes feel. The coalescing interval is a parameter, with
  tests.
- A small highlight shows which setting the wheel will change while hovering.
- Mac only, through the pointer interactions that UIKit offers on Mac Catalyst (hover, plus a pan
  gesture limited to scroll types). The phone never sees it.

**4. Localization: not in this pass.**

- The shared UI holds its copy as English literals in Swift and Kotlin, on every platform.
- Making it follow the macOS language means string catalogs across shared code and three apps, on
  iOS and Android as well. That is its own project, with its own design and language list.
- This pass only keeps the new desktop strings in a form that a string catalog can take over later
  (SwiftUI `Text` with literal keys).

## How it is checked

Unit tests:

- the scroll step accumulator (detents, trackpad deltas, direction, clamping at the ends of the
  value list);
- write coalescing;
- the centred picture rect for tall and wide windows.

Owner, on hardware:

- text at normal Mac size;
- the feed centred with no stray bars;
- the wheel changes ISO, shutter and WB on hover and in the open popup;
- nothing laid out for a phone on the Mac.

## Calls for the owner to check

- "Black bars above the top bar" is read as: dead black space between the window top and the status
  row that is not the title bar, plus a title bar that is darker than the theme. If it is something
  else, a screenshot settles it.
- Direction: scroll down means the next value.
- Localization is a separate project, started once the owner names the first languages.
