package com.opencapture.opencine.platform

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraWifiCredentialStoreTest {
    private class Memory : CredentialPreferences {
        val values = mutableMapOf<String, String>()
        var writes = 0
        override fun get(key: String, default: String?): String? = values[key] ?: default
        override fun write(values: Map<String, String>, removing: Set<String>) {
            writes += 1
            for (key in removing) this.values.remove(key)
            this.values.putAll(values)
        }
    }
    private val configuration = CameraWifiStorageConfiguration(
        preferencesName = "fixture.preferences", keyAlias = "fixture.alias",
        ssidKeySuffix = ".ssid", passwordKeySuffix = ".password", ssidIndexPrefix = "ssid:",
    )
    private fun store(memory: Memory, writable: Boolean = true) = CameraWifiCredentialStore(
        configuration, memory,
        seal = { if (writable) "sealed:$it" else null },
        open = { it.takeIf { it.startsWith("sealed:") }?.removePrefix("sealed:") },
    )

    @Test
    fun existingPlaintextMigratesOnceWithoutLosingTheCameraOrSsidIndex() {
        val memory = Memory()
        memory.values.putAll(mapOf("camera.ssid" to " FixtureCamera ", "camera.password" to "synthetic"))
        val store = store(memory)
        assertEquals(" FixtureCamera " to "synthetic", store.load("camera"))
        assertEquals(setOf("camera.ssid", "camera.password", "ssid:FixtureCamera"), memory.values.keys)
        assertEquals("sealed:synthetic", memory.values["camera.password"])
        assertEquals("synthetic", store.passphrase("FixtureCamera"))
        repeat(3) { assertEquals(" FixtureCamera " to "synthetic", store.load("camera")) }
        assertEquals(1, memory.writes)
        store.remove("camera")
        assertTrue(memory.values.isEmpty())
        store.remove("camera")
        assertNull(store.load("camera"))
    }

    @Test
    fun failedSealAndCorruptEnvelopePreserveExistingData() {
        val memory = Memory()
        memory.values.putAll(mapOf("camera.ssid" to "FixtureCamera", "camera.password" to "synthetic"))
        val unavailable = store(memory, writable = false)
        assertEquals("FixtureCamera" to "synthetic", unavailable.load("camera"))
        unavailable.save("other", "Other", "synthetic")
        assertEquals(0, memory.writes)
        memory.values["camera.password"] = "corrupt:envelope"
        assertNull(store(memory).load("camera"))
        assertEquals("corrupt:envelope", memory.values["camera.password"])
        assertEquals(0, memory.writes)
    }

    @Test
    fun emptyCameraCredentialsAndConfiguredKeysKeepExistingMeaning() {
        val memory = Memory()
        val store = store(memory)
        store.save("camera", "FixtureCamera", "")
        assertNull(store.load("camera"))
        assertEquals("", store.passphrase("FixtureCamera"))
        val custom = CameraWifiCredentialStore(
            configuration.copy(ssidKeySuffix = ".network", passwordKeySuffix = ".secret", ssidIndexPrefix = "network:"),
            memory, { "sealed:$it" }, { it.removePrefix("sealed:") },
        )
        custom.save("other", "Other", "synthetic")
        assertEquals("Other" to "synthetic", custom.load("other"))
        assertTrue(memory.values.keys.containsAll(listOf("other.network", "other.secret", "network:Other")))
        custom.remove("other")
        assertNull(custom.load("other"))
        assertEquals("", store.passphrase("FixtureCamera"))
    }
}
