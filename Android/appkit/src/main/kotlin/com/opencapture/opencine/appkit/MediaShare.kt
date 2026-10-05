package com.opencapture.opencine.appkit

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File

/**
 * Shares and saves cached media files: the share sheet through the app's FileProvider (authority
 * `<package>.mediafileprovider`, declared in the app manifest), the gallery through MediaStore in
 * the [album] folder.
 */
public class MediaShare(album: String) {
    public val insertPolicy: MediaStoreInsertPolicy = MediaStoreInsertPolicy(album)

    public fun shareCachedFile(context: Context, file: File, mime: String): Boolean {
        val uri = uriFor(context, file, mime) ?: return false
        val intent =
            Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        val chooser = Intent.createChooser(intent, null)
        if (context !is android.app.Activity) {
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(chooser)
        return true
    }

    /** One file goes through [shareCachedFile]; several share as one multiple-stream intent. */
    public fun shareFiles(context: Context, files: List<File>, mimeType: (String) -> String): Boolean {
        if (files.size == 1) {
            return shareCachedFile(
                context,
                files.first(),
                mimeType(files.first().name),
            )
        }
        val uris = ArrayList<Uri>()
        for (file in files) {
            val uri =
                runCatching { FileProvider.getUriForFile(context, authority(context), file) }.getOrNull()
                    ?: continue
            uris.add(uri)
        }
        if (uris.isEmpty()) {
            val first = files.firstOrNull() ?: return false
            return shareCachedFile(context, first, mimeType(first.name))
        }
        val mime = if (uris.size == 1) mimeType(files.first().name) else "*/*"
        val intent =
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = mime
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        val chooser = Intent.createChooser(intent, null)
        if (context !is android.app.Activity) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(chooser)
        return true
    }

    private fun uriFor(context: Context, file: File, mime: String): Uri? {
        runCatching {
            return FileProvider.getUriForFile(context, authority(context), file)
        }
        return insertIntoGallery(context, file, mime)
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

    public companion object {
        public fun authority(context: Context): String = "${context.packageName}.mediafileprovider"
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
