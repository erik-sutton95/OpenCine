package com.opencapture.opencine.runtime

import android.os.Process
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext

/** One mounted frame consumer owns its decode thread; closing never stops another consumer. */
class MonitorFrameDecodeWorker(
    threadName: String, threadPriority: Int = Process.THREAD_PRIORITY_DISPLAY,
) : AutoCloseable {
    private val lifetime = NativeRenderLifetime()
    private val ticket = lifetime.start()
    private val dispatcher = Executors.newSingleThreadExecutor { runnable ->
        Thread({ Process.setThreadPriority(threadPriority); runnable.run() }, threadName)
    }.asCoroutineDispatcher()
    suspend fun run(block: suspend (isCurrent: () -> Boolean) -> Unit) {
        if (!lifetime.isCurrent(ticket)) return
        withContext(dispatcher) { block { lifetime.isCurrent(ticket) } }
    }
    override fun close() {
        lifetime.stop()
        dispatcher.close()
    }
}
