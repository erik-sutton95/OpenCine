package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class NikonMediaServiceTest {
    @Test fun firstPageResetRetiresOldRawCatalogWhileSubsequentPagesAccumulate() = runTest {
        val port = Port()
        port.pages += page("FIRST.MOV").replace("OZCMEDIA2\t0", "OZCMEDIA2\t1")
        port.pages += page("SECOND.MOV").replace("\n7\t", "\n8\t")
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        val browse = source.openBrowse(); val cursor = browse.catalog()
        val first = assertNotNull(cursor.next()); val second = assertNotNull(cursor.next())
        assertTrue(first.reset); assertFalse(second.reset)
        assertEquals(1, first.upserts.size); assertEquals(1, second.upserts.size)
        val stale = first.upserts.single().copy(id = MediaAssetID("SIMULATED-stale"), filename = "STALE.MOV")
        val afterFirst = MediaCatalog(assets = listOf(stale)).applying(first)
        assertEquals(first.upserts.map { it.id }, afterFirst.assets.map { it.id })
        val afterSecond = afterFirst.applying(second)
        assertEquals((first.upserts + second.upserts).map { it.id }.toSet(), afterSecond.assets.map { it.id }.toSet())
        cursor.close()
        port.pages += "OZCMEDIA2\t0\t0\t0"
        val empty = assertNotNull(browse.catalog().next())
        assertTrue(empty.reset); assertTrue(empty.complete); assertTrue(empty.upserts.isEmpty())
        assertTrue(afterSecond.applying(empty).assets.isEmpty())
        browse.close()
    }

    @Test fun realPagerPublishesBothCardsAndCapturesExactRemovalIdentity() = runTest {
        val port = Port()
        port.pages += "OZCMEDIA2\t1\t1\t0\n7\t1\t200\t20261004T120000\t6048\t3402\t0\t0\t0\tr3d\t\t\tA.R3D"
        port.pages += "OZCMEDIA2\t0\t1\t1\n-\t1\t7\t20261004T120000\tA.R3D\n8\t2\t100\t20261004T120000\t1920\t1080\t6048\t3402\t1\tproxy\t\t\tA.MOV"
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler), 2)
        val browse = source.openBrowse(); val cursor = browse.catalog()
        val first = assertNotNull(cursor.next()); val oldID = first.upserts.single().id
        assertFalse(first.complete)
        val second = assertNotNull(cursor.next())
        assertEquals(listOf(oldID), second.removed)
        assertEquals(NikonMediaObjectIdentity(1, 7, "20261004T120000", "A.R3D"),
            source.mediaCatalogRecord(oldID, browse.binding)?.identity)
        assertNotEquals(oldID, second.upserts.single().id)
        assertEquals("A.MOV", source.mediaCatalogRecord(second.upserts.single().id, browse.binding)?.clip?.filename)
        assertTrue(second.complete)
        assertEquals(listOf(2, 2), port.sizes)
        assertNull(cursor.next())
        cursor.close(); browse.close()
        assertEquals(listOf(41L), port.cancelled)
        assertEquals(1, port.exits)
    }

    @Test fun epochReplacementDuringNativeStepCannotPublishAndSuccessorRemainsUsable() = runTest {
        val port = Port(); port.pages += page("OLD.MOV"); port.pages += page("NEW.MOV")
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        val old = source.openBrowse(); val cursor = old.catalog()
        port.onNext = { port.epoch = port.epoch.next() }
        val failure = assertFailsWith<MediaServiceException> { cursor.next() }
        assertEquals(MediaServiceFailure.RETIRED, failure.failure)
        assertFalse(source.isCurrent(old.binding))
        port.onNext = null
        val next = source.openBrowse(); val nextCursor = next.catalog()
        old.close()
        val successor = assertNotNull(nextCursor.next())
        assertEquals(listOf("NEW.MOV"), successor.upserts.map { it.filename })
        assertTrue(source.isCurrent(next.binding))
        assertEquals(0, port.exits)
        assertEquals(listOf(41L), port.cancelled)
        next.close()
        assertEquals(1, port.exits)
        assertEquals(listOf(41L, 42L), port.cancelled)
    }

    @Test fun admittedOldExitCompletesBeforeQueuedSuccessorBeginAndCannotClearIt() = runTest {
        val port = Port(); port.pages += page("NEXT.MOV")
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        val old = source.openBrowse()
        lateinit var successor: Deferred<CameraMediaBrowse>
        port.onExit = {
            successor = backgroundScope.async(start = CoroutineStart.UNDISPATCHED) { source.openBrowse() }
        }
        old.close()
        val next = successor.await()
        assertEquals(listOf("begin:41", "exit:start", "exit:end", "begin:42"), port.order)
        assertEquals(1, port.exits)
        assertTrue(source.isCurrent(next.binding))
        old.close()
        assertEquals(1, port.exits)
        assertEquals("NEXT.MOV", assertNotNull(next.catalog().next()).upserts.single().filename)
        port.onExit = null
        next.close()
        assertEquals(2, port.exits)
    }

    @Test fun cancelledBlockingBeginDrainsAndCancelsExactlyReturnedNativeCursor() = runTest {
        val port = Port()
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        lateinit var opening: Deferred<CameraMediaBrowse>
        port.onBegin = { opening.cancel() }
        opening = async { source.openBrowse() }
        runCurrent()
        assertFailsWith<CancellationException> { opening.await() }
        assertEquals(listOf(41L), port.cancelled)
        assertEquals(1, port.exits)
        assertEquals(listOf("begin:41", "exit:start", "exit:end"), port.order)
    }

    @Test fun exactNativeObjectReplacementRefusesCloseCommandsOnReplacement() = runTest {
        val port = Port(); val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        val old = source.openBrowse()
        port.native = Any()
        old.close()
        assertEquals(0, port.exits)
        assertEquals(listOf(41L), port.cancelled)
        val next = source.openBrowse()
        old.close()
        assertTrue(source.isCurrent(next.binding))
        assertEquals(0, port.exits)
        next.close()
    }

    @Test fun nativeUnknownVolumeAndCivilDateNeverBecomeFabricatedFacts() = runTest {
        val port = Port(); port.pages += "OZCMEDIA2\t0\t1\t0\n7\t1\t0\t20261004T120000\t0\t0\t0\t0\t1\tproxy\t\t\tGöteborg.MOV"
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        val browse = source.openBrowse(); val result = assertNotNull(browse.catalog().next())
        val asset = result.upserts.single()
        assertNull(result.volumes)
        assertNull(asset.capturedAt)
        assertNull(asset.pixelSize)
        assertNull(asset.representations.single().byteCount)
        assertNull(asset.deletable)
        assertNull(browse.transfers)
        assertNull(browse.deletion)
        browse.close()
    }

    @Test fun withoutAConnectionOwnerTheBrowseIsUnavailableAndNeverReachesTheCamera() = runTest {
        val port = Port(); port.connected = false
        val source = NikonMediaService(port.session, port, backgroundScope, StandardTestDispatcher(testScheduler))
        assertEquals(MediaServiceFailure.UNAVAILABLE, assertFailsWith<MediaServiceException> { source.openBrowse() }.failure)
        assertEquals(emptyList<String>(), port.order)
    }

    private class Port : NikonMediaSourcePort {
        val session = CameraSessionID()
        var native: Any = Any()
        var epoch = ControlEpoch(1)
        override val cameraNamespace = "SIMULATED-camera"
        val pages = ArrayDeque<String>()
        val cancelled = mutableListOf<Long>()
        val sizes = mutableListOf<Int>()
        val order = mutableListOf<String>()
        var exits = 0
        private var handle = 40L
        var onBegin: (() -> Unit)? = null
        var onNext: (() -> Unit)? = null
        var onExit: (() -> Unit)? = null
        var connected = true
        override fun sourceIdentity() = if (connected) NikonMediaSourceIdentity(native, 1, session, epoch) else null
        override fun gateway(source: NikonMediaSourceIdentity): NikonMediaBrowseGateway = object : NikonMediaBrowseGateway {
            override fun begin(): String {
                handle += 1; val captured = handle
                order += "begin:$captured"; onBegin?.invoke()
                return "OZCMEDIASTART1\t$captured\nresult\tmediaBusy\nstorageSlotCount\t0"
            }
            override fun next(cursor: Long, maxObjects: Int): String? {
                sizes += maxObjects; val result = pages.removeFirstOrNull(); onNext?.invoke(); return result
            }
            override fun cancel(cursor: Long) { cancelled += cursor }
            override fun exit() { exits += 1; order += "exit:start"; onExit?.invoke(); order += "exit:end" }
        }
    }
    private companion object {
        fun page(name: String) = "OZCMEDIA2\t0\t1\t0\n7\t1\t100\t20261004T120000\t1920\t1080\t0\t0\t1\tproxy\t\t\t$name"
    }
}
