package com.opencapture.opencine.frameio

import android.content.Context
import android.content.SharedPreferences

/** App-private completion history keyed only by a stable camera clip identity. */
interface FrameioUploadHistoryStore {
    /** Returns true only after Frame.io previously confirmed this clip's upload. */
    fun wasUploaded(stableClipIdentity: String): Boolean

    /** Durably records a confirmed upload; false means the private store rejected the write. */
    fun recordUploaded(stableClipIdentity: String): Boolean
}

/** Test/default store that never skips an artifact and retains no state. */
object NoFrameioUploadHistoryStore : FrameioUploadHistoryStore {
    override fun wasUploaded(stableClipIdentity: String): Boolean = false

    override fun recordUploaded(stableClipIdentity: String): Boolean = true
}

/** Bounded SharedPreferences history. It never stores filenames, project ids, or cloud responses. */
class AndroidFrameioUploadHistoryStore(context: Context, namespace: FrameioStorageNamespace) : FrameioUploadHistoryStore {
    private val preferences: SharedPreferences =
        context.getSharedPreferences(namespace.historyPreferences, Context.MODE_PRIVATE)
    private val index =
        FrameioUploadHistoryIndex(
            loadValue = { preferences.getString(HISTORY_KEY, null) },
            saveValue = { value -> preferences.edit().putString(HISTORY_KEY, value).commit() },
        )

    override fun wasUploaded(stableClipIdentity: String): Boolean =
        index.wasUploaded(stableClipIdentity)

    override fun recordUploaded(stableClipIdentity: String): Boolean =
        index.recordUploaded(stableClipIdentity)

    private companion object {
        const val HISTORY_KEY = "confirmed.v1"
    }
}

/**
 * Pure bounded history codec (Swift twin: FrameioUploadHistoryIndex in OpenCineFrameIO): at most
 * [maximumIdentities] identities of `[A-Za-z0-9_-]{1,128}`, oldest dropped first. Load and save
 * are injected; this codec names no storage.
 */
class FrameioUploadHistoryIndex(
    private val loadValue: () -> String?,
    private val saveValue: (String) -> Boolean,
    private val maximumIdentities: Int = 4_096,
) : FrameioUploadHistoryStore {
    init {
        require(maximumIdentities > 0) { "Frame.io history capacity must be positive." }
    }

    override fun wasUploaded(stableClipIdentity: String): Boolean =
        stableClipIdentity.isSafeHistoryIdentity() && stableClipIdentity in load()

    override fun recordUploaded(stableClipIdentity: String): Boolean {
        if (!stableClipIdentity.isSafeHistoryIdentity()) return false
        val identities = LinkedHashSet(load())
        identities.remove(stableClipIdentity)
        identities.add(stableClipIdentity)
        while (identities.size > maximumIdentities) identities.remove(identities.first())
        return saveValue(identities.joinToString(separator = "\n"))
    }

    private fun load(): List<String> =
        loadValue()
            ?.lineSequence()
            ?.filter { identity -> identity.isSafeHistoryIdentity() }
            ?.take(maximumIdentities)
            ?.toList()
            .orEmpty()
}

private fun String.isSafeHistoryIdentity(): Boolean =
    length in 1..128 &&
        all { character ->
            character in 'a'..'z' ||
                character in 'A'..'Z' ||
                character in '0'..'9' ||
                character == '-' ||
                character == '_'
        }
