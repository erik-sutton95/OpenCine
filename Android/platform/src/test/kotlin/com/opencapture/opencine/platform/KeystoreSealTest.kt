package com.opencapture.opencine.platform

import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class KeystoreSealTest {
    private val key = SecretKeySpec(ByteArray(16) { it.toByte() }, "AES")
    private val codec = Base64.getEncoder()
    private val reader = Base64.getDecoder()
    private fun seal() = KeystoreSeal({ key }, codec::encodeToString, reader::decode)

    @Test
    fun existingEnvelopeReadsAndFreshWritesKeepTheSameEnvelope() {
        val secret = "synthetic fixture"
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val iv = ByteArray(12) { (it + 1).toByte() }
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        // Same existing iv:ciphertext format, 128-bit tag and no AAD.
        val legacy = codec.encodeToString(iv) + ":" + codec.encodeToString(cipher.doFinal(secret.toByteArray()))
        assertEquals(secret, seal().open(legacy))
        val current = assertNotNull(seal().seal(secret))
        assertEquals(2, current.split(':').size)
        assertEquals(secret, seal().open(current))
        assertEquals("", seal().open(assertNotNull(seal().seal(""))))
    }

    @Test
    fun corruptedEnvelopeAndUnavailableKeyStayUnknown() {
        assertNull(seal().open("not an envelope"))
        assertNull(seal().open("invalid:invalid"))
        val current = assertNotNull(seal().seal("synthetic fixture"))
        val parts = current.split(':')
        val payload = reader.decode(parts[1]).also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertNull(seal().open(parts[0] + ":" + codec.encodeToString(payload)))
        val unavailable = KeystoreSeal({ error("unavailable") }, codec::encodeToString, reader::decode)
        assertNull(unavailable.seal("synthetic fixture"))
        assertNull(unavailable.open(current))
    }

    @Test
    fun openedTellsAGoneKeyFromOneThatDidNotAnswer() {
        val current = assertNotNull(seal().seal("synthetic fixture"))
        assertEquals(KeystoreSeal.Opened.Secret("synthetic fixture"), seal().opened(current))
        val gone = KeystoreSeal({ key }, codec::encodeToString, reader::decode, hasKey = { false })
        assertEquals(KeystoreSeal.Opened.KeyGone, gone.opened(current))
        assertNull(gone.open(current))
        val unanswered = KeystoreSeal({ key }, codec::encodeToString, reader::decode, hasKey = { error("locked") })
        assertTrue(unanswered.opened(current) is KeystoreSeal.Opened.Failed)
        val unavailable = KeystoreSeal({ error("unavailable") }, codec::encodeToString, reader::decode)
        assertTrue(unavailable.opened(current) is KeystoreSeal.Opened.Failed)
        assertTrue(seal().opened("not an envelope") is KeystoreSeal.Opened.Failed)
        val parts = current.split(':')
        val payload = reader.decode(parts[1]).also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertTrue(seal().opened(parts[0] + ":" + codec.encodeToString(payload)) is KeystoreSeal.Opened.Failed)
    }
}
