package com.opencapture.opencine.relayruntime

import android.content.Context
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.LegacyMove
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.Lookup
import java.security.KeyStore
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/** The relay secrets on the real Android Keystore, in a random service removed afterwards. */
@RunWith(AndroidJUnit4::class)
class WatcherRelaySecretsKeystoreTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val service = "test.watcher-relay.${UUID.randomUUID()}"
    private val legacyName = "$service.legacy"

    @After
    fun removeService() {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(service)
        context.deleteSharedPreferences(service)
        context.deleteSharedPreferences(legacyName)
    }

    @Test
    fun passcodesRoundTripEncryptedAndReplaceInPlace() {
        val secrets = WatcherRelaySecrets(context, service)
        assertEquals(Lookup.Absent, secrets.hostPasscodeLookup())
        assertTrue(secrets.storeHostPasscode("4821"))
        assertTrue(secrets.storeRememberedPasscode("set pass", "Set A"))
        assertEquals(Lookup.Stored("4821"), secrets.hostPasscodeLookup())
        // A second owner over the same service reads what the first stored.
        val reopened = WatcherRelaySecrets(context, service)
        assertEquals(Lookup.Stored("set pass"), reopened.rememberedPasscodeLookup("Set A"))
        assertTrue(reopened.storeHostPasscode("pässwörd 🎬"))
        assertEquals(Lookup.Stored("pässwörd 🎬"), secrets.hostPasscodeLookup())
        // Nothing readable on disk.
        val file = context.getSharedPreferences(service, Context.MODE_PRIVATE).all
        assertFalse(file.values.any { it.toString().contains("pässwörd") || it.toString().contains("set pass") })
        assertTrue(secrets.storeRememberedPasscode("", "Set A"))
        assertEquals(Lookup.Absent, secrets.rememberedPasscodeLookup("Set A"))
        assertEquals(Lookup.Stored("pässwörd 🎬"), secrets.hostPasscodeLookup())
    }

    @Test
    fun plainTextPasscodesMoveOnceAndLeaveOnlyAfterConfirmation() {
        val legacy = context.getSharedPreferences(legacyName, Context.MODE_PRIVATE)
        legacy.edit().putString("sharing.watcherPasscode", "4821").putString("Set A", "1111")
            .putString("Set B", "abcd").commit()
        val secrets = WatcherRelaySecrets(context, service)

        assertEquals(LegacyMove.MOVED, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
        assertFalse(legacy.contains("sharing.watcherPasscode"))
        assertTrue(secrets.adoptLegacyRememberedPasscodes(legacy))
        assertTrue(legacy.all.isEmpty())
        assertEquals(Lookup.Stored("4821"), secrets.hostPasscodeLookup())
        assertEquals(Lookup.Stored("1111"), secrets.rememberedPasscodeLookup("Set A"))
        assertEquals(Lookup.Stored("abcd"), secrets.rememberedPasscodeLookup("Set B"))
        assertEquals(LegacyMove.NOTHING_TO_MOVE, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
    }

    @Test
    fun anUnopenableValueIsUnavailableAndKeepsThePlainTextCopy() {
        val secrets = WatcherRelaySecrets(context, service)
        assertTrue(secrets.storeHostPasscode("1111"))
        // Damage the envelope: the key exists, the value cannot be opened.
        val file = context.getSharedPreferences(service, Context.MODE_PRIVATE)
        val sealed = file.getString(WatcherRelaySecrets.HOST_ACCOUNT, null)!!
        val (iv, payload) = sealed.split(':', limit = 2)
        val damaged = Base64.decode(payload, Base64.NO_WRAP).also { it[0] = (it[0].toInt() xor 1).toByte() }
        file.edit().putString(WatcherRelaySecrets.HOST_ACCOUNT, iv + ":" + Base64.encodeToString(damaged, Base64.NO_WRAP))
            .commit()

        val lookup = secrets.hostPasscodeLookup()
        assertTrue(lookup is Lookup.Unavailable, "$lookup")
        assertNull(lookup.usableValue)
        val legacy = context.getSharedPreferences(legacyName, Context.MODE_PRIVATE)
        legacy.edit().putString("sharing.watcherPasscode", "4821").commit()
        assertEquals(LegacyMove.FAILED, secrets.adoptLegacyHostPasscode(legacy, "sharing.watcherPasscode"))
        assertEquals("4821", legacy.getString("sharing.watcherPasscode", null))
        assertNotEquals(Lookup.Absent, secrets.hostPasscodeLookup())
        // A new code replaces the damaged one in place.
        assertTrue(secrets.storeHostPasscode("2222"))
        assertEquals(Lookup.Stored("2222"), secrets.hostPasscodeLookup())
    }

    @Test
    fun ciphertextWhoseKeyIsGoneReadsAsNothingStored() {
        val secrets = WatcherRelaySecrets(context, service)
        assertTrue(secrets.storeHostPasscode("4821"))
        // A restored file on another device, or a lost key: it can never be opened.
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(service)
        assertEquals(Lookup.Absent, secrets.hostPasscodeLookup())
        assertTrue(secrets.storeHostPasscode("1234"))
        assertEquals(Lookup.Stored("1234"), secrets.hostPasscodeLookup())
    }
}
