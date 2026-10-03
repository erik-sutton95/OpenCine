package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import java.io.File

/** The app supplies its exact storage file, keys and legacy favorite separator. Loading is read-only. */
public class MonitorMediaPreferences(
    private val storage: SharedPreferences, private val favoriteKey: String, private val lastCameraKey: String,
    private val favoriteSeparator: String,
) : MonitorMediaFavoritesStore {
    init { require(favoriteKey.isNotEmpty() && lastCameraKey.isNotEmpty() && favoriteKey != lastCameraKey && favoriteSeparator.isNotEmpty()) }
    override fun favorites(): Set<String> = storage.getString(favoriteKey, null)?.split(favoriteSeparator)?.filter { it.isNotEmpty() }?.toSet().orEmpty()
    override fun saveFavorites(keys: Set<String>) { storage.edit().putString(favoriteKey, keys.sorted().joinToString(favoriteSeparator)).apply() }
    public var lastCamera: String?
        get() = storage.getString(lastCameraKey, null)
        set(value) { if (value == null) storage.edit().remove(lastCameraKey).apply() else storage.edit().putString(lastCameraKey, value).apply() }
}

/** One explicit app-lifetime storage registry, retained across camera/model replacement. */
public class MonitorMediaCacheStorage {
    private val directories = mutableMapOf<String, MonitorMediaCacheDirectory>()
    public fun directory(root: File): MonitorMediaCacheDirectory = synchronized(directories) {
        val root = root.canonicalFile
        directories.getOrPut(root.path) { MonitorMediaCacheDirectory(root) }
    }
}
