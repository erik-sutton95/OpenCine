package com.opencapture.opencine.platform

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-only AES/GCM envelope. The caller owns the key alias; inputs are never logged. */
class KeystoreSeal internal constructor(
    private val key: () -> SecretKey,
    private val encode: (ByteArray) -> String,
    private val decode: (String) -> ByteArray,
    private val hasKey: () -> Boolean = { true },
) {
    constructor(alias: String) : this(
        { deviceKey(alias) },
        { Base64.encodeToString(it, Base64.NO_WRAP) },
        { Base64.decode(it, Base64.NO_WRAP) },
        { existingKey(alias) != null },
    )

    /** What opening a stored envelope found. */
    sealed interface Opened {
        data class Secret(val secret: String) : Opened

        /**
         * The device key is gone (a file restored onto another device, or a reset Keystore): the
         * envelope can never be opened again.
         */
        data object KeyGone : Opened

        /** The Keystore did not answer or the envelope is damaged; it may open later. */
        data class Failed(val reason: String) : Opened
    }

    fun seal(secret: String): String? = runCatching {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
        encode(cipher.iv) + SEPARATOR + encode(sealed)
    }.getOrNull()

    fun open(stored: String): String? = (opened(stored) as? Opened.Secret)?.secret

    /** Opens [stored], telling a key that is gone from one that did not answer. */
    fun opened(stored: String): Opened {
        val parts = stored.split(SEPARATOR, limit = 2)
        if (parts.size != 2) return Opened.Failed("malformed")
        return runCatching {
            if (!hasKey()) return Opened.KeyGone
            val cipher = Cipher.getInstance(TRANSFORMATION)
            val iv = decode(parts[0])
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            Opened.Secret(String(cipher.doFinal(decode(parts[1])), Charsets.UTF_8))
        }.getOrElse { Opened.Failed(it.javaClass.simpleName) }
    }

    companion object {
        const val SEPARATOR = ":"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"

        /** One process-wide lock: a second key generated under an alias orphans the first's envelopes. */
        private val keyLock = Any()

        private fun existingKey(alias: String): SecretKey? = synchronized(keyLock) {
            val keystore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            keystore.getKey(alias, null) as? SecretKey
        }

        private fun deviceKey(alias: String): SecretKey = synchronized(keyLock) {
            existingKey(alias) ?: generateKey(alias)
        }

        private fun generateKey(alias: String): SecretKey {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
            generator.init(
                KeyGenParameterSpec.Builder(
                    alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            return generator.generateKey()
        }
    }
}
