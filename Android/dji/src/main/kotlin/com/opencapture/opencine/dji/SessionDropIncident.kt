package com.opencapture.opencine.dji

import com.opencapture.opencine.media.FeedIncidentSource
import com.opencapture.opencine.media.FeedRepairPhase
import com.opencapture.opencine.media.FeedRepairRecord
import com.opencapture.opencine.media.RecoveryAction
import com.opencapture.opencine.vocabulary.SessionRecoveryTrigger

/**
 * An admitted session drop as the feed incident sees it. Pocket iOS `CameraSession` twin: the
 * unexpected disconnect opens the incident, then the session repair is recorded with its trigger,
 * so the report names what dropped (`trigger`) and that the session rung brought the picture back
 * (`recoveredBy`). Sentry PA-A (build 128) had neither: a 290 s packet-stage gap read
 * `trigger=none recoveredBy=none`, indistinguishable from a decoder that never came back.
 */
internal object SessionDropIncident {
    fun record(source: FeedIncidentSource?, trigger: SessionRecoveryTrigger, nowSeconds: Double) {
        source ?: return
        source.noteUnexpectedDisconnect(nowSeconds)
        source.recordRepair(
            FeedRepairRecord(nowSeconds, RecoveryAction.SESSION.wire, FeedRepairPhase.REQUESTED, reason(trigger)),
        )
    }

    /** The Swift `SessionRecoveryTrigger` case name, the repair reason vocabulary's wire. */
    fun reason(trigger: SessionRecoveryTrigger): String =
        when (trigger) {
            SessionRecoveryTrigger.BLE_DROPPED -> "bleDropped"
            SessionRecoveryTrigger.SOFTAP_LOST -> "softAPLost"
            SessionRecoveryTrigger.DATALINK_LOST -> "datalinkLost"
            SessionRecoveryTrigger.OPERATOR_RETRY -> "operatorRetry"
            SessionRecoveryTrigger.FEED_WATCHDOG -> "feedWatchdogStall"
            SessionRecoveryTrigger.COMMAND_TIMEOUT -> "commandTimeout"
            SessionRecoveryTrigger.FIRST_PICTURE -> "firstPicture"
        }
}
