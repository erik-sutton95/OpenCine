package com.opencapture.opencine.media

enum class DecoderErrorOrigin(val wire: String) {
    CONFIGURE("configure"),
    QUEUE("queue"),
    OUTPUT("output"),
    OUTPUT_RELEASE("outputRelease"),
}

/**
 * The MediaCodec call that threw, finer than [DecoderErrorOrigin] (PA-1V: an
 * IllegalArgumentException rode a disconnect incident and nothing said which call raised it).
 * The wire values are a closed vocabulary shared with Apple's in `FeedIncidentDecoder.errorCall`.
 */
enum class DecoderErrorCall(val wire: String) {
    /** Picking and instantiating the codec (`MediaCodec.createByCodecName`). */
    CREATE_CODEC("createCodec"),
    /** Building the format and `MediaCodec.configure`. */
    CONFIGURE("configure"),
    START("start"),
    DEQUEUE_INPUT("dequeueInput"),
    GET_INPUT_BUFFER("getInputBuffer"),
    /** Copying the access unit into the codec's input buffer. */
    FILL_INPUT("fillInput"),
    QUEUE_INPUT("queueInput"),
    DEQUEUE_OUTPUT("dequeueOutput"),
    RELEASE_OUTPUT("releaseOutput"),
}

/**
 * Typed decoder failure for one codec generation. Reset with the decoder so a
 * previous lifetime cannot mark the next one wedged.
 */
data class DecoderErrorRecord(
    val origin: DecoderErrorOrigin,
    val code: String,
    val generation: Int,
    val formatGeneration: Int,
    val codec: String?,
    val width: Int,
    val height: Int,
    val inputIsIrap: Boolean?,
    val lastOutputAgeMs: Long?,
    val atElapsedMs: Long,
    val call: DecoderErrorCall? = null,
) {
    fun journalLine(): String =
        "decoder error origin=${origin.wire} call=${call?.wire ?: "none"} code=$code gen=$generation fmt=$formatGeneration " +
            "codec=${codec ?: "none"} ${width}x$height irap=${
                when (inputIsIrap) {
                    true -> 1
                    false -> 0
                    null -> -1
                }
            } outAge=${lastOutputAgeMs ?: -1}ms"
}

class DecoderErrorLifetime {
    var generation: Int = 0
        private set
    var formatGeneration: Int = 0
        private set
    var lastError: DecoderErrorRecord? = null
        private set
    var countThisGeneration: Int = 0
        private set
    private var lastJournaledClass: String? = null
    private var lastJournaledAtMs: Long = Long.MIN_VALUE / 2

    val failedThisGeneration: Boolean
        get() = lastError != null

    fun resetLifetime() {
        generation += 1
        lastError = null
        countThisGeneration = 0
        lastJournaledClass = null
        lastJournaledAtMs = Long.MIN_VALUE / 2
    }

    fun bumpFormatGeneration() {
        formatGeneration += 1
    }

    /**
     * Record the error. Returns a journalable copy for the first error and for
     * a class change immediately, then at most once per second for repeats.
     */
    fun note(record: DecoderErrorRecord, nowMs: Long): DecoderErrorRecord? {
        lastError = record
        countThisGeneration += 1
        val key = "${record.origin.wire}:${record.code}"
        val firstOrChanged = lastJournaledClass != key
        val due = nowMs - lastJournaledAtMs >= 1_000L
        if (!firstOrChanged && !due) return null
        lastJournaledClass = key
        lastJournaledAtMs = nowMs
        return record
    }
}

/** What the live decoder does about one `MediaCodec.CodecException`. */
enum class CodecFailureAction {
    /** Transient: the same call may succeed shortly. Codec and references stay. */
    RETRY,

    /** Reclaimed or recoverable: this instance is spent. Release it, keep the last picture,
     *  and mark the references lost so the host asks for an IRAP for the replacement. */
    REBUILD,

    /** Anything else: recorded. The watchdog's output-silence repair keeps ownership. */
    REPORT,
}

/**
 * Sentry (2026-10): PA-A `codec:1101` after 68 s of healthy picture and PA-P
 * `codec:0x80001001` both rode an incident that ended as a disconnect, while the
 * decoder's output thread had already exited on the first exception and left the
 * dead codec configured until 2 s of output silence. The exception's own action
 * flags say what the instance can still do; ERROR_RECLAIMED reports neither flag
 * but the instance is gone for good.
 */
object CodecFailurePolicy {
    /** `MediaCodec.CodecException.ERROR_RECLAIMED`: the resource manager took the codec back. */
    const val ERROR_RECLAIMED = 1101

    fun action(errorCode: Int, isTransient: Boolean, isRecoverable: Boolean): CodecFailureAction =
        when {
            errorCode == ERROR_RECLAIMED -> CodecFailureAction.REBUILD
            isTransient -> CodecFailureAction.RETRY
            isRecoverable -> CodecFailureAction.REBUILD
            else -> CodecFailureAction.REPORT
        }
}
