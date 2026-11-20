package com.opencapture.opencine.streaming

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/** One serial thread that confines a publisher, with its timers. Tests substitute a manual one. */
interface StreamScheduler {
    fun interface Cancellable {
        fun cancel()
    }

    /** Runs [task] on the publisher's thread, after the tasks already queued. */
    fun execute(task: () -> Unit)

    fun schedule(delayNs: Long, task: () -> Unit): Cancellable

    fun repeat(periodNs: Long, task: () -> Unit): Cancellable

    /** Ends the thread after the queued tasks. */
    fun shutdown()

    companion object {
        fun serial(name: String = "opc.stream.publisher"): StreamScheduler = ExecutorStreamScheduler(
            Executors.newSingleThreadScheduledExecutor { Thread(it, name).apply { isDaemon = true } },
        )
    }
}

private class ExecutorStreamScheduler(private val executor: ScheduledExecutorService) : StreamScheduler {
    override fun execute(task: () -> Unit) {
        runCatching { executor.execute(task) }
    }

    override fun schedule(delayNs: Long, task: () -> Unit): StreamScheduler.Cancellable {
        val future = runCatching { executor.schedule(task, delayNs.coerceAtLeast(0), TimeUnit.NANOSECONDS) }.getOrNull()
        return StreamScheduler.Cancellable { future?.cancel(false) }
    }

    /**
     * Runs on a steady grid of [periodNs] from now. A late run does not bunch up the next ones: when
     * more than two periods behind (a cached process, a long pause) the grid restarts from now.
     */
    override fun repeat(periodNs: Long, task: () -> Unit): StreamScheduler.Cancellable {
        val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
        var dueNs = System.nanoTime()
        fun next() {
            if (cancelled.get()) return
            val now = System.nanoTime()
            dueNs = if (now - dueNs > 2 * periodNs) now + periodNs else dueNs + periodNs
            runCatching {
                executor.schedule({
                    if (!cancelled.get()) {
                        task()
                        next()
                    }
                }, (dueNs - now).coerceAtLeast(0), TimeUnit.NANOSECONDS)
            }
        }
        runCatching { executor.execute { if (!cancelled.get()) { task(); next() } } }
        return StreamScheduler.Cancellable { cancelled.set(true) }
    }

    override fun shutdown() {
        executor.shutdown()
    }
}
