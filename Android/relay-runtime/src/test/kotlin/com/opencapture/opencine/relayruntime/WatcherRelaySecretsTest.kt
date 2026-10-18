package com.opencapture.opencine.relayruntime

import android.content.SharedPreferences
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.LegacyMove
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.Lookup
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The relay secrets never get lost: no delete before a write, a write counts only once it reads
 * back, an unreadable store is not "no passcode", and a plain-text copy goes only once stored.
 * The twin of Swift's WatcherRelayKeychainTests; the real Keystore runs in the instrumented test.
 */
class WatcherRelaySecretsTest {
    @Test
    fun unreadableStoreIsNotAnEmptyPasscode() {
        val items = FakeItems()
        items.values["host-passcode"] = "1234"
        items.readFailure = "locked"
        val secrets = WatcherRelaySecrets(items)

        assertEquals(Lookup.Unavailable("locked"), secrets.hostPasscodeLookup())
        assertNull(secrets.hostPasscodeLookup().usableValue)
        items.readFailure = null
        assertEquals(Lookup.Stored("1234"), secrets.hostPasscodeLookup())
        assertEquals("", Lookup.Absent.usableValue)
    }

    @Test
    fun replacingAPasscodeUpdatesInPlaceAndNeverDeletesFirst() {
        val items = FakeItems()
        val secrets = WatcherRelaySecrets(items)
        assertTrue(secrets.storeHostPasscode("1111"))
        items.writeFails = true

        assertFalse(secrets.storeHostPasscode("2222"))
        assertEquals(Lookup.Stored("1111"), secrets.hostPasscodeLookup())
        assertFalse("delete" in items.log)
        items.writeFails = false
        assertTrue(secrets.storeHostPasscode("set pass"))
        assertEquals("set pass", secrets.hostPasscodeLookup().usableValue)
    }

    @Test
    fun aWriteThatDoesNotReadBackIsNotStored() {
        val items = FakeItems()
        items.corruptsWrites = true
        assertFalse(WatcherRelaySecrets(items).storeRememberedPasscode("4321", "Set A"))
    }

    @Test
    fun emptyClearsOnlyThatSecret() {
        val items = FakeItems()
        val secrets = WatcherRelaySecrets(items)
        secrets.storeHostPasscode("1111")
        secrets.storeRememberedPasscode("2222", "Set A")
        secrets.storeRememberedPasscode("3333", "Set B")

        assertTrue(secrets.storeRememberedPasscode("", "Set A"))
        assertEquals(Lookup.Absent, secrets.rememberedPasscodeLookup("Set A"))
        assertEquals(Lookup.Stored("3333"), secrets.rememberedPasscodeLookup("Set B"))
        assertEquals(Lookup.Stored("1111"), secrets.hostPasscodeLookup())
        items.deleteFails = true
        assertFalse(secrets.storeHostPasscode(""))
        assertEquals(Lookup.Stored("1111"), secrets.hostPasscodeLookup())
    }

    @Test
    fun legacyPasscodeMovesOnlyWhenStoredAndReadBack() {
        val items = FakeItems()
        val secrets = WatcherRelaySecrets(items)
        assertEquals(LegacyMove.NOTHING_TO_MOVE, secrets.adoptLegacyHostPasscode(""))

        items.readFailure = "locked"
        assertEquals(LegacyMove.FAILED, secrets.adoptLegacyHostPasscode("1234"))
        items.readFailure = null

        items.writeFails = true
        assertEquals(LegacyMove.FAILED, secrets.adoptLegacyHostPasscode("1234"))
        assertEquals(Lookup.Absent, secrets.hostPasscodeLookup())
        items.writeFails = false

        items.corruptsWrites = true
        assertEquals(LegacyMove.FAILED, secrets.adoptLegacyRememberedPasscode("9876", "Set A"))
        assertEquals(Lookup.Absent, secrets.rememberedPasscodeLookup("Set A"))
        items.corruptsWrites = false

        assertEquals(LegacyMove.MOVED, secrets.adoptLegacyHostPasscode("1234"))
        assertEquals(Lookup.Stored("1234"), secrets.hostPasscodeLookup())
        // A stored value wins over a different plain-text copy.
        assertEquals(LegacyMove.KEPT_STORED, secrets.adoptLegacyHostPasscode("0000"))
        assertEquals(Lookup.Stored("1234"), secrets.hostPasscodeLookup())
        assertTrue(LegacyMove.KEPT_STORED.releasesLegacyCopy)
        assertFalse(LegacyMove.FAILED.releasesLegacyCopy)
    }

    @Test
    fun plainTextHostPasscodeIsRemovedOnlyAfterTheSecureWriteIsConfirmed() {
        val items = FakeItems()
        val secrets = WatcherRelaySecrets(items)
        val legacy = FakePreferences(mutableMapOf("sharing.watcherPasscode" to "4821", "other" to true))

        items.readFailure = "locked"
        assertEquals(LegacyMove.FAILED, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
        assertEquals("4821", legacy.getString("sharing.watcherPasscode", null))
        items.readFailure = null

        items.corruptsWrites = true
        assertEquals(LegacyMove.FAILED, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
        assertEquals("4821", legacy.getString("sharing.watcherPasscode", null))
        items.corruptsWrites = false

        assertEquals(LegacyMove.MOVED, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
        assertFalse(legacy.contains("sharing.watcherPasscode"))
        assertTrue(legacy.contains("other"))
        assertEquals(Lookup.Stored("4821"), secrets.hostPasscodeLookup())
        // Once: nothing is left to move, and the stored code is untouched.
        assertEquals(LegacyMove.NOTHING_TO_MOVE, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
        assertEquals(Lookup.Stored("4821"), secrets.hostPasscodeLookup())
        // A cleared plain-text value is dropped without touching the store.
        legacy.edit().putString("sharing.watcherPasscode", "").commit()
        assertEquals(LegacyMove.NOTHING_TO_MOVE, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
        assertFalse(legacy.contains("sharing.watcherPasscode"))
        assertEquals(Lookup.Stored("4821"), secrets.hostPasscodeLookup())
    }

    @Test
    fun plainTextRememberedPasscodesMoveEachOnlyOnceConfirmed() {
        val items = FakeItems()
        val secrets = WatcherRelaySecrets(items)
        val legacy = FakePreferences(mutableMapOf("Set A" to "1111", "Set B" to "2222"))
        items.failWritesFor = "code.Set B"

        assertFalse(secrets.adoptLegacyRememberedPasscodes(legacy))
        assertFalse(legacy.contains("Set A"))
        assertEquals("2222", legacy.getString("Set B", null))
        assertEquals(Lookup.Stored("1111"), secrets.rememberedPasscodeLookup("Set A"))
        assertEquals(Lookup.Absent, secrets.rememberedPasscodeLookup("Set B"))

        items.failWritesFor = null
        assertTrue(secrets.adoptLegacyRememberedPasscodes(legacy))
        assertTrue(legacy.all.isEmpty())
        assertEquals(Lookup.Stored("2222"), secrets.rememberedPasscodeLookup("Set B"))
    }

    private class FakeItems : WatcherRelaySecretItems {
        val values = mutableMapOf<String, String>()
        val log = mutableListOf<String>()
        var readFailure: String? = null
        var writeFails = false
        var failWritesFor: String? = null
        var deleteFails = false
        var corruptsWrites = false

        override fun read(account: String): WatcherRelaySecretItems.Read {
            readFailure?.let { return WatcherRelaySecretItems.Read.Failed(it) }
            return values[account]?.let { WatcherRelaySecretItems.Read.Value(it) } ?: WatcherRelaySecretItems.Read.Missing
        }

        override fun write(account: String, value: String): Boolean {
            log += "write"
            if (writeFails || account == failWritesFor) return false
            values[account] = if (corruptsWrites) value.reversed() + "!" else value
            return true
        }

        override fun delete(account: String): Boolean {
            log += "delete"
            if (deleteFails) return false
            values.remove(account)
            return true
        }
    }

    /** Just enough SharedPreferences for the plain-text moves. */
    private class FakePreferences(private val values: MutableMap<String, Any?>) : SharedPreferences {
        override fun getAll(): Map<String, *> = values.toMap()
        override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues
        override fun getInt(key: String?, defValue: Int): Int = defValue
        override fun getLong(key: String?, defValue: Long): Long = defValue
        override fun getFloat(key: String?, defValue: Float): Float = defValue
        override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
        override fun contains(key: String?): Boolean = values.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

        private inner class Editor : SharedPreferences.Editor {
            private val puts = mutableMapOf<String, Any?>()
            private val removals = mutableSetOf<String>()
            override fun putString(key: String, value: String?): SharedPreferences.Editor = apply { puts[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor = this
            override fun putInt(key: String, value: Int): SharedPreferences.Editor = this
            override fun putLong(key: String, value: Long): SharedPreferences.Editor = this
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor = this
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = apply { puts[key] = value }
            override fun remove(key: String): SharedPreferences.Editor = apply { removals += key }
            override fun clear(): SharedPreferences.Editor = this
            override fun commit(): Boolean {
                removals.forEach(values::remove)
                values.putAll(puts)
                return true
            }
            override fun apply() { commit() }
        }
    }
}
