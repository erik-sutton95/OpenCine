# Spike 1: hidden module output

Date: 2026-11-05. Build: OpenZCine Catalyst module on current main, feeding the old driver (version 15),
using a 30 fps moving test picture (`ZC_DEMO_WEBCAM_TEST=1`) through the same publish path as the camera
loop. Measured with `Desktop/Tools/virtual-receiver`, 15 seconds each.

| Module state | Frames | Unique | Slate | Largest gap |
| --- | --- | --- | --- | --- |
| Window visible, frontmost | 449 | 98 | 0 | 44 ms |
| Another app frontmost | 449 | 95 | 0 | 73 ms |
| App hidden | 450 | 96 | 0 | 46 ms |
| App hidden for over 60 s (App Nap window) | 451 | 97 | 0 | 51 ms |

The receiver's hash samples a coarse pixel grid, so "unique" counts about one in four frames for this test
picture. What matters is that it stays level across states, and it does.

## Findings

- A Catalyst module keeps producing and publishing while hidden, with no App Nap slowdown over this window.
- The scene does receive `didEnterBackground` when hidden, so the real Nikon path, which stops live view on
  that signal, must not act on it while webcam output is on (Task 8).
- Not proven here: real camera frames while hidden (Task 8), and a longer hidden run.

## Decision

`tabs`, pending the owner's judgment of the real swap. The window bridge is built for real in the dock and
module (Tasks 7 and 8) rather than as throwaway code, and the owner judges that. If it fails, the fallback
is plain windows.
