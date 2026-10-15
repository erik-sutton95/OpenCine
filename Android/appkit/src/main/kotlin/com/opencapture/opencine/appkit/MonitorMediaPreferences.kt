package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.monitorui.MonitorThumbnailSize
import java.io.File

/** The gallery choices an operator gets back next time: tab, order, layout and thumbnail size. */
public data class MonitorMediaViewOptions(
    public val category: MonitorMediaCategoryFilter = MonitorMediaCategoryFilter.ALL,
    public val sort: MonitorMediaSort = MonitorMediaSort.NEWEST,
    public val layout: MonitorMediaLayout = MonitorMediaLayout.GRID,
    public val thumbnailSize: MonitorThumbnailSize = MonitorThumbnailSize.MEDIUM,
)
public interface MonitorMediaViewOptionsStore {
    public fun viewOptions(): MonitorMediaViewOptions
    public fun saveViewOptions(options: MonitorMediaViewOptions)
}

/** The key/value file media preferences live in; a null value removes the key. */
public interface MonitorMediaPreferenceStorage {
    public fun getString(key: String): String?
    public fun putString(key: String, value: String?)
}

/** The app supplies its exact storage file, keys and legacy favorite separator. Loading is read-only.
 * With [viewKeyPrefix] the gallery view options persist under `<prefix>.category`, `.sort`, `.layout`
 * and `.thumbnail-size`. */
public class MonitorMediaPreferences(
    private val storage: MonitorMediaPreferenceStorage, private val favoriteKey: String, private val lastCameraKey: String,
    private val favoriteSeparator: String, private val viewKeyPrefix: String? = null,
) : MonitorMediaFavoritesStore, MonitorMediaViewOptionsStore {
    public constructor(storage: SharedPreferences, favoriteKey: String, lastCameraKey: String, favoriteSeparator: String,
        viewKeyPrefix: String? = null) : this(object : MonitorMediaPreferenceStorage {
            override fun getString(key: String): String? = storage.getString(key, null)
            override fun putString(key: String, value: String?) {
                storage.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
            }
        }, favoriteKey, lastCameraKey, favoriteSeparator, viewKeyPrefix)
    init { require(favoriteKey.isNotEmpty() && lastCameraKey.isNotEmpty() && favoriteKey != lastCameraKey && favoriteSeparator.isNotEmpty() &&
        viewKeyPrefix?.isNotEmpty() != false) }
    override fun favorites(): Set<String> = storage.getString(favoriteKey)?.split(favoriteSeparator)?.filter { it.isNotEmpty() }?.toSet().orEmpty()
    override fun saveFavorites(keys: Set<String>) { storage.putString(favoriteKey, keys.sorted().joinToString(favoriteSeparator)) }
    override fun viewOptions(): MonitorMediaViewOptions {
        val prefix = viewKeyPrefix ?: return MonitorMediaViewOptions()
        val defaults = MonitorMediaViewOptions()
        return MonitorMediaViewOptions(enumValue("$prefix.category", defaults.category), enumValue("$prefix.sort", defaults.sort),
            enumValue("$prefix.layout", defaults.layout), enumValue("$prefix.thumbnail-size", defaults.thumbnailSize))
    }
    override fun saveViewOptions(options: MonitorMediaViewOptions) {
        val prefix = viewKeyPrefix ?: return
        storage.putString("$prefix.category", options.category.name); storage.putString("$prefix.sort", options.sort.name)
        storage.putString("$prefix.layout", options.layout.name); storage.putString("$prefix.thumbnail-size", options.thumbnailSize.name)
    }
    private inline fun <reified V : Enum<V>> enumValue(key: String, fallback: V): V =
        storage.getString(key)?.let { value -> enumValues<V>().firstOrNull { it.name == value } } ?: fallback
    public var lastCamera: String?
        get() = storage.getString(lastCameraKey)
        set(value) { storage.putString(lastCameraKey, value) }
}

/** One explicit app-lifetime storage registry, retained across camera/model replacement. */
public class MonitorMediaCacheStorage {
    private val directories = mutableMapOf<String, MonitorMediaCacheDirectory>()
    public fun directory(root: File): MonitorMediaCacheDirectory = synchronized(directories) {
        // Resolve trusted ancestors, retaining the camera leaf lexically. A live leaf alias
        // must not redirect ownership of a retired sibling into an unrelated directory.
        val normalized = root.absoluteFile.normalize()
        val root = normalized.parentFile?.canonicalFile?.let { File(it, normalized.name) } ?: normalized
        directories.getOrPut(root.path) { MonitorMediaCacheDirectory(root) }
    }
    /** Every live or valid retired child camera namespace once, in stable order. */
    public fun directories(parent: File): List<MonitorMediaCacheDirectory> =
        MonitorMediaCacheNamespaces.names(parent).map { directory(File(parent, it)) }

}
