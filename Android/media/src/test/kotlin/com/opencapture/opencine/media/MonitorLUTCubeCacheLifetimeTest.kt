package com.opencapture.opencine.media

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Draft only: tests the production owner, with actual maximum-size payloads. No sleeps or GC oracle. */
class MonitorLUTCubeCacheLifetimeTest {
    private val payloadBytes = 1_048_576
    private fun cube(value: Int) = MonitorLUTCube(64, ByteArray(payloadBytes) { value.toByte() })

    @Test fun defaultCapacityRetainsEightMaximumCubesAndEvictsTheLeastRecent() {
        val cache = MonitorLUTCubeCache()
        val calls = mutableMapOf<String, Int>()
        fun read(key: String) = cache.value(key) {
            calls[key] = (calls[key] ?: 0) + 1
            cube(key.removePrefix("key").toInt())
        }
        repeat(8) { read("key$it") }
        assertEquals(MonitorLUTCubeCache.Snapshot(8, 8_388_608L, false), cache.snapshot())
        val first = read("key0")
        read("key8")
        assertEquals(MonitorLUTCubeCache.Snapshot(8, 8_388_608L, false), cache.snapshot())
        assertSame(first, read("key0"))
        assertEquals(1, calls["key0"])
        read("key1")
        assertEquals(2, calls["key1"])
        assertEquals(10, calls.values.sum())
        cache.close()
        assertEquals(MonitorLUTCubeCache.Snapshot(0, 0L, true), cache.snapshot())
    }

    @Test fun nilIsNotStoredAndZeroCapacityDoesNotRetainAResult() {
        val cache = MonitorLUTCubeCache()
        var calls = 0
        repeat(2) { assertNull(cache.value("missing") { calls++; null }) }
        assertEquals(2, calls)
        assertEquals(0L, cache.snapshot().payloadBytes)
        val uncached = MonitorLUTCubeCache(0)
        val payload = cube(21)
        assertSame(payload, uncached.value("same") { payload })
        assertEquals(0, uncached.snapshot().entries)
        assertEquals(0L, uncached.snapshot().payloadBytes)
        cache.close(); uncached.close()
    }

    @Test fun ownersWithIdenticalKeysNeverShareStorageOrRetirement() {
        val live = MonitorLUTCubeCache()
        val playback = MonitorLUTCubeCache()
        val inspector = MonitorLUTCubeCache()
        val a = live.value("paint:1:12:800") { cube(10) }
        val b = playback.value("paint:1:12:800") { cube(20) }
        val c = inspector.value("paint:1:12:800") { cube(30) }
        assertNotSame(a, b); assertNotSame(a, c); assertNotSame(b, c)
        live.close()
        assertEquals(MonitorLUTCubeCache.Snapshot(0, 0L, true), live.snapshot())
        assertSame(b, playback.value("paint:1:12:800") { error("must stay cached") })
        assertSame(c, inspector.value("paint:1:12:800") { error("must stay cached") })
        assertEquals(1_048_576L, playback.snapshot().payloadBytes)
        assertEquals(1_048_576L, inspector.snapshot().payloadBytes)
        // Closing the cache cannot mutate a plan's previously borrowed pixels.
        assertEquals(10.toByte(), assertNotNull(a).rgba[52])
        playback.close(); inspector.close()
    }

    @Test fun retirementDoesNotWaitForEnteredBakeAndItsLateResultIsDiscarded() {
        val retired = MonitorLUTCubeCache()
        val successor = MonitorLUTCubeCache()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val old = pool.submit<MonitorLUTCube?> {
                retired.value("same") {
                    entered.countDown()
                    check(release.await(10, TimeUnit.SECONDS))
                    cube(40)
                }
            }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            // Bound the *test* if close incorrectly holds the bake lock; the clock is no stimulus.
            pool.submit { retired.close() }.get(2, TimeUnit.SECONDS)
            assertEquals(MonitorLUTCubeCache.Snapshot(0, 0L, true), retired.snapshot())
            val lateQuery = pool.submit<MonitorLUTCube?> {
                retired.value("same") { error("a retired owner must never bake") }
            }
            assertNull(lateQuery.get(2, TimeUnit.SECONDS))
            val current = successor.value("same") { cube(50) }
            release.countDown()
            assertNull(old.get(10, TimeUnit.SECONDS))
            assertEquals(MonitorLUTCubeCache.Snapshot(0, 0L, true), retired.snapshot())
            assertSame(current, successor.value("same") { error("late old bake erased successor") })
            retired.close()
        } finally {
            release.countDown(); retired.close(); successor.close(); pool.shutdownNow()
        }
    }

    @Test fun hitAndSameKeyConcurrentMissReuseTheOwnersPayload() {
        val cache = MonitorLUTCubeCache()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        var bakes = 0
        try {
            val a = pool.submit<MonitorLUTCube?> {
                cache.value("key") { bakes++; entered.countDown(); check(release.await(10, TimeUnit.SECONDS)); cube(60) }
            }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            val b = pool.submit<MonitorLUTCube?> { cache.value("key") { bakes++; cube(70) } }
            release.countDown()
            assertSame(a.get(10, TimeUnit.SECONDS), b.get(10, TimeUnit.SECONDS))
            assertEquals(1, bakes)
            assertEquals(MonitorLUTCubeCache.Snapshot(1, 1_048_576L, false), cache.snapshot())
        } finally { release.countDown(); cache.close(); pool.shutdownNow() }
    }
}
