package com.opencapture.opencine.streaming

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StreamKeyStoreTest {
    private class MemoryStorage : StreamKeyStorage {
        val values = mutableMapOf<String, String>()
        override fun get(name: String): String? = values[name]
        override fun put(name: String, value: String): Boolean { values[name] = value; return true }
        override fun remove(name: String): Boolean { values.remove(name); return true }
    }

    /** Reversible stand-in for the Keystore envelope; `keyGone` mimics a restored backup. */
    private class FakeSeal : StreamSecretSeal {
        var keyGone = false
        var answers = true
        override fun seal(secret: String): String? = if (answers) "sealed:" + secret.reversed() else null
        override fun open(stored: String): StreamSecretSeal.Opened = when {
            keyGone -> StreamSecretSeal.Opened.KeyGone
            !answers -> StreamSecretSeal.Opened.Failed
            else -> StreamSecretSeal.Opened.Secret(stored.removePrefix("sealed:").reversed())
        }
    }

    private val storage = MemoryStorage()
    private val seal = FakeSeal()
    private val store = StreamKeyStore(storage, seal)

    @Test
    fun savedKeyReadsBack() {
        assertEquals(StreamKeyStore.Lookup.Absent, store.key("twitch"))
        assertTrue(store.save(key = "live_abc", server = null, presetId = "twitch"))
        assertEquals(StreamKeyStore.Lookup.Stored("live_abc"), store.key("twitch"))
        assertEquals(StreamKeyStore.Lookup.Absent, store.server("twitch"))
        assertTrue(store.save(key = "k2", server = "rtmps://h/app", presetId = "custom"))
        assertEquals(StreamKeyStore.Lookup.Stored("rtmps://h/app"), store.server("custom"))
        assertFalse(storage.values.values.any { it.contains("live_abc") })
    }

    @Test
    fun removeForgetsKeyAndServer() {
        store.save(key = "k", server = "rtmps://h/app", presetId = "custom")
        assertTrue(store.remove("custom"))
        assertEquals(StreamKeyStore.Lookup.Absent, store.key("custom"))
        assertEquals(StreamKeyStore.Lookup.Absent, store.server("custom"))
    }

    @Test
    fun lostDeviceKeyIsUnavailableNotAbsent() {
        store.save(key = "k", server = null, presetId = "youtube")
        seal.keyGone = true
        assertEquals(StreamKeyStore.Lookup.Unavailable, store.key("youtube"))
        seal.keyGone = false
        seal.answers = false
        assertEquals(StreamKeyStore.Lookup.Unavailable, store.key("youtube"))
        assertFalse(store.save(key = "k", server = null, presetId = "youtube"))
    }

    @Test
    fun keyIsInNoDescription() {
        store.save(key = "SECRETKEY", server = null, presetId = "twitch")
        val found = store.key("twitch")
        assertFalse(found.toString().contains("SECRETKEY"))
        assertFalse(store.toString().contains("SECRETKEY"))
    }
}
