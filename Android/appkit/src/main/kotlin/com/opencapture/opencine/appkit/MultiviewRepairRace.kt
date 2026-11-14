package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MultiviewRepairResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration

/**
 * The coordinator's deadline on a member link's repair: runs [work] in [scope] against [deadline]
 * (the link's `repairDeadline`). Its own result when it ends first; [MultiviewRepairResult.Done]
 * when the deadline passes first, after cancelling it. A repair blocked in uninterruptible work
 * keeps running, but its late result is dropped: the coordinator stops treating the member as
 * recovering at the deadline. Cancelling the caller cancels [work]. Swift twin:
 * `MultiviewRepairResult.race` in `OpenCineAppKit`.
 */
public suspend fun MultiviewRepairResult.Companion.race(
    deadline: Duration,
    scope: CoroutineScope,
    work: suspend () -> MultiviewRepairResult,
): MultiviewRepairResult {
    val repair = scope.async { work() }
    try {
        return withTimeoutOrNull(deadline) { repair.await() } ?: MultiviewRepairResult.Done
    } finally {
        repair.cancel()
    }
}
