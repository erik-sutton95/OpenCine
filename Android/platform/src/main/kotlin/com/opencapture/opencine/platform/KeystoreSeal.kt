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
) {
    constructor(alias: String) : this(
        { deviceKey(alias) },
        { Base64.encodeToString(it, Base64.NO_WRAP) },
        { Base64.decode(it, Base64.NO_WRAP) },
    )

    fun seal(secret: String): String? = runCatching {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
        encode(cipher.iv) + SEPARATOR + encode(sealed)
    }.getOrNull()

    fun open(stored: String): String? {
        val parts = stored.split(SEPARATOR, limit = 2)
        if (parts.size != 2) return null
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            val iv = decode(parts[0])
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(decode(parts[1])), Charsets.UTF_8)
        }.getOrNull()
    }

    companion object {
        const val SEPARATOR = ":"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"

        private fun deviceKey(alias: String): SecretKey {
            val keystore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            (keystore.getKey(alias, null) as? SecretKey)?.let { return it }
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
