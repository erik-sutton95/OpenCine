package com.opencapture.opencine.cameracontrols

/** Operator help shared by the settings compositions (Swift `MonitorSettingsCopy`). */
public object MonitorSettingsCopy {
    public const val keepScreenAwake: String =
        "Keeps the screen awake while this app is active. Turn off to use the device's normal auto-lock setting. The system may still dim the screen when the device is hot."

    /**
     * Automatic reports, one disclosure on every platform (A2-37). It states what the shared
     * reporter sends: crashes and hangs, live-feed reports and session health counts, with no
     * images, footage or location.
     */
    public const val automaticReports: String =
        "Optional: send crash, hang, live-feed reports and session health counts to OpenCapture through Sentry. Off by default. Turn off anytime without losing app features. Uploads wait until you leave camera Wi-Fi. Automatic reports exclude all images. No footage or GPS location. Sentry receives the connection IP; stored event IP and derived geography are removed. See Reporting Privacy below."

    /**
     * Shown in place of the false colour and zebra settings while the camera has not named its colour
     * curve (product ruling 2026-10-16). Swift twin: `MonitorSettingsCopy.sourceCurveUnknown`.
     */
    public const val sourceCurveUnknown: String =
        "Waiting for the camera to report its color curve. False color, zebra and LUT exposure return on their own once it does."

    /**
     * The reliability-report paragraph of every app's bundled privacy text, the same facts as the
     * websites: the random install identifier made on opt-in and deleted on opt-out, and the toggle's place.
     */
    public const val reliabilityReportsPrivacy: String =
        "Optional reliability reports\nWith your consent, configured builds send crash, hang and feed diagnostics, app/OS/device versions and session health counts through Sentry, with a random install identifier that is created when you opt in and deleted when you opt out. Automatic reports exclude all images. No footage, screenshots, raw camera packets or GPS location are included. Sentry receives the connection IP; stored event IP and derived geography are removed. Event storage uses Germany. Some provider processing may occur internationally.\nTurn reporting off in Operator Setup > System at any time without losing app features. This clears pending SDK uploads and deletes the install identifier, but does not delete reports already received. Contact us privately to request deletion. The website policy explains retention, transfers and your rights."
}
