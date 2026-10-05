package com.opencapture.opencine.dji

import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentTestSource
import com.opencapture.opencine.media.FeedRepairRecord

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

    /** Reliability reporting: a camera session is open (crash and hang context). */
    fun setCameraSessionActive(active: Boolean)
    /** Feed incident recorder (snapshots, repairs, breadcrumbs). */
    val incidents: FeedIncidentSink
    fun incidentTestSource(): FeedIncidentTestSource
    fun incidentBuildIdentity(): String

    val appVersion: String
    val appBuild: String
    val sourceRevision: String
    /** Debug build: instrumentation hooks are live. */
    val debugBuild: Boolean

    /** One face detector per session (Face AF); the app owns the detection library. */
    fun createFaceDetector(): FaceDetectorPort
}

/** The app's feed incident recorder. */
interface FeedIncidentSink {
    fun beginSession(context: FeedIncidentSessionContext)
    fun endSession(nowSeconds: Double)
    fun ingestSnapshot(snapshot: FeedIncidentSnapshot)
    fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb)
    fun recordRepair(repair: FeedRepairRecord)
    fun noteDecoderGeneration(generation: Int)
    fun noteSocketGeneration(generation: Int)
    fun noteExhausted(nowSeconds: Double)
    fun noteUnexpectedDisconnect(nowSeconds: Double)
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
