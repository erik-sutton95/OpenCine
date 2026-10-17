# SIMULATED label-ladder native regression

Developer-only XcodeGen test host, never a package product or shipping camera app.
It composes the real `LadderSheet` and `MonitorValueDrum`, routes explicit label writes through
`MonitorControlModel.commit`, and records the Core test camera's actual backend wire.
The manual clock separates explicit selection, deferred submission and camera readback.
XCUITest taps the visible drum once. Accessibility and raster assertions cover unknown and
known selection, with locked and empty controls as negative cases.

Generate with `xcodegen generate` in this directory, then run the
`LadderSheetNativeRegression` scheme on a private simulator. Keep build output outside the
repository and follow the repository's simulator and verification rules. No hardware is proven.
