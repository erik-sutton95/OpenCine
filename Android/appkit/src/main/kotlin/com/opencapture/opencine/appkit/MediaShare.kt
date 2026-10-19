package com.opencapture.opencine.appkit

import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.FileProvider
import com.opencapture.opencine.media.MonitorMediaShareIntentSpec
import com.opencapture.opencine.media.MonitorMediaShareStager
import com.opencapture.opencine.media.MonitorMediaShareStagingPolicy
import com.opencapture.opencine.media.MonitorStagedMediaShare
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Shares and saves delivered media files for every app: the share sheet through the app's
 * FileProvider (authority `<package>[authoritySuffix]`, declared in the app manifest over the
 * directories delivered files live in), the gallery through MediaStore in the [album] folder.
 * A delivered file outside those directories (the private no-backup cache, which FileProvider
 * cannot name) is shared through a copy in `cacheDir/share/ready`, so the app's paths also declare
 * `<cache-path path="share/ready/">` ([staging] bounds that copy cache).
 */
public class MediaShare(
    album: String,
    private val authoritySuffix: String = ".mediafileprovider",
    private val batchLabel: String = "$album media",
    private val staging: MonitorMediaShareStagingPolicy = DEFAULT_STAGING,
) {
    public val insertPolicy: MediaStoreInsertPolicy = MediaStoreInsertPolicy(album)

    /**
     * The chooser for already-delivered files, with read grants on every URI and the "Include
     * metadata" summary as `EXTRA_TEXT` when not blank (A2-51). [displayName] is the title a
     * file is shared under (a staged copy may carry a private name). Null unless every file has a
     * URI, so a selected clip is never silently left out of the share.
     * Copies files outside the provider paths, so call it off the main thread.
     */
    public fun chooserIntent(context: Context, files: List<File>, mimeType: (File) -> String,
        metadataText: String? = null, displayName: (File) -> String = { it.name }): Intent? {
        val stager = lazy { MonitorMediaShareStager(context.cacheDir.toPath(), staging) }
        val shared = files.map { file ->
            val mime = mimeType(file)
            val name = displayName(file)
            val uri = providerUri(context, file)
                // IA-552: a file in the private cache is shared through its provider-visible copy.
                ?: runCatching { stager.value.stagePreparedArtifact(file.toPath(), file.length(), name, STAGED_MIME) }
                    .getOrNull()?.let { providerUri(context, it.file.toFile()) }
                // An app without the share/ready path still shares a single file through its gallery copy.
                ?: if (files.size == 1) insertIntoGallery(context, file, mime) else null
            uri?.let { MonitorStagedMediaShare(file.toPath(), name, mime) to it } ?: return null
        }
        if (shared.isEmpty()) return null
        val spec = MonitorMediaShareIntentSpec.forShares(shared.map { it.first }, batchLabel, metadataText)
        val uris = shared.map { it.second }
        val clipData = ClipData.newRawUri(spec.clipDataLabel, uris.first())
        uris.drop(1).forEach { clipData.addItem(ClipData.Item(it)) }
        val send = Intent(spec.action).apply {
            type = spec.mimeType
            if (uris.size == 1) {
                putExtra(Intent.EXTRA_STREAM, uris.single())
                putExtra(Intent.EXTRA_TITLE, shared.single().first.displayName)
            } else {
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
                putExtra(Intent.EXTRA_TITLE, batchLabel)
            }
            spec.text?.let { putExtra(Intent.EXTRA_TEXT, it) }
            this.clipData = clipData
            if (spec.grantsReadUriPermission) addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return Intent.createChooser(send, spec.chooserTitle).apply {
            if (spec.grantsReadUriPermission) addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    /** Photos for delivered files: one gallery insert per file, off the main thread. */
    public fun photos(context: Context, mimeType: (File) -> String): MonitorDeliveryPhotosService<File> =
        MonitorDeliveryPhotosService { file ->
            withContext(Dispatchers.IO) { insertIntoGallery(context, file, mimeType(file)) != null }
        }

    public fun insertIntoGallery(context: Context, file: File, mime: String): Uri? {
        val isImage = MediaStoreInsertPolicy.isImage(mime)
        val collection =
            if (isImage) {
                if (Build.VERSION.SDK_INT >= 29) {
                    MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                } else {
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                }
            } else {
                if (Build.VERSION.SDK_INT >= 29) {
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                } else {
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                }
            }
        val values =
            ContentValues().apply {
                put(
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    insertPolicy.sanitizeDisplayName(file.name),
                )
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                if (Build.VERSION.SDK_INT >= 29) {
                    // Images must land under DCIM/Pictures, video under Movies.
                    // "Movies" for the images collection is rejected with
                    // IllegalArgumentException (#348).
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        insertPolicy.relativePath(mime),
                    )
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
            }
        // A bad name/mime/volume must skip the share, never crash the sheet.
        val uri =
            runCatching { context.contentResolver.insert(collection, values) }.getOrNull()
                ?: return null
        val copied =
            runCatching {
                context.contentResolver.openOutputStream(uri)?.use { out ->
                    file.inputStream().use { it.copyTo(out) }
                } ?: return@runCatching false
                true
            }.getOrDefault(false)
        if (!copied) {
            runCatching { context.contentResolver.delete(uri, null, null) }
            return null
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            runCatching { context.contentResolver.update(uri, done, null, null) }
        }
        return uri
    }

    private fun providerAuthority(context: Context): String = "${context.packageName}$authoritySuffix"

    private fun providerUri(context: Context, file: File): Uri? =
        runCatching { FileProvider.getUriForFile(context, providerAuthority(context), file) }.getOrNull()

    public companion object {
        /** The default provider authority (also used for diagnostics shares). */
        public fun authority(context: Context): String = "${context.packageName}.mediafileprovider"

        /**
         * Share copies of private-cache files: room for a few camera originals, kept long enough
         * for the receiving app to read its temporary grant.
         */
        public val DEFAULT_STAGING: MonitorMediaShareStagingPolicy =
            MonitorMediaShareStagingPolicy(8L * 1024 * 1024 * 1024, 32, 10L * 60 * 1000, 64 * 1024)

        // The chooser carries each file's own MIME; the staged copy only needs a valid one.
        private const val STAGED_MIME = "application/octet-stream"
    }
}

/**
 * MediaStore insert rules that are easy to get wrong and crash when wrong (#348).
 *
 * `MediaProvider` validates the top of `RELATIVE_PATH` against the target
 * collection: photos must live under `Pictures`/`DCIM`, video under `Movies`.
 * Inserting a photo into the Images collection with `RELATIVE_PATH = Movies/...`
 * is rejected with `IllegalArgumentException`, so the directory follows the
 * MIME and never a fixed default.
 *
 * Literals, not `Environment.DIRECTORY_*`: AGP's mockable `android.jar` nils
 * those constants in unit tests, and the platform values are stable.
 */
public class MediaStoreInsertPolicy(private val album: String) {
    public val fallbackName: String = "${album}_media"

    public fun relativePath(mime: String): String =
        if (isImage(mime)) {
            "$PICTURES/$album"
        } else {
            "$MOVIES/$album"
        }

    /** Filesystem-safe `DISPLAY_NAME`; a path separator or NUL is rejected by MediaStore. */
    public fun sanitizeDisplayName(name: String): String {
        val cleaned =
            name.replace('/', '_').replace('\u0000', '_').filterNot { it.isISOControl() }.trim()
        return cleaned.ifEmpty { fallbackName }
    }

    public companion object {
        public const val PICTURES: String = "Pictures"
        public const val MOVIES: String = "Movies"

        public fun isImage(mime: String): Boolean = mime.startsWith("image/")
    }
}
