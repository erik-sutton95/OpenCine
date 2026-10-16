package com.opencapture.opencine.relayruntime

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.opencine.platform.KeystoreSeal

/**
 * The relay's secrets on Android: the host passcode and the passcodes remembered per host,
 * sealed with an Android Keystore key ([KeystoreSeal]). The twin of Swift's `WatcherRelayKeychain`.
 *
 * `service` names both the Keystore key and the private file holding the ciphertexts; it must not
 * change, or saved passcodes stop loading. The key never leaves this device, so a file restored
 * onto another device (or after the key was lost) reads as nothing stored, never as a passcode.
 *
 * Writes never delete first: a value is replaced in place, and a write counts only once the stored
 * value reads back equal. A read the Keystore cannot answer is [Lookup.Unavailable], never
 * "no passcode", so a broadcast never starts unprotected because of it.
 */
public class WatcherRelaySecrets internal constructor(private val items: WatcherRelaySecretItems) {
    public constructor(context: Context, service: String) :
        this(KeystoreSecretItems(context.applicationContext, service))

    /** What the store holds for one secret. */
    public sealed interface Lookup {
        /** The value to use: empty when nothing is stored, null when the store did not answer. */
        public val usableValue: String?

        /** Nothing is stored. */
        public data object Absent : Lookup { override val usableValue: String get() = "" }

        public data class Stored(val value: String) : Lookup { override val usableValue: String get() = value }

        /** The Keystore did not answer or the stored value could not be opened. */
        public data class Unavailable(val reason: String) : Lookup { override val usableValue: String? get() = null }
    }

    /** The result of moving a secret the app kept in plain text into the store. */
    public enum class LegacyMove {
        /** The old copy was empty; nothing to move. */
        NOTHING_TO_MOVE,
        /** Stored and read back equal; the old copy may now be removed. */
        MOVED,
        /** The store already holds this secret and keeps it; the old copy may be removed. */
        KEPT_STORED,
        /** Not stored; keep the old copy and try again later. */
        FAILED,
        ;

        /** Whether the old copy may now be removed. */
        public val releasesLegacyCopy: Boolean get() = this != FAILED
    }

    // Host passcode

    public fun hostPasscodeLookup(): Lookup = lookup(HOST_ACCOUNT)

    /** Stores the host passcode; empty clears it. True once the store reads it back. */
    public fun storeHostPasscode(code: String): Boolean = store(code, HOST_ACCOUNT)

    /** Moves a host passcode the app kept in plain text into the store. */
    public fun adoptLegacyHostPasscode(legacy: String): LegacyMove = adoptLegacy(legacy, HOST_ACCOUNT)

    /**
     * Moves the plain-text host passcode under [key] in [legacy] into the store, once: the
     * plain-text entry is removed only after the store confirmed it, and stays for the next try
     * otherwise.
     */
    public fun adoptLegacyHostPasscode(legacy: SharedPreferences, key: String): LegacyMove {
        if (!legacy.contains(key)) return LegacyMove.NOTHING_TO_MOVE
        val move = adoptLegacyHostPasscode(legacy.getString(key, null).orEmpty())
        if (move.releasesLegacyCopy) legacy.edit().remove(key).commit()
        return move
    }

    // Remembered passcodes

    public fun rememberedPasscodeLookup(host: String): Lookup = lookup(hostAccount(host))

    /** Stores the passcode for one host; empty clears it. True once the store reads it back. */
    public fun storeRememberedPasscode(code: String, host: String): Boolean = store(code, hostAccount(host))

    /** Moves one host's passcode the app kept in plain text into the store. */
    public fun adoptLegacyRememberedPasscode(legacy: String, host: String): LegacyMove =
        adoptLegacy(legacy, hostAccount(host))

    /**
     * Moves every plain-text passcode in [legacy] (one string entry per host name) into the store.
     * Each entry is removed only after the store confirmed it; one that failed stays for the next
     * try. True when no entry is left behind.
     */
    public fun adoptLegacyRememberedPasscodes(legacy: SharedPreferences): Boolean {
        var complete = true
        for ((host, value) in legacy.all) {
            val move = if (value is String) adoptLegacyRememberedPasscode(value, host) else LegacyMove.NOTHING_TO_MOVE
            if (move.releasesLegacyCopy) legacy.edit().remove(host).commit() else complete = false
        }
        return complete
    }

    // Storage

    private fun lookup(account: String): Lookup = when (val read = items.read(account)) {
        WatcherRelaySecretItems.Read.Missing -> Lookup.Absent
        is WatcherRelaySecretItems.Read.Value -> if (read.value.isEmpty()) Lookup.Absent else Lookup.Stored(read.value)
        is WatcherRelaySecretItems.Read.Failed -> Lookup.Unavailable(read.reason)
    }

    private fun store(value: String, account: String): Boolean {
        if (value.isEmpty()) return items.delete(account) && lookup(account) == Lookup.Absent
        return items.write(account, value) && lookup(account) == Lookup.Stored(value)
    }

    private fun adoptLegacy(legacy: String, account: String): LegacyMove {
        if (legacy.isEmpty()) return LegacyMove.NOTHING_TO_MOVE
        return when (lookup(account)) {
            is Lookup.Stored -> LegacyMove.KEPT_STORED
            is Lookup.Unavailable -> LegacyMove.FAILED
            Lookup.Absent -> {
                if (store(legacy, account)) return LegacyMove.MOVED
                // Nothing was stored before: leave it that way so the next try starts clean.
                items.delete(account)
                LegacyMove.FAILED
            }
        }
    }

    internal companion object {
        const val HOST_ACCOUNT: String = "host-passcode"
        fun hostAccount(name: String): String = "code.$name"
    }
}

/** The three item operations for one service. Production uses the Keystore; tests inject failures. */
internal interface WatcherRelaySecretItems {
    sealed interface Read {
        data object Missing : Read
        data class Value(val value: String) : Read
        data class Failed(val reason: String) : Read
    }

    fun read(account: String): Read

    /** Replaces the account's value in place. True once the platform accepted the write. */
    fun write(account: String, value: String): Boolean

    /** True once the account holds nothing. */
    fun delete(account: String): Boolean
}

/**
 * The platform [KeystoreSeal] (AES/GCM under a device-only Keystore key named after the service),
 * its envelopes kept in a private preferences file named after the service.
 */
internal class KeystoreSecretItems(context: Context, service: String) : WatcherRelaySecretItems {
    private val preferences: SharedPreferences = context.getSharedPreferences(service, Context.MODE_PRIVATE)
    private val seal = KeystoreSeal(service)

    override fun read(account: String): WatcherRelaySecretItems.Read {
        val stored = preferences.getString(account, null) ?: return WatcherRelaySecretItems.Read.Missing
        return when (val opened = seal.opened(stored)) {
            is KeystoreSeal.Opened.Secret -> WatcherRelaySecretItems.Read.Value(opened.secret)
            // Restored onto another device, or the key was lost: it can never be opened.
            KeystoreSeal.Opened.KeyGone -> WatcherRelaySecretItems.Read.Missing
            is KeystoreSeal.Opened.Failed -> WatcherRelaySecretItems.Read.Failed(opened.reason)
        }
    }

    override fun write(account: String, value: String): Boolean {
        val sealed = seal.seal(value) ?: return false
        return preferences.edit().putString(account, sealed).commit()
    }

    override fun delete(account: String): Boolean = preferences.edit().remove(account).commit()
}
