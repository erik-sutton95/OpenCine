package com.opencapture.opencine.dji

import com.opencapture.opencine.media.FeedIncidentSink
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.vocabulary.TrackingBox

/**
 * What [PocketCameraSession] needs from the app that hosts it: operator preferences, feed
 * diagnostics, build identity and the face detector. The app keeps those (and its UI); the
 * session calls them only through this interface.
 */
interface PocketSessionHost {
    /** Operator preference: shutter set as an angle (re-matched on format changes). */
    fun shutterUsesAngle(): Boolean
    fun shutterAngleDegrees(): Double
    fun setShutterAngleDegrees(degrees: Double)
    /** Operator preference: hop to the native ISO when the color mode changes. */
    fun nativeISOHopEnabled(): Boolean

    /**
     * Reliability reporting: holds reports back from a connect attempt (recovery included) until
     * the session retires and closes the returned hold.
     */
    fun beginCameraPath(): AutoCloseable
    /** Feed incident recorder (snapshots, repairs, breadcrumbs). */
    val incidents: FeedIncidentSink
    fun incidentTestSource(): FeedIncidentTestSource
    fun incidentBuildIdentity(): String

    /** Additive host slot. Legacy hosts keep the original context; adopted hosts use the shared factory. */
    fun incidentSessionContext(sessionId: String, cameraFamily: String,
        decoderGeneration: Int = 0, socketGeneration: Int = 0): FeedIncidentSessionContext =
        FeedIncidentSessionContext(sessionId, appVersion, appBuild, sourceRevision, "Android",
            android.os.Build.VERSION.RELEASE ?: "unknown", android.os.Build.MODEL ?: "unknown",
            cameraFamily, decoderGeneration = decoderGeneration, socketGeneration = socketGeneration,
            testSource = incidentTestSource(), buildIdentity = incidentBuildIdentity())

    val appVersion: String
    val appBuild: String
    val sourceRevision: String
    /** Debug build: instrumentation hooks are live. */
    val debugBuild: Boolean

    /** One face detector per session (Face AF); the app owns the detection library. */
    fun createFaceDetector(): FaceDetectorPort
}

/** A picture handed to the face detector; [release] once the detector is done with it. */
interface FaceFrame {
    fun release()
}

/** Face detection for Face AF. Frames come from the same app that supplies the detector. */
interface FaceDetectorPort {
    /** False when a frame offered now would be dropped (skip the readback). */
    fun wantsFrame(): Boolean
    fun consider(frame: FaceFrame, done: (List<TrackingBox>) -> Unit)
    fun shutdown()
}
