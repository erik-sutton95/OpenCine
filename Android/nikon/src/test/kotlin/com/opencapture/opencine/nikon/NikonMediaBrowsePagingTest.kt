package com.opencapture.opencine.nikon

import kotlin.coroutines.CoroutineContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield

class NikonMediaBrowsePagingTest {
    @Test
    fun `parses browse start with authoritative storage generation`() {
        val start =
            NikonMediaBrowseStarts.parse(
                startWire(
                    cursor = 41,
                    slots =
                        listOf(
                            StorageSlot(65_537, 1, 954_000_000_000, 242_000_000_000),
                            StorageSlot(131_073, 2, 512_000_000_000, 111_000_000_000),
                        ),
                ),
            )

        requireNotNull(start)
        assertEquals(41L, start.cursor)
        assertEquals(listOf(65_537L, 131_073L), start.storageSlots.map { it.storageId })
        assertEquals(listOf(1, 2), start.storageSlots.map { it.slotNumber })
        assertNull(NikonMediaBrowseStarts.parse("OZCMEDIASTART0\t41\nresult\tmediaBusy"))
        assertNull(NikonMediaBrowseStarts.parse("OZCMEDIASTART1\t0\nresult\tmediaBusy"))
        assertNull(NikonMediaBrowseStarts.parse("OZCMEDIASTART1\t41\nresult\taccepted"))
    }

    @Test
    fun `parses versioned page header and records`() {
        val page =
            NikonMediaBrowsePages.parse(
                "OZCMEDIA2\t1\t32\t0\n" +
                    "4097\t65537\t1284505600\t20260713T101010\t5760\t3240\t0\t0\t1\tproxy\t\t\tC0001.MOV",
            )

        requireNotNull(page)
        assertTrue(page.hasMore)
        assertEquals(32, page.inspectedObjectCount)
        assertEquals(listOf("C0001.MOV"), page.clips.map { it.filename })
    }

    @Test
    fun `rejects malformed page headers`() {
        assertNull(NikonMediaBrowsePages.parse(""))
        assertNull(NikonMediaBrowsePages.parse("OZCMEDIA1\t0\t0\t0"))
        assertNull(NikonMediaBrowsePages.parse("OZCMEDIA2\tmaybe\t0\t0"))
        assertNull(NikonMediaBrowsePages.parse("OZCMEDIA2\t0\t-1\t0"))
        assertNull(NikonMediaBrowsePages.parse("OZCMEDIA2\t0\t129\t0"))
        assertNull(NikonMediaBrowsePages.parse("OZCMEDIA2\t0\t0\t1\n-\t1\t-1\tdate\tA.R3D"))
    }

    @Test
    fun `collects every page and publishes both storage cards incrementally`() = runTest {
        val gateway =
            FakeGateway(
                pages =
                    listOf(
                        page(
                            hasMore = true,
                            inspected = 2,
                            records = listOf(record(5, 1, "CARD1-NEW.MOV"), record(9, 2, "CARD2-NEW.MOV")),
                        ),
                        page(
                            hasMore = true,
                            inspected = 2,
                            records = listOf(record(4, 1, "CARD1-OLD.MOV")),
                        ),
                        page(
                            hasMore = false,
                            inspected = 1,
                            records = listOf(record(8, 2, "CARD2-OLD.MOV")),
                        ),
                    ),
            )
        val updates = mutableListOf<NikonMediaBrowseSnapshot>()

        val clips =
            collectPages(
                pageSize = 2,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = updates::add,
            )

        assertEquals(listOf(2, 3, 4), updates.map { it.clips.size })
        assertEquals(listOf(2, 1, 1), updates.map { it.addedClips.size })
        assertEquals(setOf(1L, 2L), updates.first().clips.map { it.storageId }.toSet())
        assertEquals(setOf(1L, 2L), clips.map { it.storageId }.toSet())
        assertEquals(listOf(2, 2, 2), gateway.requestedPageSizes)
        assertEquals(listOf(41L), gateway.cancelledCursors)
    }

    @Test
    fun `empty bootstrap receives storage before the first media page`() = runTest {
        val slots =
            listOf(
                StorageSlot(65_537, 1, 954_000_000_000, 242_000_000_000),
                StorageSlot(131_073, 2, 512_000_000_000, 111_000_000_000),
            )
        val gateway =
            FakeGateway(
                pages = listOf(page(hasMore = false, inspected = 0, records = emptyList())),
                storageSlots = slots,
            )
        val callbacks = mutableListOf<String>()
        var receivedSlots = emptyList<Long>()

        collectPages(
            pageSize = 32,
            gateway = gateway,
            ioContext = Dispatchers.Unconfined,
            onStart = { authoritative ->
                callbacks += "start"
                receivedSlots = authoritative.map { it.storageId }
            },
            onPage = { callbacks += "page" },
        )

        assertEquals(listOf("start", "page"), callbacks)
        assertEquals(listOf(65_537L, 131_073L), receivedSlots)
    }

    @Test
    fun `later proxy removal wins over an earlier R3D addition`() = runTest {
        val master = "7\t1\t2\t20260715T120000\t6144\t3240\t0\t0\t0\tr3d\t\t\tA001.R3D"
        val proxy = record(8, 2, "A001.MP4")
        val gateway =
            FakeGateway(
                pages =
                    listOf(
                        page(hasMore = true, inspected = 1, records = listOf(master)),
                        page(
                            hasMore = false,
                            inspected = 1,
                            records = listOf(proxy),
                            removals =
                                listOf(
                                    NikonMediaObjectIdentity(
                                        storageID = 1,
                                        handle = 7,
                                        captureDate = "20260715T120000",
                                        filename = "A001.R3D",
                                    ),
                                ),
                        ),
                    ),
            )
        val updates = mutableListOf<NikonMediaBrowseSnapshot>()

        val clips =
            collectPages(
                pageSize = 2,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = { updates += it },
            )

        assertEquals(listOf("A001.R3D"), updates.first().clips.map { it.filename })
        assertEquals(listOf("A001.R3D"), updates.first().addedClips.map { it.filename })
        assertEquals(listOf("A001.MP4"), updates.last().addedClips.map { it.filename })
        assertEquals(listOf("A001.MP4"), clips.map { it.filename })
    }

    @Test
    fun `caller cancellation always invalidates the native cursor`() = runTest {
        val gateway =
            FakeGateway(
                pages = listOf(page(hasMore = true, inspected = 1, records = listOf(record(1, 1, "A.MOV")))),
            )

        assertFailsWith<CancellationException> {
            collectPages(
                pageSize = 1,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = { throw CancellationException("New listing replaced this one.") },
            )
        }
        assertEquals(listOf(41L), gateway.cancelledCursors)
    }

    @Test
    fun `invalid native page fails closed and releases the cursor`() = runTest {
        val gateway = FakeGateway(pages = listOf("unversioned"))

        assertFailsWith<NikonMediaBrowsePagingException> {
            collectPages(
                pageSize = 32,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = {},
            )
        }
        assertEquals(listOf(41L), gateway.cancelledCursors)
    }

    /** Drives the production pager to the end of the listing, as the service's catalog does. */
    private suspend fun collectPages(
        pageSize: Int,
        gateway: NikonMediaBrowseGateway,
        ioContext: CoroutineContext,
        onStart: suspend (List<CameraStorageSlotStatus>) -> Unit = {},
        onPage: suspend (NikonMediaBrowseSnapshot) -> Unit,
    ): List<NikonMediaClipRecord> {
        val pager = NikonMediaCatalogPager(gateway, pageSize, ioContext)
        var clips: List<NikonMediaClipRecord> = emptyList()
        try {
            onStart(pager.begin().storageSlots)
            while (true) {
                val page = pager.next() ?: return clips
                clips = page.clips
                onPage(page)
                if (!page.hasMore) return clips
                yield()
            }
        } finally {
            withContext(NonCancellable) { pager.close() }
        }
    }

    private class FakeGateway(
        pages: List<String>,
        private val cursor: Long = 41,
        private val storageSlots: List<StorageSlot> = emptyList(),
    ) : NikonMediaBrowseGateway {
        private val remainingPages = ArrayDeque(pages)
        val requestedPageSizes = mutableListOf<Int>()
        val cancelledCursors = mutableListOf<Long>()

        override fun begin(): String = startWire(cursor, storageSlots)

        override fun next(cursor: Long, maxObjects: Int): String? {
            assertEquals(this.cursor, cursor)
            requestedPageSizes += maxObjects
            return remainingPages.removeFirstOrNull()
        }

        override fun cancel(cursor: Long) {
            cancelledCursors += cursor
        }
    }

    private companion object {
        data class StorageSlot(
            val storageId: Long,
            val slotNumber: Int,
            val totalCapacityBytes: Long,
            val freeSpaceBytes: Long,
        )

        fun startWire(cursor: Long, slots: List<StorageSlot> = emptyList()): String =
            buildList {
                add("OZCMEDIASTART1\t$cursor")
                add("result\tmediaBusy")
                add("storageSlotCount\t${slots.size}")
                slots.forEachIndexed { index, slot ->
                    add("storageSlot.$index.storageId\t${slot.storageId}")
                    add("storageSlot.$index.slotNumber\t${slot.slotNumber}")
                    add("storageSlot.$index.totalCapacityBytes\t${slot.totalCapacityBytes}")
                    add("storageSlot.$index.freeSpaceBytes\t${slot.freeSpaceBytes}")
                }
            }.joinToString(separator = "\n")

        fun page(
            hasMore: Boolean,
            inspected: Int,
            records: List<String>,
            removals: List<NikonMediaObjectIdentity> = emptyList(),
        ): String =
            buildList {
                add("OZCMEDIA2\t${if (hasMore) 1 else 0}\t$inspected\t${removals.size}")
                removals.forEach {
                    add("-\t${it.storageID}\t${it.handle}\t${it.captureDate}\t${it.filename}")
                }
                addAll(records)
            }.joinToString(separator = "\n")

        fun record(handle: Long, storageID: Long, filename: String): String =
            "$handle\t$storageID\t1\t20260715T12000$handle\t1920\t1080\t0\t0\t1\tproxy\t\t\t$filename"
    }
}
