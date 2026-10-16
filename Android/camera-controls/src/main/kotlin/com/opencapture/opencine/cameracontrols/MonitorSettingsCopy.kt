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

}
