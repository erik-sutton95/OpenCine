package com.opencapture.opencine.cameracontrols

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import com.opencapture.monitorui.TeleprompterScript
import com.opencapture.monitorui.TeleprompterScriptImport
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Native import IO; uses the current route without camera Wi-Fi or handover services. */
internal object MonitorTeleprompterImport {
    suspend fun document(resolver: ContentResolver, uri: Uri): TeleprompterScript = withContext(Dispatchers.IO) {
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
        } ?: uri.lastPathSegment ?: "script.txt"
        val bytes = resolver.openInputStream(uri)?.use { readBounded(it) }
            ?: throw IllegalArgumentException("The selected script could not be opened.")
        TeleprompterScriptImport.decode(bytes, name, contentType = resolver.getType(uri))
    }

    suspend fun remote(value: String,
        connectionFactory: (String) -> HttpURLConnection = { URI(it).toURL().openConnection() as HttpURLConnection },
    ): TeleprompterScript = withContext(Dispatchers.IO) {
        val initial = TeleprompterScriptImport.link(value)
        var address = initial
        repeat(6) { redirects ->
            currentCoroutineContext().ensureActive()
            val connection = connectionFactory(address)
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Accept", "text/plain, text/markdown")
            val cancellation = launch(start = CoroutineStart.UNDISPATCHED) { try { awaitCancellation() } finally { connection.disconnect() } }
            try {
                val status = connection.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    require(redirects < 5) { "The script link redirected too many times." }
                    val destination = connection.getHeaderField("Location")
                        ?: throw IllegalArgumentException("The script link has no download destination.")
                    address = TeleprompterScriptImport.link(URI(address).resolve(destination).toString())
                } else {
                    require(status in 200..299) { "The script link returned HTTP $status. Open a direct text or Markdown link." }
                    require(connection.contentLengthLong <= TeleprompterScriptImport.MAXIMUM_BYTES) { "The script is larger than 1 MiB." }
                    val bytes = connection.inputStream.use { readBounded(it) }
                    return@withContext TeleprompterScriptImport.decode(bytes,
                        URI(address).path.substringAfterLast('/').ifBlank { "Linked script" }, initial, connection.contentType)
                }
            } catch (failure: Exception) {
                currentCoroutineContext().ensureActive()
                throw failure
            } finally { cancellation.cancel(); connection.disconnect() }
        }
        throw IllegalArgumentException("The script link redirected too many times.")
    }

    private suspend fun readBounded(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            currentCoroutineContext().ensureActive()
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= TeleprompterScriptImport.MAXIMUM_BYTES) { "The script is larger than 1 MiB." }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}
