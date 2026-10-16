package com.opencapture.opencine.cameracontrols

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.opencapture.monitorui.monitorScrollFade

/** The four legal pages every app offers, in Settings and wherever privacy is linked. */
public enum class MonitorLegalPage(public val title: String) {
    PRIVACY("Privacy"), TERMS("Terms"), LICENSES("Licenses"), NOTICE("NOTICE"),
}

/** One legal page: text bundled with the app (readable offline) or a page opened in the browser. */
public sealed interface MonitorLegalDocument {
    /** [available] is false for a bundled page this build does not carry; [body] then says so. */
    public class Text @JvmOverloads constructor(
        public val body: String,
        public val available: Boolean = true,
    ) : MonitorLegalDocument
    public class Link(public val url: String) : MonitorLegalDocument

    public companion object {
        /** Shown, never an empty page, when a bundled legal file is missing from the build. */
        public const val UNAVAILABLE_TEXT: String =
            "This build does not include this document. It is in the project's source repository."

        /** The bundled files joined in order, or the unavailable page when any is missing or blank. */
        public fun bundledText(parts: List<String?>): Text {
            val texts = parts.map { it?.trim().orEmpty() }
            return if (texts.isEmpty() || texts.any { it.isEmpty() }) Text(UNAVAILABLE_TEXT, available = false)
            else Text(texts.joinToString("\n\n"))
        }

        /**
         * One legal file from the Java resources, staged by the owning module's Gradle build from
         * the repository file, or null when the build lacks it.
         */
        public fun resource(path: String): String? =
            MonitorLegalDocument::class.java.classLoader?.getResourceAsStream(path)
                ?.bufferedReader()?.use { it.readText() }
    }
}

/**
 * The platform's third-party notices every app ships: OpenCine's THIRD-PARTY-NOTICES.md and the
 * license texts of the fonts and icons the shared UI bundles, staged by camera-controls' Gradle
 * build from the same repository files the Swift twin bundles (MonitorUI `Resources`).
 */
public object MonitorPlatformLegalNotices {
    /** Resource paths in reading order. */
    public val PARTS: List<String> = listOf(
        "opencine/legal/THIRD-PARTY-NOTICES.md",
        "opencine/legal/Fonts/OFL-Sora.txt",
        "opencine/legal/Icons/lucide/LICENSE.txt",
        "opencine/legal/Icons/assist/LICENSE-Tabler.txt",
    )

    /** The joined notices, or the unavailable page when this build lacks any part. */
    public val document: MonitorLegalDocument.Text
        get() = MonitorLegalDocument.bundledText(PARTS.map(MonitorLegalDocument::resource))

    /** The joined text for a host's licenses page, or null when this build lacks any part. */
    public val text: String? get() = document.takeIf { it.available }?.body
}

/**
 * An app's legal set. Privacy and terms may be bundled text or web pages; license and attribution
 * text is always bundled, so it is reachable without a network.
 */
public class MonitorLegalDocuments(
    public val wordmark: String,
    public val privacy: MonitorLegalDocument,
    public val terms: MonitorLegalDocument,
    public val licenses: MonitorLegalDocument.Text,
    public val notice: MonitorLegalDocument.Text,
) {
    public operator fun get(page: MonitorLegalPage): MonitorLegalDocument = when (page) {
        MonitorLegalPage.PRIVACY -> privacy
        MonitorLegalPage.TERMS -> terms
        MonitorLegalPage.LICENSES -> licenses
        MonitorLegalPage.NOTICE -> notice
    }

    /**
     * Opens [page]: bundled text through [present] (the caller shows [MonitorLegalDocumentScreen]),
     * a web page in the browser. False when no app on the phone can open the page.
     */
    public fun open(page: MonitorLegalPage, context: Context, present: (MonitorLegalPage) -> Unit): Boolean =
        when (val document = get(page)) {
            is MonitorLegalDocument.Text -> { present(page); true }
            is MonitorLegalDocument.Link -> openMonitorLink(context, document.url)
        }
}

/** Opens [url] in the browser; false (never a throw) when nothing on the phone handles it. */
public fun openMonitorLink(context: Context, url: String): Boolean {
    val intent = Intent(Intent.ACTION_VIEW, url.toUri())
    if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    return runCatching { context.startActivity(intent) }.isSuccess
}

/** A bundled legal page over the whole window; Back and the close button dismiss it. */
@Composable
public fun MonitorLegalDocumentScreen(documents: MonitorLegalDocuments, page: MonitorLegalPage, onClose: () -> Unit) {
    val document = documents[page] as? MonitorLegalDocument.Text ?: return
    BackHandler(onBack = onClose)
    val shape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)
    Box(Modifier.fillMaxSize().background(LiveDesign.background).windowInsetsPadding(WindowInsets.safeDrawing)
        .testTag("legal.document.${page.name.lowercase()}")) {
        Column(Modifier.fillMaxSize().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 12.dp)) {
            Column(Modifier.padding(start = 45.dp)) {
                Text(documents.wordmark, style = LiveType.ui(9.5f, FontWeight.Bold).copy(letterSpacing = 0.8.sp),
                    color = LiveDesign.accent)
                Text(page.title, style = LiveType.ui(24f, FontWeight.SemiBold), color = LiveDesign.text)
            }
            Spacer(Modifier.height(12.dp))
            val scroll = rememberScrollState()
            Text(document.body, style = LiveType.ui(14f).copy(lineHeight = 19.sp), color = LiveDesign.text,
                modifier = Modifier.fillMaxWidth().weight(1f).monitorScrollFade(scroll).verticalScroll(scroll)
                    .background(LiveDesign.surface, shape).border(1.dp, LiveDesign.hairline, shape).padding(16.dp))
        }
        MediaCloseButton(onClick = onClose, modifier = Modifier.align(Alignment.TopStart).padding(start = 16.dp, top = 16.dp))
    }
}
