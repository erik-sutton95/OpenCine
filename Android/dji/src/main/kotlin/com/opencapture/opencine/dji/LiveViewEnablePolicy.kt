package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CamFov
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.FocusTrackMode
import java.util.Locale

fun phaseAllowsReconnect(phase: ConnectionPhase): Boolean =
    when (phase) {
        ConnectionPhase.IDLE,
        ConnectionPhase.SCANNING,
        ConnectionPhase.FAILED,
        ConnectionPhase.LIVE,
        -> true
        else -> false
    }

/**
 * Live-feed stall detector. UDP receive age is the stall signal; never 1 Hz `0x09/0xa8`.
 * Mirrors iOS `FeedWatchdog` + `CameraSoftAP` first-picture gates.
 */
object LiveViewEnablePolicy {
    const val STALL_MS = 2_000L
    const val ESCALATE_MS = 5_000L
    const val GOP_GRACE_MS = 8_000L
    /** Endpoint repair and decoder-rebuild picture deadline. Matches iOS 16 s. */
    const val ENDPOINT_PICTURE_GRACE_MS = 16_000L
    /** Core `enableAnswerWindow`: an unanswered encoder-pause enable escalates after this. */
    const val ENABLE_ANSWER_MS = 1_500L
    /** Core `keyframeResendInterval` / `keyframeRequestLimit` for the decoder repair. */
    const val KEYFRAME_RESEND_MS = 2_000L
    const val KEYFRAME_REQUEST_LIMIT = 2
    /** Core `maxHeldRepairCycles`: repair deadlines (~60 s) before BLE recovery may run. */
    const val MAX_HELD_REPAIR_CYCLES = 3
    const val REBUILD_BACKOFF_MS = 60_000L
    const val COOLDOWN_MS = 15_000L
    const val REBUILD_COOLDOWN_MS = 5_000L
    const val ANALOG_LIFT_STALE_MS = 1_600L
    const val COMMAND_TIMEOUT_WINDOW_MS = 5_000L
    const val COMMAND_TIMEOUT_REBUILD_COUNT = 2
    const val FIRST_PICTURE_RESEND_MS = 2_000L
    const val FORMAT_POKE_MIN_SETTLE_MS = 800L
    const val FORMAT_STALL_MS = 2_000L
    const val HANDSHAKE_RETRY_PAUSE_MS = 500L
    const val HANDSHAKE_OPEN_RETRY_LIMIT = 6
    const val HANDSHAKE_REBIND_LIMIT = 3
    const val HANDSHAKE_SENDS_PER_BIND = 20
    const val HANDSHAKE_SEND_INTERVAL_MS = 350L
    /**
     * One `DatalinkDriver.open` budget: 20×350 ms × (1+3 rebinds) + 500 ms
     * pauses, plus headroom. iOS has no envelope; 30 s raced the last rebind.
     */
    fun handshakeOpenTimeoutMs(): Long =
        HANDSHAKE_SENDS_PER_BIND * HANDSHAKE_SEND_INTERVAL_MS * (HANDSHAKE_REBIND_LIMIT + 1L) +
            HANDSHAKE_RETRY_PAUSE_MS * HANDSHAKE_REBIND_LIMIT +
            5_000L
    /** After a foreground rebuild, wait this long for an IDR before a full rejoin. */
    const val FOREGROUND_PICTURE_GRACE_MS = GOP_GRACE_MS

    private fun coreDecision(kind: String, json: String): String? {
        if (!DjiNative.isAvailable) return null
        return DjiNative.cameraSoftAPDecision(kind, json)?.takeIf { it.isNotEmpty() }
    }

    private fun coreFlag(kind: String, json: String, fallback: () -> Boolean): Boolean =
        when (coreDecision(kind, json)) {
            "true" -> true
            "false" -> false
            else -> fallback()
        }

    private fun secJson(ms: Long?): String = ms?.let { (it / 1000.0).toString() } ?: "null"

    fun shouldGiveUpOpenRetry(attempts: Int): Boolean =
        coreFlag("shouldGiveUpOpenRetry", "{\"attempts\":$attempts}") {
            attempts >= HANDSHAKE_OPEN_RETRY_LIMIT
        }

    fun shouldKickAfterHandshakeTimeout(pathReady: Boolean): Boolean =
        coreFlag("shouldKickAfterHandshakeTimeout", "{\"pathReady\":$pathReady}") { !pathReady }

    fun canSendHandshake(receiveArmed: Boolean, connectionReady: Boolean): Boolean =
        coreFlag(
            "canSendHandshake",
            "{\"receiveArmed\":$receiveArmed,\"connectionReady\":$connectionReady}",
        ) { receiveArmed && connectionReady }

    enum class Action { NONE, RESEND_ENABLE, REBUILD_DECODER, REBUILD_UDP, FULL_REJOIN }

    enum class Stage { IDLE, RESEND_ENABLE, REBUILD_DECODER, REBUILD_UDP, FULL_REJOIN, COOLDOWN }

    enum class FirstPictureStep {
        WAIT,
        RESEND_ENABLE,
        POKE_RECORDING_FORMAT,
        REBUILD_UDP,
        REJOIN,
    }

    class State {
        var stage: Stage = Stage.IDLE
        var lastActionAt: Long = 0
        var encoderPauseEnables: Int = 0

        fun reset() {
            stage = Stage.IDLE
            lastActionAt = 0
            encoderPauseEnables = 0
        }

        fun capture(): State {
            val copy = State()
            copy.restore(this)
            return copy
        }

        fun restore(other: State) {
            stage = other.stage
            lastActionAt = other.lastActionAt
            encoderPauseEnables = other.encoderPauseEnables
        }
    }

    data class Snapshot(
        val now: Long,
        val videoPackets: Int,
        val lastVideoPacketAt: Long?,
        val lastAccessUnitAt: Long?,
        val lastStatusAt: Long?,
        val lastBleNotifyAt: Long?,
        val lastRebuildAt: Long?,
        val lastEnableAt: Long,
        val pathReady: Boolean,
        val hasFormat: Boolean,
        val decoderErrors: Int,
        val live: Boolean,
        val sawPicture: Boolean,
        val lastFocusTrackAt: Long? = null,
        val lastZoomAt: Long? = null,
        val zoomPinchActive: Boolean = false,
        val lastGimbalThrowAt: Long? = null,
        val gimbalStickHeld: Boolean = false,
        val hadVideo: Boolean? = null,
        val lastCameraSetAt: Long? = null,
        val lastDecoderOutputAt: Long? = null,
        val lastPresentedAt: Long? = null,
        val decoderOutputExpected: Boolean = false,
        val referenceRecoveryNeeded: Boolean = false,
        val lastIrapAt: Long? = null,
        val repairReady: Boolean = true,
    )

    fun age(now: Long, at: Long?): Long? = at?.let { now - it }

    fun udpReceiveAlive(snap: Snapshot): Boolean {
        val video = age(snap.now, snap.lastVideoPacketAt)
        if (video != null && video < STALL_MS) return true
        val au = age(snap.now, snap.lastAccessUnitAt)
        return au != null && au < STALL_MS
    }

    fun controlReceiveAlive(snap: Snapshot): Boolean {
        val status = age(snap.now, snap.lastStatusAt) ?: return false
        return status < STALL_MS
    }

    fun hadVideo(videoPackets: Int, videoAgeMs: Long?): Boolean =
        videoPackets > 0 || videoAgeMs != null

    fun shouldHoldForGopReset(sinceEnableMs: Long?, videoAgeMs: Long?): Boolean =
        coreFlag(
            "shouldHoldForGOPReset",
            "{\"secondsSinceLastEnable\":${secJson(sinceEnableMs)},\"lastVideoPacketAge\":${secJson(videoAgeMs)}}",
        ) {
            if (sinceEnableMs == null || sinceEnableMs >= GOP_GRACE_MS) return@coreFlag false
            if (videoAgeMs != null && videoAgeMs > sinceEnableMs + STALL_MS) return@coreFlag false
            true
        }

    /** Control Center / a short app-switcher peek still has a live GOP; do not tear UDP. */
    fun shouldRecoverAfterForeground(
        secondsSinceLastPresented: Double?,
        videoFresh: Boolean = false,
        statusFresh: Boolean = false,
        stallSec: Double = STALL_MS / 1000.0,
    ): Boolean =
        coreFlag(
            "shouldRecoverAfterForeground",
            "{\"secondsSinceLastPresented\":${secondsSinceLastPresented ?: "null"},\"videoFresh\":$videoFresh,\"statusFresh\":$statusFresh}",
        ) {
            if (videoFresh || statusFresh) return@coreFlag false
            val age = secondsSinceLastPresented ?: return@coreFlag true
            age >= stallSec
        }

    fun shouldEscalateForegroundRecover(
        secondsSinceLastPresented: Double?,
        videoFresh: Boolean = false,
        statusFresh: Boolean = false,
        graceSec: Double = FOREGROUND_PICTURE_GRACE_MS / 1000.0,
    ): Boolean =
        coreFlag(
            "shouldEscalateForegroundRecover",
            "{\"secondsSinceLastPresented\":${secondsSinceLastPresented ?: "null"},\"videoFresh\":$videoFresh,\"statusFresh\":$statusFresh}",
        ) {
            if (videoFresh || statusFresh) return@coreFlag false
            val age = secondsSinceLastPresented ?: return@coreFlag true
            age >= graceSec
        }

    enum class HandshakeTimeoutStep { KEEP_SOCKET, REBIND_UDP, FAIL }

    fun handshakeTimeoutStep(
        pathReady: Boolean,
        rebindsUsed: Int,
        inboundDatagrams: Int = 0,
        rebindLimit: Int = HANDSHAKE_REBIND_LIMIT,
    ): HandshakeTimeoutStep {
        when (
            coreDecision(
                "handshakeTimeoutStep",
                "{\"pathReady\":$pathReady,\"rebindsUsed\":$rebindsUsed,\"inboundDatagrams\":$inboundDatagrams,\"rebindLimit\":$rebindLimit}",
            )
        ) {
            "keepSocket" -> return HandshakeTimeoutStep.KEEP_SOCKET
            "rebindUDP" -> return HandshakeTimeoutStep.REBIND_UDP
            "fail" -> return HandshakeTimeoutStep.FAIL
        }
        if (inboundDatagrams > 0) return HandshakeTimeoutStep.KEEP_SOCKET
        if (!pathReady) return HandshakeTimeoutStep.FAIL
        if (rebindsUsed < rebindLimit) return HandshakeTimeoutStep.REBIND_UDP
        return HandshakeTimeoutStep.FAIL
    }

    fun holdUdpRebuildGopLog(sinceEnableMs: Long?, videoAgeMs: Long?): String =
        "feed: hold UDP rebuild — GOP-reset grace lastEnable=${ageSec(sinceEnableMs)}s lastVideo=${ageSec(videoAgeMs)}s"

    fun holdUdpRebuildAfcLog(sinceSetMs: Long?, videoAgeMs: Long?): String =
        "feed: hold UDP rebuild — AF-C grace lastSet=${ageSec(sinceSetMs)}s lastVideo=${ageSec(videoAgeMs)}s"

    fun holdUdpRebuildZoomLog(sinceSetMs: Long?, videoAgeMs: Long?): String =
        "feed: hold UDP rebuild — zoom grace lastSet=${ageSec(sinceSetMs)}s lastVideo=${ageSec(videoAgeMs)}s"

    private fun ageSec(ageMs: Long?): String {
        val value = if (ageMs == null) -1.0 else ageMs / 1000.0
        return String.format(java.util.Locale.US, "%.1f", value)
    }

    fun shouldHoldBind(pathReady: Boolean, bleAgeMs: Long?): Boolean =
        pathReady && (bleAgeMs ?: Long.MAX_VALUE) < STALL_MS

    fun shouldHoldRebuildAfterRecentUdp(
        sinceRebuildMs: Long?,
        pathReady: Boolean,
        bleAgeMs: Long?,
        hadVideo: Boolean,
    ): Boolean {
        if (!hadVideo) return false
        if (!shouldHoldBind(pathReady, bleAgeMs)) return false
        val since = sinceRebuildMs ?: return false
        return since < REBUILD_BACKOFF_MS
    }

    fun enableRestartedVideo(sinceEnableMs: Long?, videoAgeMs: Long?): Boolean {
        if (sinceEnableMs == null || videoAgeMs == null) return false
        return videoAgeMs + 50 < sinceEnableMs
    }

    fun shouldTreatLiveVideoAsStale(
        lastVideoPacketAgeMs: Long?,
        hadVideo: Boolean,
        recovering: Boolean = false,
    ): Boolean =
        coreFlag(
            "shouldTreatLiveVideoAsStale",
            "{\"lastVideoPacketAge\":${secJson(lastVideoPacketAgeMs)},\"hadVideo\":$hadVideo,\"recovering\":$recovering}",
        ) {
            if (recovering) return@coreFlag true
            val age = lastVideoPacketAgeMs ?: return@coreFlag hadVideo
            age >= ANALOG_LIFT_STALE_MS
        }

    fun shouldStartFeedRecovery(rebuildInFlight: Boolean): Boolean =
        coreFlag("shouldStartFeedRecovery", "{\"rebuildInFlight\":$rebuildInFlight}") {
            !rebuildInFlight
        }

    enum class DecoderRepairStep { WAIT, RESEND_KEYFRAME, REBUILD_ENDPOINT, DEADLINE }

    /** Core `FeedWatchdog.decoderRepairStep`: resend until answered, then the endpoint. */
    fun decoderRepairStep(
        sinceRepairStartMs: Long,
        sinceEnableMs: Long,
        sinceIrapMs: Long?,
        keyframeRequests: Int,
    ): DecoderRepairStep {
        val core =
            coreDecision(
                "decoderRepairStep",
                "{\"secondsSinceRepairStart\":${sinceRepairStartMs / 1000.0}," +
                    "\"secondsSinceLastEnable\":${sinceEnableMs / 1000.0}," +
                    "\"secondsSinceLastIrap\":${secJson(sinceIrapMs)}," +
                    "\"keyframeRequests\":$keyframeRequests}",
            )
        return when (core) {
            "wait" -> DecoderRepairStep.WAIT
            "resendKeyframe" -> DecoderRepairStep.RESEND_KEYFRAME
            "rebuildEndpoint" -> DecoderRepairStep.REBUILD_ENDPOINT
            "deadline" -> DecoderRepairStep.DEADLINE
            else -> {
                if (sinceRepairStartMs >= ENDPOINT_PICTURE_GRACE_MS) return DecoderRepairStep.DEADLINE
                val answered = sinceIrapMs != null && sinceIrapMs < sinceEnableMs
                if (answered || sinceEnableMs < KEYFRAME_RESEND_MS) return DecoderRepairStep.WAIT
                if (keyframeRequests < KEYFRAME_REQUEST_LIMIT) DecoderRepairStep.RESEND_KEYFRAME
                else DecoderRepairStep.REBUILD_ENDPOINT
            }
        }
    }

    /**
     * Core `FeedWatchdog.nextSessionHoldCycles`: no BLE teardown while video arrives,
     * for at most [MAX_HELD_REPAIR_CYCLES] repair deadlines per episode. 0 releases.
     */
    fun nextSessionHoldCycles(videoAgeMs: Long?, previousCycles: Int, pictureSinceLastCycle: Boolean): Int {
        val core =
            coreDecision(
                "nextSessionHoldCycles",
                "{\"lastVideoPacketAge\":${secJson(videoAgeMs)},\"previousCycles\":$previousCycles," +
                    "\"pictureSinceLastCycle\":$pictureSinceLastCycle}",
            )?.toIntOrNull()
        if (core != null) return core
        val cycles = (if (pictureSinceLastCycle) 0 else maxOf(0, previousCycles)) + 1
        val videoLive = videoAgeMs != null && videoAgeMs < STALL_MS
        return if (videoLive && cycles < MAX_HELD_REPAIR_CYCLES) cycles else 0
    }

    fun shouldRepeatRecoverEnable(
        sinceEnableMs: Long,
        @Suppress("UNUSED_PARAMETER") sinceRebuildMs: Long?,
        @Suppress("UNUSED_PARAMETER") pathReady: Boolean,
        @Suppress("UNUSED_PARAMETER") bleAgeMs: Long?,
        hadVideo: Boolean,
        @Suppress("UNUSED_PARAMETER") holdEnableCount: Int,
        @Suppress("UNUSED_PARAMETER") videoAgeMs: Long?,
    ): Boolean =
        coreFlag(
            "shouldRepeatRecoverEnable",
            "{" +
                "\"secondsSinceLastEnable\":${sinceEnableMs / 1000.0}," +
                "\"secondsSinceLastRebuild\":${secJson(sinceRebuildMs)}," +
                "\"pathReady\":$pathReady," +
                "\"lastBleNotifyAge\":${secJson(bleAgeMs)}," +
                "\"hadVideo\":$hadVideo" +
                "}",
        ) {
            // Mid-session extra enable GOP-cuts. FeedWatchdog.tick owns that ladder.
            if (hadVideo) return@coreFlag false
            sinceEnableMs >= STALL_MS
        }

    fun shouldRebuildAfterCommandTimeouts(
        timeoutsInWindow: Int,
        downlinkFresh: Boolean,
        videoFresh: Boolean,
        rebuildInFlight: Boolean,
        sinceRebuildMs: Long?,
        statusFresh: Boolean = false,
    ): Boolean =
        coreFlag(
            "shouldRebuildAfterCommandTimeouts",
            "{" +
                "\"timeoutsInWindow\":$timeoutsInWindow," +
                "\"downlinkFresh\":$downlinkFresh," +
                "\"videoFresh\":$videoFresh," +
                "\"rebuildInFlight\":$rebuildInFlight," +
                "\"secondsSinceLastRebuild\":${secJson(sinceRebuildMs)}," +
                "\"statusFresh\":$statusFresh" +
                "}",
        ) {
            if (videoFresh) return@coreFlag false
            if (statusFresh) return@coreFlag false
            if (timeoutsInWindow < COMMAND_TIMEOUT_REBUILD_COUNT || !downlinkFresh || rebuildInFlight) {
                return@coreFlag false
            }
            if (sinceRebuildMs != null && sinceRebuildMs < REBUILD_COOLDOWN_MS) return@coreFlag false
            true
        }

    fun shouldRunFirstPictureRecover(presentedAgeMs: Long?, alreadySettled: Boolean): Boolean =
        coreFlag(
            "shouldRunFirstPictureRecover",
            "{\"secondsSinceLastPresented\":${secJson(presentedAgeMs)},\"alreadySettled\":$alreadySettled}",
        ) {
            if (alreadySettled) return@coreFlag false
            presentedAgeMs == null || presentedAgeMs >= STALL_MS
        }

    fun shouldDeferRecordingFormatPoke(
        hasKnownRecordingFormat: Boolean,
        sinceEnableMs: Long,
    ): Boolean =
        coreFlag(
            "shouldDeferRecordingFormatPoke",
            "{" +
                "\"hasKnownRecordingFormat\":$hasKnownRecordingFormat," +
                "\"secondsSinceLastEnable\":${sinceEnableMs / 1000.0}" +
                "}",
        ) { !hasKnownRecordingFormat && sinceEnableMs < GOP_GRACE_MS }

    fun shouldMarkFirstPictureSettled(presentedAgeMs: Long?, sinceEnableMs: Long): Boolean =
        coreFlag(
            "shouldMarkFirstPictureSettled",
            "{\"secondsSinceLastPresented\":${secJson(presentedAgeMs)},\"secondsSinceLastEnable\":${sinceEnableMs / 1000.0}}",
        ) {
            val presented = presentedAgeMs ?: return@coreFlag false
            presented >= 0 && presented < STALL_MS
        }

    fun shouldBeginIDRHoldOnEnable(hasPresentedPicture: Boolean): Boolean =
        coreFlag(
            "shouldBeginIDRHoldOnEnable",
            "{\"hasPresentedPicture\":$hasPresentedPicture}",
        ) { !hasPresentedPicture }

    fun shouldReleaseIDRHold(
        awaitingIDR: Boolean,
        udpReceiveAlive: Boolean,
        sinceEnableMs: Long?,
        hasPresentedPicture: Boolean,
    ): Boolean =
        coreFlag(
            "shouldReleaseIDRHold",
            "{" +
                "\"awaitingIDR\":$awaitingIDR," +
                "\"udpReceiveAlive\":$udpReceiveAlive," +
                "\"secondsSinceLastEnable\":${secJson(sinceEnableMs)}," +
                "\"hasPresentedPicture\":$hasPresentedPicture" +
                "}",
        ) {
            if (!awaitingIDR || !udpReceiveAlive || !hasPresentedPicture) return@coreFlag false
            val since = sinceEnableMs ?: return@coreFlag false
            since >= GOP_GRACE_MS
        }

    fun firstPictureStep(
        videoPackets: Int,
        enableSends: Int,
        sinceEnableMs: Long,
        videoAgeMs: Long?,
        sinceRebuildMs: Long?,
        needsRecordingFormatPoke: Boolean = false,
        alreadyPokedRecordingFormat: Boolean = false,
        recordingFormatPokeInFlight: Boolean = false,
        isRecording: Boolean = false,
        hasPresentedPicture: Boolean = false,
    ): FirstPictureStep {
        when (
            coreDecision(
                "firstPictureStep",
                "{" +
                    "\"videoPackets\":$videoPackets," +
                    "\"enableSends\":$enableSends," +
                    "\"secondsSinceLastEnable\":${sinceEnableMs / 1000.0}," +
                    "\"secondsSinceLastVideo\":${secJson(videoAgeMs)}," +
                    "\"secondsSinceLastRebuild\":${secJson(sinceRebuildMs)}," +
                    "\"needsRecordingFormatPoke\":$needsRecordingFormatPoke," +
                    "\"alreadyPokedRecordingFormat\":$alreadyPokedRecordingFormat," +
                    "\"recordingFormatPokeInFlight\":$recordingFormatPokeInFlight," +
                    "\"isRecording\":$isRecording," +
                    "\"hasPresentedPicture\":$hasPresentedPicture" +
                    "}",
            )
        ) {
            "wait" -> return FirstPictureStep.WAIT
            "resendEnable" -> return FirstPictureStep.RESEND_ENABLE
            "pokeRecordingFormat" -> return FirstPictureStep.POKE_RECORDING_FORMAT
            "rebuildUDP" -> return FirstPictureStep.REBUILD_UDP
            "rejoin" -> return FirstPictureStep.REJOIN
        }
        if (hasPresentedPicture) return FirstPictureStep.WAIT
        if (enableSends < 1) return FirstPictureStep.RESEND_ENABLE
        if (recordingFormatPokeInFlight) return FirstPictureStep.WAIT
        if (sinceEnableMs < FIRST_PICTURE_RESEND_MS) return FirstPictureStep.WAIT
        val had = hadVideo(videoPackets, videoAgeMs)
        if (shouldPokeRecordingFormat(
                needsPoke = needsRecordingFormatPoke,
                alreadyPoked = alreadyPokedRecordingFormat,
                isRecording = isRecording,
                hadVideo = had,
                enableSends = enableSends,
                sinceEnableMs = sinceEnableMs,
            )
        ) {
            return FirstPictureStep.POKE_RECORDING_FORMAT
        }
        val videoFresh = had && (videoAgeMs ?: Long.MAX_VALUE) < STALL_MS
        if (!had) {
            if (sinceEnableMs < GOP_GRACE_MS) return FirstPictureStep.WAIT
            if (enableSends >= 4) return FirstPictureStep.REJOIN
            if (enableSends >= 2) {
                if (sinceRebuildMs != null && sinceRebuildMs < REBUILD_COOLDOWN_MS) {
                    return FirstPictureStep.WAIT
                }
                return FirstPictureStep.REBUILD_UDP
            }
            return FirstPictureStep.RESEND_ENABLE
        }
        if (sinceEnableMs < GOP_GRACE_MS) {
            if (videoFresh && enableSends == 1 && sinceEnableMs >= ESCALATE_MS) {
                return FirstPictureStep.RESEND_ENABLE
            }
            return FirstPictureStep.WAIT
        }
        if (videoFresh) {
            if (enableSends == 1) return FirstPictureStep.RESEND_ENABLE
            // Match CameraSoftAP: fresh P-frames cannot keep a missed first IRAP
            // waiting forever after the one resend. The rejoin owner is bounded.
            if (sinceEnableMs >= ENDPOINT_PICTURE_GRACE_MS) return FirstPictureStep.REJOIN
            return FirstPictureStep.WAIT
        }
        if (sinceRebuildMs != null && sinceRebuildMs < REBUILD_COOLDOWN_MS) return FirstPictureStep.WAIT
        if (enableSends >= 4) return FirstPictureStep.REJOIN
        if (sinceRebuildMs != null) return FirstPictureStep.REJOIN
        return FirstPictureStep.REBUILD_UDP
    }

    /** Pocket 3: SET 1080 then boot 4K before tearing UDP. Not Pocket 4. */
    fun shouldPokeRecordingFormat(
        needsPoke: Boolean,
        alreadyPoked: Boolean,
        isRecording: Boolean,
        hadVideo: Boolean,
        enableSends: Int,
        sinceEnableMs: Long,
    ): Boolean =
        coreFlag(
            "shouldPokeRecordingFormat",
            "{" +
                "\"needsPoke\":$needsPoke," +
                "\"alreadyPoked\":$alreadyPoked," +
                "\"isRecording\":$isRecording," +
                "\"hadVideo\":$hadVideo," +
                "\"enableSends\":$enableSends," +
                "\"secondsSinceLastEnable\":${sinceEnableMs / 1000.0}" +
                "}",
        ) {
            if (!needsPoke || alreadyPoked || isRecording || enableSends < 1) return@coreFlag false
            if (sinceEnableMs < FIRST_PICTURE_RESEND_MS) return@coreFlag false
            if (!hadVideo) return@coreFlag true
            sinceEnableMs >= ESCALATE_MS
        }

    /**
     * Leftover TRAIL P-frames still arriving: ask for IDR, keep the socket.
     * [videoPackets] > 0 with a stale [videoAgeMs] is a dead receive; rebuild UDP.
     * Frozen pkts=375 then three enable resends delayed first picture ~32 s.
     */
    fun shouldKeepUdpForLeftoverGop(
        noPicture: Boolean,
        videoPackets: Int,
        videoAgeMs: Long?,
    ): Boolean {
        if (!noPicture || videoPackets <= 0) return false
        val age = videoAgeMs ?: return false
        return age < STALL_MS
    }

    fun shouldIngestLiveVideo(ingestArmed: Boolean): Boolean = ingestArmed

    /**
     * Settings / media covering the monitor is not a leftover-GOP gate.
     * Dropping `0x02` while UDP stays live blacks the well on return (#177).
     */
    fun shouldIngestLiveVideo(
        ingestArmed: Boolean,
        browsingMedia: Boolean,
        operatorOverlayHeld: Boolean,
    ): Boolean {
        // browsingMedia / operatorOverlayHeld are lockstep with CameraSoftAP.
        // Overlay/browse must not drop 0x02. Pocket has no periodic GOP (#177).
        if (browsingMedia || operatorOverlayHeld) return ingestArmed
        return ingestArmed
    }

    /** Pocket: `0x02/0x68` `08` immediately before `0x09/0xa8`. Not Nano. */
    fun shouldSendLiveViewPrepare(usesNanoLiveViewGate: Boolean): Boolean =
        coreFlag(
            "shouldSendLiveViewPrepare",
            "{\"usesNanoLiveViewGate\":$usesNanoLiveViewGate}",
        ) { !usesNanoLiveViewGate }

    /** `0x02/0x0c` is gallery enter/exit; not live-start. Matches iOS / handbook. */
    fun shouldExitPlaybackBeforeLiveEnable(inPlayback: Boolean): Boolean =
        coreFlag("shouldExitPlaybackBeforeLiveEnable", "{\"inPlayback\":$inPlayback}") { inPlayback }

    fun shouldClearForegroundRecoverWithoutRebuild(holdsMonitor: Boolean): Boolean =
        coreFlag(
            "shouldClearForegroundRecoverWithoutRebuild",
            "{\"holdsMonitor\":$holdsMonitor}",
        ) { holdsMonitor }

    fun shouldContinueFirstPictureAfterStrayPlayback(hasPicture: Boolean): Boolean =
        coreFlag(
            "shouldContinueFirstPictureAfterStrayPlayback",
            "{\"hasPicture\":$hasPicture}",
        ) { !hasPicture }

    fun shouldKeepaliveRebuildUDP(
        flowNeedsRebuild: Boolean,
        rebuildInFlight: Boolean,
        sinceRebuildMs: Long?,
        videoFresh: Boolean = false,
        sawPicture: Boolean = true,
        statusFresh: Boolean = false,
        sinceEnableMs: Long? = null,
        pathReady: Boolean = true,
    ): Boolean =
        coreFlag(
            "shouldKeepaliveRebuildUDP",
            "{" +
                "\"flowNeedsRebuild\":$flowNeedsRebuild," +
                "\"rebuildInFlight\":$rebuildInFlight," +
                "\"secondsSinceLastRebuild\":${secJson(sinceRebuildMs)}," +
                "\"videoFresh\":$videoFresh," +
                "\"sawPicture\":$sawPicture," +
                "\"statusFresh\":$statusFresh," +
                "\"secondsSinceLastEnable\":${secJson(sinceEnableMs)}," +
                "\"pathReady\":$pathReady" +
                "}",
        ) {
            if (!sawPicture) return@coreFlag false
            if (!pathReady) return@coreFlag false
            if (!flowNeedsRebuild || rebuildInFlight || videoFresh) return@coreFlag false
            if (statusFresh) return@coreFlag false
            if (shouldHoldForGopReset(sinceEnableMs, null)) return@coreFlag false
            if (sinceRebuildMs != null && sinceRebuildMs < REBUILD_COOLDOWN_MS) return@coreFlag false
            true
        }

    fun shouldForceEnableAfterUDPRebuild(hadVideo: Boolean): Boolean =
        coreFlag("shouldForceEnableAfterUDPRebuild", "{\"hadVideo\":$hadVideo}") { !hadVideo }

    fun shouldRearmLiveIngestAfterUDPRebuild(wasAccepting: Boolean): Boolean =
        coreFlag(
            "shouldRearmLiveIngestAfterUDPRebuild",
            "{\"wasAccepting\":$wasAccepting}",
        ) { wasAccepting }

    fun shouldSendRecoverEnable(pathReady: Boolean, decoderReady: Boolean): Boolean =
        coreFlag(
            "shouldSendRecoverEnable",
            "{\"pathReady\":$pathReady,\"decoderReady\":$decoderReady}",
        ) { pathReady && decoderReady }

    fun shouldCommitLiveHandshake(
        driverOwned: Boolean,
        isClosed: Boolean,
        isCancelled: Boolean,
    ): Boolean =
        coreFlag(
            "shouldCommitLiveHandshake",
            "{\"driverOwned\":$driverOwned,\"isClosed\":$isClosed,\"isCancelled\":$isCancelled}",
        ) { driverOwned && !isClosed && !isCancelled }

    fun shouldReuseDatalink(isClosed: Boolean): Boolean =
        coreFlag("shouldReuseDatalink", "{\"isClosed\":$isClosed}") { !isClosed }

    /** Match the portable watchdog: upstream progress cannot renew a downstream stall. */
    private fun shouldHoldForControlGrace(snap: Snapshot, stalledStageAge: Long?): Boolean {
        val stageAgeSec = stalledStageAge?.div(1000.0)
        fun withinGrace(graceSec: Double): Boolean =
            stageAgeSec == null || stageAgeSec < STALL_MS / 1000.0 + graceSec
        return CameraCommands.shouldHoldCameraSetWatchdog(
            age(snap.now, snap.lastCameraSetAt)?.div(1000.0), stageAgeSec,
        ) || (withinGrace(FocusTrackMode.VIDEO_GRACE_SEC) &&
            FocusTrackMode.shouldHoldWatchdog(age(snap.now, snap.lastFocusTrackAt)?.div(1000.0))) ||
            snap.zoomPinchActive ||
            (withinGrace(CamFov.VIDEO_GRACE_SEC) &&
                CamFov.shouldHoldWatchdog(age(snap.now, snap.lastZoomAt)?.div(1000.0))) ||
            CameraCommands.shouldHoldGimbalWatchdog(
                age(snap.now, snap.lastGimbalThrowAt)?.div(1000.0), stageAgeSec, snap.gimbalStickHeld,
            )
    }

    fun tick(state: State, snap: Snapshot): Action {
        if (!snap.live) {
            state.reset()
            return Action.NONE
        }
        if (!snap.pathReady || !snap.repairReady) return Action.NONE

        val outputAt = snap.lastDecoderOutputAt ?: snap.lastPresentedAt
        val outputAge = age(snap.now, outputAt) ?: 0L
        val decoderSilent =
            snap.decoderOutputExpected && snap.sawPicture && outputAge >= STALL_MS
        val knownReferenceLoss =
            snap.decoderOutputExpected && snap.sawPicture && snap.referenceRecoveryNeeded
        val decoderNeedsRepair = decoderSilent || knownReferenceLoss
        val presentedAge = age(snap.now, snap.lastPresentedAt) ?: 0L
        val auAge = age(snap.now, snap.lastAccessUnitAt)
        val assemblyStalled =
            snap.sawPicture &&
                udpReceiveAlive(snap) &&
                auAge != null &&
                auAge >= STALL_MS &&
                presentedAge >= STALL_MS &&
                (!snap.decoderOutputExpected || decoderSilent)
        // An early loss repair must not accept still-young pre-action output,
        // or IRAP submission without output, as completion of its deadline.
        val outputAfterAction = outputAt != null && outputAt > state.lastActionAt
        if (state.stage == Stage.REBUILD_DECODER && (decoderNeedsRepair || !outputAfterAction)) {
            if (snap.now - state.lastActionAt >= ENDPOINT_PICTURE_GRACE_MS) {
                return fire(state, Action.FULL_REJOIN, snap.now)
            }
            return Action.NONE
        }

        val sinceEnable = if (snap.lastEnableAt == 0L) null else snap.now - snap.lastEnableAt
        val videoAge = age(snap.now, snap.lastVideoPacketAt)
        if (udpReceiveAlive(snap) && !assemblyStalled) {
            // Lost parameter sets are restored by this existing repair's enable.
            // Requiring format here strands an established decoder on inter-frames.
            if (decoderNeedsRepair &&
                (auAge ?: Long.MAX_VALUE) < STALL_MS
            ) {
                // Twin of FeedWatchdog: cooldown ends, and an IRAP after the last
                // enable answered it, so a new loss gets its own request.
                if ((state.stage == Stage.FULL_REJOIN || state.stage == Stage.COOLDOWN) &&
                    snap.now - state.lastActionAt < COOLDOWN_MS
                ) {
                    return Action.NONE
                }
                val irapAnsweredEnable =
                    snap.lastIrapAt != null && snap.lastEnableAt != 0L && snap.lastIrapAt > snap.lastEnableAt
                if (!irapAnsweredEnable && shouldHoldForGopReset(sinceEnable, videoAge)) return Action.NONE
                if (shouldHoldForControlGrace(snap, outputAge)) return Action.NONE
                return fire(state, Action.REBUILD_DECODER, snap.now)
            }
            state.reset()
            return Action.NONE
        }
        if (shouldHoldForGopReset(sinceEnable, videoAge)) return Action.NONE
        if (shouldHoldForControlGrace(snap, if (assemblyStalled) auAge else videoAge)) {
            return Action.NONE
        }

        val had = snap.hadVideo ?: hadVideo(snap.videoPackets, videoAge)
        if (!had) {
            if (state.stage != Stage.IDLE && snap.now - state.lastActionAt < ESCALATE_MS) {
                return Action.NONE
            }
            return when (state.stage) {
                Stage.IDLE -> fire(state, Action.RESEND_ENABLE, snap.now)
                Stage.RESEND_ENABLE -> fire(state, Action.REBUILD_UDP, snap.now)
                Stage.REBUILD_DECODER, Stage.REBUILD_UDP, Stage.FULL_REJOIN, Stage.COOLDOWN -> {
                    state.stage = Stage.COOLDOWN
                    state.lastActionAt = snap.now
                    Action.NONE
                }
            }
        }

        if (state.stage == Stage.FULL_REJOIN) {
            state.stage = Stage.COOLDOWN
            state.lastActionAt = snap.now
            return Action.NONE
        }

        if (assemblyStalled || (controlReceiveAlive(snap) && !udpReceiveAlive(snap))) {
            // Twin of FeedWatchdog: an unanswered enable escalates after ENABLE_ANSWER_MS.
            val rungWait = if (state.stage == Stage.RESEND_ENABLE) ENABLE_ANSWER_MS else ESCALATE_MS
            if (state.stage != Stage.IDLE && snap.now - state.lastActionAt < rungWait) {
                return Action.NONE
            }
            if (state.encoderPauseEnables < 1) {
                state.encoderPauseEnables += 1
                return fire(state, Action.RESEND_ENABLE, snap.now)
            }
            val bleAge = age(snap.now, snap.lastBleNotifyAt)
            val sinceRebuild = age(snap.now, snap.lastRebuildAt)
            if (shouldHoldRebuildAfterRecentUdp(sinceRebuild, snap.pathReady, bleAge, had)) {
                return Action.NONE
            }
            if (state.stage == Stage.REBUILD_UDP) {
                return fire(state, Action.FULL_REJOIN, snap.now)
            }
            return fire(state, Action.REBUILD_UDP, snap.now)
        }

        val bleAge = age(snap.now, snap.lastBleNotifyAt)
        val sinceRebuild = age(snap.now, snap.lastRebuildAt)
        if (shouldHoldRebuildAfterRecentUdp(sinceRebuild, snap.pathReady, bleAge, had)) {
            if (state.stage == Stage.IDLE) {
                state.stage = Stage.COOLDOWN
                state.lastActionAt = snap.now
            }
            return Action.NONE
        }

        if (state.stage == Stage.COOLDOWN) {
            if (shouldHoldBind(snap.pathReady, bleAge)) return Action.NONE
            if (snap.now - state.lastActionAt >= COOLDOWN_MS) {
                return fire(state, Action.REBUILD_UDP, snap.now)
            }
            return Action.NONE
        }

        if (state.stage != Stage.IDLE && snap.now - state.lastActionAt < ESCALATE_MS) {
            return Action.NONE
        }
        return when (state.stage) {
            Stage.IDLE, Stage.RESEND_ENABLE, Stage.REBUILD_DECODER ->
                fire(state, Action.REBUILD_UDP, snap.now)
            Stage.REBUILD_UDP -> fire(state, Action.FULL_REJOIN, snap.now)
            Stage.FULL_REJOIN, Stage.COOLDOWN -> {
                state.stage = Stage.COOLDOWN
                state.lastActionAt = snap.now
                Action.NONE
            }
        }
    }

    private fun fire(state: State, action: Action, now: Long): Action {
        state.stage =
            when (action) {
                Action.RESEND_ENABLE -> Stage.RESEND_ENABLE
                Action.REBUILD_DECODER -> Stage.REBUILD_DECODER
                Action.REBUILD_UDP -> Stage.REBUILD_UDP
                Action.FULL_REJOIN -> Stage.FULL_REJOIN
                Action.NONE -> state.stage
            }
        state.lastActionAt = now
        return action
    }
}
