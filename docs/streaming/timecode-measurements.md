# Camera timecode measurements

Status: not measured yet. Task 1 of `docs/superpowers/plans/2026-11-05-rtmps-1-timecode-and-engine.md`
needs the owner's hands and one body of each brand. Part 4 (program strip, alignment, grades) is
planned from the results here; until then no pairing earns better than `Not aligned` with manual
trim, and same-brand pairings ship no better than `TC approx`.

## Method

The screen recording of an app's monitor holds both the picture and the timecode readout in the
same frame. Every camera is aimed at one screen showing a millisecond clock, so each recording gives
pairs of (clock shown in the picture, timecode shown in the readout), and `timecode minus clock` is
that camera's offset against a shared reference. One camera at a time is fine because the reference
is absolute.

Per brand: the timecode mode as reported, a 60 second recording while idle, the app's clock setting
where it exists (Nikon: on connect; Luna: `LunaCameraSession.syncClock`; Pocket: to be checked) and a
second recording, then a third recording after 30 minutes. Each recording is read at 20 frames
(`ffmpeg -i <file> -vf fps=1/3 frame-%02d.png`) for the offset's mean and spread. Luna's readout has
whole seconds, so its offset is known only to about 1 second.

Pass rule (spec): measured error under one frame at the output rate over the 30 minute run.

## Results

| Brand | Mode | Advances while idle | Follows clock | Offset before clock setting | Offset after | Offset after 30 min |
|---|---|---|---|---|---|---|
| Nikon Z | not measured | | | | | |
| DJI Pocket | not measured | | | | | |
| Insta360 Luna | not measured | | | | | |

| Pairing | Error over 30 min | Pass |
|---|---|---|
| Nikon Z and Pocket | not measured | |
| Nikon Z and Luna | not measured | |
| Pocket and Luna | not measured | |
| Same-brand pairings | not tested (the test set has one body of each brand) | |
