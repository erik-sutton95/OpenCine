package com.opencapture.opencine.dji

/**
 * The DJI connection and live-picture owner. Use this integration-level name when composing
 * an app. The existing JVM class name stays intact for the add/migrate/remove release policy.
 */
typealias DjiCameraSession = PocketCameraSession

/** App-owned preferences, diagnostics and face detection supplied to one DJI session. */
typealias DjiSessionHost = PocketSessionHost
