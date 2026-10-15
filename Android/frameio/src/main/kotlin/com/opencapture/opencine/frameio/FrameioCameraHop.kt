package com.opencapture.opencine.frameio

/** Whether the current camera context can safely perform an explicit Frame.io internet hop. */
enum class FrameioHopAvailability {
    READY,
    NOT_CAMERA_ACCESS_POINT,
    MISSING_SAVED_PROFILE,
    FIXTURE_UNAVAILABLE,
    ;

    val operatorMessage: String
        get() =
            when (this) {
                READY -> ""
                NOT_CAMERA_ACCESS_POINT ->
                    "This camera connection doesn't own a camera access-point binding."
                MISSING_SAVED_PROFILE ->
                    "This camera can't be rejoined automatically because its saved Wi-Fi profile or key is unavailable. Pair it again before using a Frame.io hop."
                FIXTURE_UNAVAILABLE ->
                    "Network hopping is unavailable for demo fixtures. Connect a configured camera access point to verify the real workflow."
            }
}

/** Session evidence captured only after a fresh camera connection succeeds. */
data class FrameioCameraRejoinEvidence(
    val cameraName: String,
    val cameraModel: String,
    val verifiedAtEpochMillis: Long,
)

/** Visible lifecycle of the explicit camera-AP → internet → camera-AP round trip. */
sealed interface FrameioInternetHopState {
    data object Idle : FrameioInternetHopState

    data object LeavingCamera : FrameioInternetHopState

    data object WaitingForInternet : FrameioInternetHopState

    data object Online : FrameioInternetHopState

    data object RejoiningCamera : FrameioInternetHopState

    data class Rejoined(val evidence: FrameioCameraRejoinEvidence) : FrameioInternetHopState

    data class Failed(val message: String) : FrameioInternetHopState
}

/** Prevents dismissal while the non-cancellable camera-network hand-off owns the dialog. */
fun FrameioInternetHopState.blocksDismissal(): Boolean =
    this == FrameioInternetHopState.LeavingCamera || this == FrameioInternetHopState.WaitingForInternet ||
        this == FrameioInternetHopState.RejoiningCamera

/**
 * The app's camera-network adapter, held by the Frame.io owner while a delivery context remains
 * mounted. Disconnect and rejoin are camera specific; the lease around them is shared.
 */
interface FrameioCameraHop {
    val availability: FrameioHopAvailability

    /** Disconnects the current session, then releases its AP binding after operator consent. */
    suspend fun leaveCameraNetwork(): Boolean

    /** Rejoins through the saved profile and returns only protocol-connected session evidence. */
    suspend fun rejoinCameraNetwork(): FrameioCameraRejoinEvidence?
}
