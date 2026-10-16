package com.opencapture.opencine.cameracontrols

import android.annotation.SuppressLint
import android.content.Context
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.MonitorActionButton
import com.opencapture.monitorui.MonitorCameraAction
import com.opencapture.monitorui.MonitorIcon
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * A LUT pack the operator downloads from its maker's own web page (the maker's terms are accepted
 * there, never bundled): the page, the hosts a download may come from, the cookie origins that
 * carry the session, the page scripts that keep the terms on screen, and the operator copy. The
 * Swift twin is still app-owned (recorded in the DEDUP-Z-ANDROID lane report).
 */
public class MonitorLutPackSource(
    public val pageUrl: String,
    /** Cache file name for the in-progress archive. */
    public val archiveFileName: String,
    public val isAllowedDownload: (String) -> Boolean,
    /** Origins whose web cookies authorise the archive fetch when the download host has none. */
    public val cookieOrigins: List<String>,
    /** Injected on page start and finish: a cover while the maker's terms load. */
    public val loadingScript: String? = null,
    /** Injected on page finish: keeps only the terms dialog and its download action. */
    public val helperScript: String? = null,
    public val copy: MonitorLutPackCopy,
)

/** Every word the pack flow shows; the maker's name and the app's name arrive here. */
public class MonitorLutPackCopy(
    public val intro: String,
    public val introDetail: String,
    public val continueLabel: String,
    public val hopReady: String,
    public val hopUnavailable: String,
    public val downloading: String,
    public val success: (Int) -> String,
    public val successDetail: String,
    public val unexpectedSite: String,
    public val noFile: String,
    public val pageFailed: String,
    public val httpFailure: (Int) -> String,
    public val webPageInsteadOfArchive: String,
    public val notAnArchive: String,
    public val blockedTitle: String = "Internet required",
    public val switching: String = "Switching networks…",
    public val hopAction: String = "Download over internet",
    public val importing: String = "Adding LUTs…",
    public val failedTitle: String = "Download failed",
    public val downloadFailed: String = "Download failed.",
)

/** Where the phone's internet stands for the pack download, decided by the host's network policy. */
public enum class MonitorLutPackNetwork { AVAILABLE, ON_CAMERA_ACCESS_POINT, NO_INTERNET, POLICY_UNAVAILABLE }

/** The network state and the operator's words for it. */
public data class MonitorLutPackReadiness(public val network: MonitorLutPackNetwork, public val message: String)

/**
 * The host's camera access point hop: leave the camera's Wi-Fi for an internet route and rejoin it
 * after the flow closes. Absent when this surface cannot hop.
 */
public interface MonitorLutPackInternetHop {
    /** True when a hop can start now. */
    public val ready: Boolean
    /** Why a hop cannot start, when [ready] is false. */
    public val unavailableMessage: String?
    /** Leaving the camera or waiting for internet. */
    public val switching: Boolean
    public val active: Boolean
    public val errorMessage: String?
    public suspend fun begin(): Boolean
    /** Rejoins the camera after the flow has closed; never awaited before closing. */
    public fun endAfterDismiss()
}

/** What the host's import made of the downloaded file: a count, or the operator's failure words. */
public sealed interface MonitorLutPackOutcome {
    public data class Imported(public val count: Int) : MonitorLutPackOutcome
    public data class Failed(public val message: String) : MonitorLutPackOutcome
}

private sealed interface PackPhase {
    data object Gateway : PackPhase
    data object Browsing : PackPhase
    data object Downloading : PackPhase
    data object Importing : PackPhase
    data class Success(val count: Int) : PackPhase
    data class Failed(val message: String) : PackPhase
}

/**
 * The full-screen pack download: a gateway (terms, blocked or hop), the maker's real page in a web
 * view, the fetched archive, then the host's import. Closing never waits for the camera rejoin.
 */
@Composable
public fun MonitorLutPackDownloadScreen(
    source: MonitorLutPackSource,
    readiness: () -> MonitorLutPackReadiness,
    hop: MonitorLutPackInternetHop?,
    /** Shown when the operator asks for a hop and this surface has none. */
    noHopMessage: String,
    /** Shown when a hop fails without its own words. */
    hopFailedMessage: String,
    closeLabel: String,
    importPack: suspend (File) -> MonitorLutPackOutcome,
    onClose: () -> Unit,
    onImported: (Int) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val copy = source.copy
    var state by remember { mutableStateOf(readiness()) }
    var phase by remember { mutableStateOf<PackPhase>(PackPhase.Gateway) }
    var progress by remember { mutableFloatStateOf(0f) }
    var hopBusy by remember { mutableStateOf(false) }
    var hopError by remember { mutableStateOf<String?>(null) }

    // The camera rejoins after the cover is gone; closing never waits for it.
    DisposableEffect(hop) { onDispose { if (hop != null && hop.active) hop.endAfterDismiss() } }

    fun requestHop() {
        if (hop == null) { hopError = noHopMessage; return }
        if (!hop.ready) { hopError = hop.unavailableMessage?.ifBlank { null } ?: hopFailedMessage; return }
        scope.launch {
            hopBusy = true
            hopError = null
            val ok = try { hop.begin() } catch (_: Exception) { false }
            hopBusy = false
            if (!ok) hopError = hop.errorMessage ?: hopFailedMessage
            state = readiness()
        }
    }

    LaunchedEffect(Unit) {
        while (true) {
            state = readiness()
            if (state.network == MonitorLutPackNetwork.AVAILABLE) hopError = null
            delay(1_000)
        }
    }
    val switching = hopBusy || hop?.switching == true
    BackHandler { onClose() }

    Box(Modifier.fillMaxSize().background(LiveDesign.background)) {
        when (val current = phase) {
            PackPhase.Gateway -> PackGateway(copy, state, switching, hopError, canHop = hop?.ready == true,
                closeLabel = closeLabel,
                onContinue = {
                    when (state.network) {
                        MonitorLutPackNetwork.AVAILABLE, MonitorLutPackNetwork.POLICY_UNAVAILABLE -> phase = PackPhase.Browsing
                        MonitorLutPackNetwork.ON_CAMERA_ACCESS_POINT -> requestHop()
                        MonitorLutPackNetwork.NO_INTERNET -> Unit
                    }
                }, onHop = ::requestHop, onClose = onClose)
            PackPhase.Browsing -> PackWebView(source,
                onDownloadStarted = { phase = PackPhase.Downloading },
                onProgress = { progress = it },
                onFileReady = { file ->
                    phase = PackPhase.Importing
                    scope.launch {
                        val outcome = withContext(Dispatchers.IO) { importPack(file) }
                        runCatching { file.delete() }
                        phase = when (outcome) {
                            is MonitorLutPackOutcome.Imported -> { onImported(outcome.count); PackPhase.Success(outcome.count) }
                            is MonitorLutPackOutcome.Failed -> PackPhase.Failed(outcome.message)
                        }
                    }
                },
                onFailed = { phase = PackPhase.Failed(it) })
            PackPhase.Downloading -> PackStatusPage(copy.downloading, null, progress, null, "Cancel" to onClose)
            PackPhase.Importing -> PackStatusPage(copy.importing, null, null, null, "Cancel" to onClose)
            is PackPhase.Success -> PackStatusPage(copy.success(current.count), copy.successDetail, null, "Done" to onClose)
            is PackPhase.Failed -> PackStatusPage(copy.failedTitle, current.message, null,
                "Retry" to { phase = PackPhase.Gateway; progress = 0f }, closeLabel to onClose)
        }
        // Above the web view so the close button always receives taps.
        MonitorActionButton(closeLabel,
            modifier = Modifier.align(Alignment.TopStart).zIndex(2f).statusBarsPadding().padding(start = 8.dp, top = 4.dp),
            onClick = onClose) { tint -> MonitorIcon(MonitorIcon.X, null, Modifier.size(18.dp), tint) }
    }
}

@Composable
private fun PackGateway(copy: MonitorLutPackCopy, readiness: MonitorLutPackReadiness, switching: Boolean,
    hopError: String?, canHop: Boolean, closeLabel: String, onContinue: () -> Unit, onHop: () -> Unit, onClose: () -> Unit) {
    // Only block when there is no internet path (camera access point or offline).
    val blocked = readiness.network == MonitorLutPackNetwork.ON_CAMERA_ACCESS_POINT ||
        readiness.network == MonitorLutPackNetwork.NO_INTERNET
    Column(Modifier.fillMaxSize().padding(horizontal = 28.dp, vertical = 36.dp),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        if (blocked || switching) {
            Text(copy.blockedTitle, style = LiveType.ui(20f, FontWeight.Bold), color = LiveDesign.text, textAlign = TextAlign.Center)
            Spacer(Modifier.height(12.dp))
            if (switching) {
                CircularProgressIndicator(color = LiveDesign.accent, modifier = Modifier.size(28.dp))
                Spacer(Modifier.height(12.dp))
                Text(copy.switching, style = LiveType.ui(14f, FontWeight.SemiBold), color = LiveDesign.text,
                    textAlign = TextAlign.Center)
            } else {
                Text(hopError ?: readiness.message, style = LiveType.ui(14f), color = LiveDesign.muted,
                    textAlign = TextAlign.Center)
                Spacer(Modifier.height(20.dp))
                if (readiness.network == MonitorLutPackNetwork.ON_CAMERA_ACCESS_POINT) {
                    MonitorCameraAction(copy.hopAction, primary = true, enabled = canHop,
                        contentDescription = copy.hopAction, onClick = onHop, modifier = Modifier.fillMaxWidth())
                    Spacer(Modifier.height(8.dp))
                    Text(if (canHop) copy.hopReady else copy.hopUnavailable, style = LiveType.ui(12f),
                        color = LiveDesign.muted, textAlign = TextAlign.Center)
                }
            }
            Spacer(Modifier.height(16.dp))
            val dismiss = if (switching) "Cancel" else closeLabel
            MonitorCameraAction(dismiss, primary = false, enabled = true, contentDescription = dismiss,
                onClick = onClose, modifier = Modifier.fillMaxWidth())
        } else {
            Text(copy.intro, style = LiveType.ui(15f, FontWeight.Medium), color = LiveDesign.text, textAlign = TextAlign.Center)
            Spacer(Modifier.height(12.dp))
            Text(copy.introDetail, style = LiveType.ui(13f), color = LiveDesign.muted, textAlign = TextAlign.Center)
            Spacer(Modifier.height(24.dp))
            MonitorCameraAction(copy.continueLabel, primary = true, enabled = true,
                contentDescription = copy.continueLabel, onClick = onContinue, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(12.dp))
            MonitorCameraAction(closeLabel, primary = false, enabled = true, contentDescription = closeLabel,
                onClick = onClose, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun PackStatusPage(title: String, body: String?, progress: Float?, primary: Pair<String, () -> Unit>?,
    secondary: Pair<String, () -> Unit>? = null) {
    Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        if (progress == null && primary == null) {
            CircularProgressIndicator(color = LiveDesign.accent, modifier = Modifier.size(36.dp))
            Spacer(Modifier.height(16.dp))
        }
        Text(title, style = LiveType.ui(18f, FontWeight.Bold), color = LiveDesign.text, textAlign = TextAlign.Center)
        body?.let {
            Spacer(Modifier.height(10.dp))
            Text(it, style = LiveType.ui(13f), color = LiveDesign.muted, textAlign = TextAlign.Center)
        }
        progress?.let {
            Spacer(Modifier.height(16.dp))
            LinearProgressIndicator(progress = { it.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth(0.7f),
                color = LiveDesign.accent, trackColor = LiveDesign.glassBright)
        }
        primary?.let { (label, action) ->
            Spacer(Modifier.height(20.dp))
            MonitorCameraAction(label, primary = true, enabled = true, contentDescription = label, onClick = action,
                modifier = Modifier.fillMaxWidth())
        }
        secondary?.let { (label, action) ->
            Spacer(Modifier.height(10.dp))
            MonitorCameraAction(label, primary = false, enabled = true, contentDescription = label, onClick = action,
                modifier = Modifier.fillMaxWidth())
        }
    }
}

/**
 * The maker's page with the source's scripts. Popup (`window.open`) and attachment navigations to an
 * allowed host are fetched in-process with the page's cookies; the system download manager is not
 * used (it misses popup downloads and often drops the session on a storage redirect).
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun PackWebView(source: MonitorLutPackSource, onDownloadStarted: () -> Unit, onProgress: (Float) -> Unit,
    onFileReady: (File) -> Unit, onFailed: (String) -> Unit) {
    val context = LocalContext.current
    val fetchLock = remember { Any() }
    var fetchStarted by remember { mutableStateOf(false) }
    val copy = source.copy

    fun startAuthorizedFetch(url: String, userAgent: String?) {
        synchronized(fetchLock) {
            if (fetchStarted) return
            if (!source.isAllowedDownload(url)) { onFailed(copy.unexpectedSite); return }
            fetchStarted = true
        }
        onDownloadStarted()
        Thread {
            try {
                val file = fetchLutPackArchive(context, source, url, userAgent, onProgress)
                if (file != null) onFileReady(file) else onFailed(copy.noFile)
            } catch (error: Exception) {
                onFailed(error.message ?: copy.downloadFailed)
            }
        }.start()
    }

    AndroidView(factory = { ctx ->
        CookieManager.getInstance().setAcceptCookie(true)
        WebView(ctx).apply {
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setBackgroundColor(android.graphics.Color.parseColor("#12100d"))
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.javaScriptCanOpenWindowsAutomatically = true
            settings.setSupportMultipleWindows(true)
            // The page may set session cookies, then redirect the archive to a storage host.
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            webChromeClient = object : WebChromeClient() {
                override fun onCreateWindow(view: WebView?, isDialog: Boolean, isUserGesture: Boolean,
                    resultMsg: android.os.Message?): Boolean {
                    // The accept button opens the archive in a new window: capture its URL with a
                    // transient web view and never show a popup page.
                    val transport = resultMsg?.obj as? WebView.WebViewTransport ?: return false
                    val popup = WebView(ctx).apply {
                        settings.javaScriptEnabled = true
                        webViewClient = object : WebViewClient() {
                            private fun capture(url: String?) {
                                val target = url?.takeIf { it.isNotBlank() && !it.startsWith("about:") } ?: return
                                if (source.isAllowedDownload(target)) startAuthorizedFetch(target, settings.userAgentString)
                            }
                            override fun shouldOverrideUrlLoading(v: WebView?, request: WebResourceRequest?): Boolean {
                                capture(request?.url?.toString())
                                return true
                            }
                            override fun onPageStarted(v: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                                capture(url)
                            }
                        }
                    }
                    transport.webView = popup
                    resultMsg.sendToTarget()
                    return true
                }
            }
            webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                    source.loadingScript?.let { view?.evaluateJavascript(it, null) }
                }
                override fun onPageFinished(view: WebView?, url: String?) {
                    source.loadingScript?.let { view?.evaluateJavascript(it, null) }
                    source.helperScript?.let { view?.evaluateJavascript(it, null) }
                }
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                    val target = request?.url ?: return false
                    val disposition = request.requestHeaders?.entries
                        ?.firstOrNull { it.key.equals("Content-Disposition", ignoreCase = true) }?.value?.lowercase()
                    val looksLikeFile = target.lastPathSegment?.endsWith(".zip", ignoreCase = true) == true ||
                        disposition?.contains("attachment") == true
                    if (looksLikeFile && source.isAllowedDownload(target.toString())) {
                        startAuthorizedFetch(target.toString(), settings.userAgentString)
                        return true
                    }
                    return false
                }
                override fun onReceivedError(view: WebView?, request: WebResourceRequest?,
                    error: android.webkit.WebResourceError?) {
                    if (request?.isForMainFrame != true || fetchStarted) return
                    onFailed(error?.description?.toString() ?: copy.pageFailed)
                }
            }
            // A direct download navigation instead of a new window.
            setDownloadListener(DownloadListener { url, userAgent, _, _, _ -> startAuthorizedFetch(url, userAgent) })
            loadUrl(source.pageUrl)
        }
    }, modifier = Modifier.fillMaxSize(), onRelease = { view -> view.destroy() })
}

/** The web cookies for [url], else the first of the source's origins that has a session. */
public fun lutPackCookies(source: MonitorLutPackSource, url: String,
    read: (String) -> String? = { CookieManager.getInstance().getCookie(it) }): String? =
    read(url)?.takeIf { it.isNotBlank() }
        ?: source.cookieOrigins.firstNotNullOfOrNull { origin -> read(origin)?.takeIf { it.isNotBlank() } }

/** Cookie-bound HTTPS fetch of the archive into the app cache; throws with the source's words. */
internal fun fetchLutPackArchive(context: Context, source: MonitorLutPackSource, url: String, userAgent: String?,
    onProgress: (Float) -> Unit): File? {
    val copy = source.copy
    val agent = userAgent?.takeIf { it.isNotBlank() }
        ?: "Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36"
    val connection = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
        instanceFollowRedirects = true
        connectTimeout = 30_000
        readTimeout = 120_000
        requestMethod = "GET"
        setRequestProperty("User-Agent", agent)
        lutPackCookies(source, url)?.let { setRequestProperty("Cookie", it) }
        setRequestProperty("Accept", "*/*")
        setRequestProperty("Referer", source.pageUrl)
    }
    try {
        connection.connect()
        val code = connection.responseCode
        if (code !in 200..299) throw IllegalStateException(copy.httpFailure(code))
        val total = connection.contentLengthLong.takeIf { it > 0 } ?: -1L
        val destination = File(context.cacheDir, source.archiveFileName)
        if (destination.exists()) destination.delete()
        connection.inputStream.use { input ->
            destination.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var written = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    written += read
                    if (total > 0) onProgress((written.toFloat() / total.toFloat()).coerceIn(0f, 1f))
                }
            }
        }
        onProgress(1f)
        if (destination.length() <= 0L) return null
        if (!destination.looksLikeZipArchive()) {
            val head = destination.inputStream().use { stream ->
                val peek = ByteArray(64)
                val n = stream.read(peek)
                if (n <= 0) "" else String(peek, 0, n, Charsets.ISO_8859_1)
            }
            destination.delete()
            if (head.trimStart().startsWith("<") || head.contains("html", ignoreCase = true)) {
                throw IllegalStateException(copy.webPageInsteadOfArchive)
            }
            throw IllegalStateException(copy.notAnArchive)
        }
        return destination
    } finally {
        connection.disconnect()
    }
}
