package com.opencapture.opencine.watchruntime

public enum class WatchRelayConnection { DISCONNECTED, CONNECTED, NO_CAMERA }
public data class WatchRelaySourceFacts(public val connection: WatchRelayConnection, public val feedLive: Boolean)
public enum class WatchRelayAction { TOGGLE_RECORD, CAPTURE, RESUME }

/** Exact deployed Data Layer route facts; suffix parsing is common bounded transport behavior. */
public data class WatchRelayPaths(
    public val state: String, public val frame: String, public val frameAck: String,
    public val command: String, public val result: String,
) {
    public fun requestID(path: String, prefix: String): Long? {
        if (!path.startsWith("$prefix/")) return null
        val suffix = path.removePrefix("$prefix/")
        if (suffix.isEmpty() || suffix.any { !it.isDigit() }) return null
        return suffix.toLongOrNull()?.takeIf { it > 0 }
    }
    public fun path(prefix: String, request: Long): String { require(request > 0); return "$prefix/$request" }
}

public sealed interface WatchRelayMessage<out State, out Frame, out Command, out Result> {
    public data class State<Value>(public val value: Value) : WatchRelayMessage<Value, Nothing, Nothing, Nothing>
    public data class Frame<Value>(public val value: Value) : WatchRelayMessage<Nothing, Value, Nothing, Nothing>
    public data class Command<Value>(public val value: Value) : WatchRelayMessage<Nothing, Nothing, Value, Nothing>
    public data class Result<Value>(public val value: Value) : WatchRelayMessage<Nothing, Nothing, Nothing, Value>
}

/** Payload and result facts remain integration-owned; common runtime has no JSON or Google edge. */
public interface WatchRelayCodec<State, Frame, Command, Result, Timecode> {
    public val paths: WatchRelayPaths
    public fun decode(data: ByteArray): WatchRelayMessage<State, Frame, Command, Result>?
    public fun encodeState(state: State): ByteArray
    public fun encodeFrame(frame: Frame): ByteArray
    public fun encodeCommand(action: WatchRelayAction): ByteArray
    public fun encodeResult(result: Result): ByteArray
    public fun action(command: Command): WatchRelayAction
    public fun facts(state: State): WatchRelaySourceFacts
    public fun replacing(state: State, result: Result): State
    public fun error(result: Result): String?
    public fun result(accepted: Boolean, isRecording: Boolean, error: String?): Result
    public fun image(frame: Frame): ByteArray
    public fun timecode(frame: Frame): Timecode
    public fun stateMatches(first: State, second: State): Boolean
}

public fun interface WatchScheduled { public fun cancel(): Unit }
public interface WatchRuntimeScheduler {
    public fun nowMillis(): Long
    public fun schedule(afterMillis: Long, action: () -> Unit): WatchScheduled
}
public fun interface WatchMessagePort {
    public fun send(node: String, path: String, bytes: ByteArray, onFailure: (() -> Unit)?): Unit
}
public data class WatchReceiverPolicy(
    public val stateFreshnessMillis: Long = 6_000,
    public val commandTimeoutMillis: Long = 5_000,
    public val unavailableError: String,
    public val timeoutError: String,
) {
    init { require(stateFreshnessMillis > 0 && commandTimeoutMillis > 0) }
}
