package com.opencapture.opencine.platform

import java.util.Base64
import javax.crypto.spec.SecretKeySpec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Twin of the Swift `SharedNetworkStoreTests` (iOS alone keeps a legacy `last-network`). */
class SharedNetworkStoreTest {
    private class MemoryStorage(var value: String? = null) : SharedNetworkStore.Storage {
        override fun read(): String? = value
        override fun write(value: String) {
            this.value = value
        }
    }

    private val key = SecretKeySpec(ByteArray(16) { it.toByte() }, "AES")
    private fun store(storage: MemoryStorage = MemoryStorage()) = SharedNetworkStore(
        storage, KeystoreSeal({ key }, Base64.getEncoder()::encodeToString, Base64.getDecoder()::decode),
    )

    @Test
    fun savingTheSameNetworkAndKindReplacesIt() {
        val store = store()
        store.save("Set", "one", false)
        store.save("Other", "x", false)
        store.save("Set", "two", false)
        assertEquals(listOf("Other", "Set"), store.savedNetworks().map { it.ssid })
        assertEquals("two", store.load("Set", false)?.password)
    }

    @Test
    fun aWiFiAndAHotspotWithOneNameAreKeptApart() {
        val store = store()
        store.save("Set", "wifi", false)
        store.save("Set", "spot", true)
        assertEquals(2, store.savedNetworks().size)
        assertEquals("wifi", store.load("Set", false)?.password)
        assertEquals("spot", store.load("Set", true)?.password)
    }

    @Test
    fun aMissingHotspotFlagReadsAsWiFi() {
        val store = store(MemoryStorage("""[{"ssid":"Set","password":""}]"""))
        assertEquals(SharedNetworkStore.Network("Set", "", false), store.load("Set", false))
        assertNull(store.load("Set", true))
    }

    @Test
    fun loadFindsByNameAndKind() {
        val store = store()
        store.save("A", "1", false)
        store.save("B", "2", true)
        assertEquals("2", store.load("B", true)?.password)
        assertNull(store.load("B", false))
        assertNull(store.load("Missing", false))
    }
}
