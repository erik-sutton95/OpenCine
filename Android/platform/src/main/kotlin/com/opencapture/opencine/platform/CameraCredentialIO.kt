package com.opencapture.opencine.platform

import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/**
 * Runs one blocking secure-storage operation (Keystore unseal, preferences) off the caller's
 * thread, for every integration that keeps camera Wi-Fi credentials. The caller supplies its
 * captured connection: only the existing connection Job and [isCurrent] admit entry and
 * publication; no IO is owned here. An entered [transaction] keeps its original completion, but an
 * expired caller gets no result.
 */
suspend fun <Result> withCredentialIO(
    isCurrent: () -> Boolean,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
    transaction: Mutex? = null,
    operation: () -> Result,
): Result {
    val connection = coroutineContext[Job]
    fun requireCurrent() {
        connection?.ensureActive()
        if (!isCurrent()) throw CancellationException("camera credential connection changed")
    }
    requireCurrent()
    // Mutex waiting is cooperative: Main yields while the preceding secure transaction finishes.
    transaction?.lock()
    try {
        if (transaction != null) requireCurrent()
        val result = withContext(dispatcher) {
            requireCurrent()
            coroutineContext.ensureActive()
            operation()
        }
        requireCurrent()
        coroutineContext.ensureActive()
        return result
    } finally {
        transaction?.unlock()
    }
}
