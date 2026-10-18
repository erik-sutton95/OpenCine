package com.opencapture.opencine.core

/** Connection authority and arriving readings, independent of a camera's supported controls.
 * Swift twin: `MonitorConnectionPolicy`. */
public data class MonitorConnectionPolicy(
    public val ownsCameraSession: Boolean,
    public val receivesCameraMetadata: Boolean,
    public val holdsRelayControl: Boolean = false,
) {
    /** A local session or a relay token admits commands; neither invents camera support. */
    public val canDriveCamera: Boolean get() = ownsCameraSession || holdsRelayControl
    public val cameraControls: Boolean get() = canDriveCamera
    public val recordControl: Boolean get() = canDriveCamera
    /** Card transfers and source switching require the local session, even with a relay token. */
    public val mediaBrowser: Boolean get() = ownsCameraSession
    public val offersSourceSwitch: Boolean get() = ownsCameraSession
    public val focusBoxes: Boolean get() = receivesCameraMetadata
    public val focusConfirmation: Boolean get() = receivesCameraMetadata
    public val subjectDetectionBoxes: Boolean get() = receivesCameraMetadata
    public val audioMeters: Boolean get() = receivesCameraMetadata
    public val cameraTimecode: Boolean get() = receivesCameraMetadata
    public val cameraLevel: Boolean get() = receivesCameraMetadata

    public companion object {
        public val OWNING: MonitorConnectionPolicy = MonitorConnectionPolicy(true, true)
        public fun watcher(holdsControl: Boolean): MonitorConnectionPolicy =
            MonitorConnectionPolicy(false, true, holdsControl)
    }
}
