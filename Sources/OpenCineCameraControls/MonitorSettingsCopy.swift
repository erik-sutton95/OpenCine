import Foundation

/// Operator help shared by the settings compositions (A2-36). Transport, brand, protocol and
/// camera-specific rows stay with each host; anything two apps say the same way lives here.
public enum MonitorSettingsCopy {
    public static let keepScreenAwake =
        "Keeps the screen awake while this app is active. Turn off to use the device's normal auto-lock setting. The system may still dim the screen when the device is hot."
    public static let haptics = "Short confirmation pulses for switches, settings and controls."
    public static let hdrDisplay = "Show the native monitor in HDR when the display supports it."
    /// The Feed Upscaler help on the Link tab's Processing card, in every app (A2-78).
    public static let feedUpscaler =
        "How the live-view frame is enlarged to fill the panel. The camera sends far fewer pixels than the panel has, so something always does this. Off is a plain sample, Fast is a fixed sharpening kernel, and Quality is the OS spatial upscaler.\n\nAI is different in kind: it is a machine-learning model that INFERS detail the camera never captured. It gives the sharpest-looking picture, but the fine texture it adds is invented (plausible rather than real), so it can suggest crispness the lens did not record. Judge critical focus on Quality or Fast, and treat AI as a viewing aid rather than evidence.\n\nOnly the options this device supports are shown."

    /// The HDR display row's help (A2-31): a phone panel boost, not a grade. `cameraMode` names
    /// the camera's own HDR picture mode it is not, for example "HDR/HLG color mode".
    public static func hdrPanel(cameraMode: String) -> String {
        "Outdoor panel brightness, not a grade. WAVE, HISTO, PARADE, VECTOR, zebras and false color still read the decoded camera signal, so judge exposure there, not from how bright the picture looks. Screen recording and AirPlay drop back to a normal SDR picture so the file is not HDR-boosted. This is not the camera's \(cameraMode). Off by default."
    }

    /// Automatic reports, one disclosure on every platform (A2-37). It states what the shared
    /// reporter sends: crashes and hangs, live-feed reports and session health counts, with no
    /// images, footage or location.
    public static let automaticReports =
        "Optional: send crash, hang, live-feed reports and session health counts to OpenCapture through Sentry. Off by default. Turn off anytime without losing app features. Uploads wait until you leave camera Wi-Fi. Automatic reports exclude all images. No footage or GPS location. Sentry receives the connection IP. See Reporting Privacy below."
    /// Shown in place of the false colour and zebra settings while the camera has not named its
    /// colour curve (product ruling 2026-10-16). Kotlin twin: `MonitorSettingsCopy.sourceCurveUnknown`.
    public static let sourceCurveUnknown =
        "Waiting for the camera to report its color curve. False color, zebra and LUT exposure return on their own once it does."
    /// The reliability-report paragraph of every app's bundled privacy text, the same facts as the
    /// websites: the random install identifier made on opt-in and deleted on opt-out, and the
    /// toggle's place. Kotlin twin: `MonitorSettingsCopy.reliabilityReportsPrivacy`.
    public static let reliabilityReportsPrivacy =
        "Optional reliability reports\nWith your consent, configured builds send crash, hang and feed diagnostics, app/OS/device versions and session health counts through Sentry, with a random install identifier that is created when you opt in and deleted when you opt out. Automatic reports exclude all images. No footage, screenshots, raw camera packets or GPS location are included. Sentry receives the connection IP. Event storage uses Germany. Some provider processing may occur internationally.\nTurn reporting off in Operator Setup > System at any time without losing app features. This clears pending SDK uploads and deletes the install identifier, but does not delete reports already received. Contact us privately to request deletion. The website policy explains retention, transfers and your rights."
    public static let automaticReportsUnavailable =
        "This build cannot send automatic reports. You can still share or delete reports stored on this phone."
    public static let shareDiagnostics =
        "Saves a report with connection events, warnings, and crashes. No name, location, or Wi-Fi password. Take a screenshot for TestFlight and paste the copied text into the feedback."
    public static let deleteSavedFeedReports =
        "Remove local copies of saved freeze reports. Turn off Automatic error reports to clear pending uploads. Reports already sent cannot be removed here."
    public static func sourceHelp(app: String) -> String {
        "View the \(app) project on GitHub. Opening this may leave the camera Wi-Fi if that is the only network."
    }
    public static func termsHelp(app: String) -> String { "How you can use \(app)." }
    public static func versionHelp(app: String) -> String { "Current \(app) build from the native project metadata." }

    public static func sharingSubtitle(app: String) -> String {
        "Share this feed with \(app) devices on the same camera Wi-Fi."
    }
    public static let shareThisFeed =
        "Watching devices join this camera’s Wi-Fi, then receive the shared picture from this phone."
    public static let broadcastPriority = "Steadier picture uses more delay when the radio is busy."
    public static let watcherPasscode = "Watchers enter this once. Leave empty for an open feed."
    public static let controlRequests =
        "A watcher can ask to record, focus, and change exposure. You grant or deny on this phone."

    /// Help for the account row; `service` is the upload service the host names.
    public static func accountHelp(service: String) -> String {
        "Sign in to upload clips from the share popup. \(service) needs the internet, so the phone hops off the camera Wi\u{2011}Fi for the upload."
    }
    public static let clearAllCamerasCache =
        "Removes downloaded clip files, thumbnails, and camera indexes for every camera. The on-device library is left intact."
    public static let cacheFullResolution =
        "Download the original camera file when you open a clip. Off keeps only the 720p proxy to save space. Share needs the original, so connect the camera if it is not cached."

    /// Gimbal, joystick and game controller help for cameras with a gimbal.
    public static let gimbalHaptics =
        "Short confirmation pulses for switches, settings, and gimbal limits. A connected controller also rumbles at a stop."
    public static let headTracking =
        "Experimental. The compass above the joystick on the right is Calibrate Head Lock: that AirPods pose and that gimbal pose are shared forward. Head turns set matching pan and tilt angles within the gimbal’s range. Roll is shown only. Needs AirPods with motion (Pro, 3, Max, or later) in your ears. Off by default. The same control becomes STOP and clears the lock. On-screen stick, a game controller, and Motion Control takes priority."
    public static let joystickSensitivity =
        "How far a stick throw moves the gimbal, on-screen or with a connected game controller. Small throws crawl; full throw is fastest. 4 is the captured feel. 5 reaches full speed sooner; 1 is the slowest."
    public static let virtualJoystickSize =
        "How large the on-screen stick is. Medium is the default. Large is easier to grab; Small keeps more of the picture clear."
    public static let virtualJoystickInvertPan =
        "Reverse left and right on the on-screen stick. Off is the default. A game controller is unchanged."
    public static let virtualJoystickInvertTilt =
        "Reverse up and down on the on-screen stick. Off is the default. A game controller is unchanged."
    public static let virtualJoystickDeadzone =
        "Ignore small movements near the center. The default is 8%. Increase it to make the center less sensitive."
    public static let virtualJoystickResponse =
        "Standard keeps the current feel. Linear responds evenly. Fine makes small movements gentler."
    public static let gimbalJoystick =
        "Which analog stick pans and tilts. Left is the default. The other stick does not move the gimbal."
    public static let gamepad =
        "A connected game controller. The selected gimbal joystick pans and tilts. Cross/A records. Circle/B recenters. Square/X is rotate-180. Triangle/Y tracks a face. L1/R1 jump zoom out/in. L2/R2 hold-to-zoom (deeper is faster). D-pad up/down ISO, left/right shutter. Unplug rests the stick. On-screen stick wins while you hold it."

    /// The account sign-in consent on the camera's Wi-Fi (A2-23): signing in hops to the internet
    /// through the app's one internet hop, then reconnects the camera.
    public static let accountConsentTitle = "Leave camera Wi\u{2011}Fi to sign in?"
    public static func accountConsentMessage(service: String) -> String {
        "We'll hop to home Wi\u{2011}Fi or cellular so you can sign in to \(service), then reconnect to the camera automatically."
    }
    public static let accountConsentAction = "Sign in"
    /// Asked before a Settings browser link leaves the camera's Wi-Fi (A2-22).
    public static func browserConfirmation(title: String, app: String) -> String {
        "To open \(title), \(app) will disconnect from the camera's Wi-Fi and switch to cellular or another internet-connected Wi-Fi network. You can reconnect to the camera after you finish."
    }
    /// Shown when a Settings browser link found no internet route after leaving the camera's Wi-Fi.
    public static func browserInternetFailure(app: String) -> String {
        "\(app) couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or another Wi-Fi network and try again."
    }
    /// Shown when the account hop left the camera's Wi-Fi but found no internet route.
    public static let accountInternetFailure =
        "Couldn't reach the internet after leaving the camera's Wi\u{2011}Fi. Check cellular or home Wi\u{2011}Fi."
}
