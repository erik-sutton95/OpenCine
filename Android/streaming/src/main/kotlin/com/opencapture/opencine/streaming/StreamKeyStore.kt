package com.opencapture.opencine.streaming

import android.content.Context
import com.opencapture.opencine.platform.KeystoreSeal

/** Plain string storage for sealed values; production is one app-private preferences file. */
interface StreamKeyStorage {
    fun get(name: String): String?

    fun put(name: String, value: String): Boolean

    fun remove(name: String): Boolean
}

/** The device-only envelope keys are sealed in; production is [KeystoreSeal]. */
interface StreamSecretSeal {
    sealed interface Opened {
        class Secret(val secret: String) : Opened {
            override fun toString(): String = "Secret"
        }

        /** The device key is gone (a restored backup or a reset Keystore). */
        data object KeyGone : Opened

        /** The Keystore did not answer or the envelope is damaged. */
        data object Failed : Opened
    }

    fun seal(secret: String): String?

    fun open(stored: String): Opened
}

/**
 * Stream keys, and entered server addresses, per preset, sealed with a device-only Keystore key.
 * Names are `stream-key.<presetId>` and `stream-server.<presetId>`. A key the device can no longer
 * open reads as [Lookup.Unavailable], never [Lookup.Absent], so the page asks to enter it again
 * instead of pretending none was saved.
 */
class StreamKeyStore(private val storage: StreamKeyStorage, private val seal: StreamSecretSeal) {
    sealed interface Lookup {
        data object Absent : Lookup

        class Stored(val value: String) : Lookup {
            override fun equals(other: Any?): Boolean = other is Stored && other.value == value
            override fun hashCode(): Int = value.hashCode()
            override fun toString(): String = "Stored"
        }

        data object Unavailable : Lookup
    }

    fun key(presetId: String): Lookup = read("stream-key.$presetId")

    fun server(presetId: String): Lookup = read("stream-server.$presetId")

    /** Saves both values; a null [server] removes a saved one. False when sealing failed. */
    fun save(key: String, server: String?, presetId: String): Boolean {
        val sealedKey = seal.seal(key) ?: return false
        val sealedServer = server?.let { seal.seal(it) ?: return false }
        if (!storage.put("stream-key.$presetId", sealedKey)) return false
        return if (sealedServer != null) {
            storage.put("stream-server.$presetId", sealedServer)
        } else {
            storage.remove("stream-server.$presetId")
        }
    }

    fun remove(presetId: String): Boolean =
        storage.remove("stream-key.$presetId") and storage.remove("stream-server.$presetId")

    override fun toString(): String = "StreamKeyStore"

    private fun read(name: String): Lookup {
        val stored = storage.get(name) ?: return Lookup.Absent
        return when (val opened = seal.open(stored)) {
            is StreamSecretSeal.Opened.Secret -> Lookup.Stored(opened.secret)
            StreamSecretSeal.Opened.KeyGone, StreamSecretSeal.Opened.Failed -> Lookup.Unavailable
        }
    }

    companion object {
        /** The production store: [preferencesFile] and [keystoreAlias] are host values. */
        fun create(context: Context, preferencesFile: String, keystoreAlias: String): StreamKeyStore {
            val preferences = context.applicationContext.getSharedPreferences(preferencesFile, Context.MODE_PRIVATE)
            val storage = object : StreamKeyStorage {
                override fun get(name: String): String? = preferences.getString(name, null)
                override fun put(name: String, value: String): Boolean = preferences.edit().putString(name, value).commit()
                override fun remove(name: String): Boolean = preferences.edit().remove(name).commit()
            }
            val envelope = KeystoreSeal(keystoreAlias)
            val seal = object : StreamSecretSeal {
                override fun seal(secret: String): String? = envelope.seal(secret)
                override fun open(stored: String): StreamSecretSeal.Opened = when (val opened = envelope.opened(stored)) {
                    is KeystoreSeal.Opened.Secret -> StreamSecretSeal.Opened.Secret(opened.secret)
                    KeystoreSeal.Opened.KeyGone -> StreamSecretSeal.Opened.KeyGone
                    is KeystoreSeal.Opened.Failed -> StreamSecretSeal.Opened.Failed
                }
            }
            return StreamKeyStore(storage, seal)
        }
    }
}
