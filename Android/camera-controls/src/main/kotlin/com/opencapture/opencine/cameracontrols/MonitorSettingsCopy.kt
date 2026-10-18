package com.opencapture.opencine.cameracontrols

/** Operator help shared by the settings compositions (Swift `MonitorSettingsCopy`). */
public object MonitorSettingsCopy {
    /** The Feed Upscaler help on the Link tab's Processing card, in every app (A2-78). */
    public const val feedUpscaler: String =
        "How the live-view frame is enlarged to fill the panel. The camera sends far fewer pixels than the panel has, so something always does this. Off is a plain sample, Fast is a fixed sharpening kernel, and Quality is the OS spatial upscaler.\n\nAI is different in kind: it is a machine-learning model that INFERS detail the camera never captured. It gives the sharpest-looking picture, but the fine texture it adds is invented (plausible rather than real), so it can suggest crispness the lens did not record. Judge critical focus on Quality or Fast, and treat AI as a viewing aid rather than evidence.\n\nOnly the options this device supports are shown."

    public const val keepScreenAwake: String =
        "Keeps the screen awake while this app is active. Turn off to use the device's normal auto-lock setting. The system may still dim the screen when the device is hot."

    /**
     * Automatic reports, one disclosure on every platform (A2-37). It states what the shared
     * reporter sends: crashes and hangs, live-feed reports and session health counts, with no
     * images, footage or location.
     */
    public const val automaticReports: String =
        "Optional: send crash, hang, live-feed reports and session health counts to OpenCapture through Sentry. Off by default. Turn off anytime without losing app features. Uploads wait until you leave camera Wi-Fi. Automatic reports exclude all images. No footage or GPS location. Sentry receives the connection IP. See Reporting Privacy below."

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
        "Optional reliability reports\nWith your consent, configured builds send crash, hang and feed diagnostics, app/OS/device versions and session health counts through Sentry, with a random install identifier that is created when you opt in and deleted when you opt out. Automatic reports exclude all images. No footage, screenshots, raw camera packets or GPS location are included. Sentry receives the connection IP. Event storage uses Germany. Some provider processing may occur internationally.\nTurn reporting off in Operator Setup > System at any time without losing app features. This clears pending SDK uploads and deletes the install identifier, but does not delete reports already received. Contact us privately to request deletion. The website policy explains retention, transfers and your rights."
}
