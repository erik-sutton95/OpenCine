package com.opencapture.opencine.appkit.diagnostics

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import com.opencapture.opencine.appkit.DiscoveryPermissions
import com.opencapture.opencine.appkit.MediaShare
import com.opencapture.opencine.media.BoundedDiagnosticFormatter
import com.opencapture.opencine.media.DecoderErrorRecord
import com.opencapture.opencine.media.DiagnosticJournal
import com.opencapture.opencine.media.PrivacyRedactor
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** The camera a diagnostic report describes. Unknown is `"none"`. */
public data class DiagnosticCamera(public val family: String, public val model: String, public val phase: String)

/**
 * On-device journal, exceptions, and a shareable report the camera apps share. Optional uploads
 * belong to [ReliabilityReporting]. Person name, location, device name, and Wi-Fi passwords are
 * stripped with the host's redaction policy.
 *
 * Each app keeps one `object DiagnosticCenter` that extends this with its [DiagnosticsHost], its
 * incident runtime, its camera access-point policy and how it reads its session `S`. The app's own
 * install steps (log sinks, reporting install) go in [installHost].
 */
public abstract class DiagnosticCenterRuntime<S>(
    private val host: DiagnosticsHost,
    private val incidents: FeedIncidentRuntime,
    /** A camera access point name the report may keep readable. */
    private val isSafeNetwork: (String) -> Boolean,
    /** Whether a VPN is active, which the report notes because it can block the camera link. */
    private val vpnActive: (Context) -> Boolean,
    private val camera: (S) -> DiagnosticCamera,
) {
    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    @Volatile private var appContext: Context? = null
    @Volatile public var onCopiedForFeedback: (() -> Unit)? = null
    public val journal: DiagnosticJournal = DiagnosticJournal(JOURNAL_CAP)
    public val exceptionJournal: DiagnosticJournal = DiagnosticJournal(EXCEPTION_CAP)
    private val journalWritten = AtomicInteger(0)
    private val exceptionWritten = AtomicInteger(0)
    private val sharing = AtomicBoolean(false)

    /** The app's install steps, after the journals and incident store are ready. */
    protected abstract fun installHost(context: Context)

    public fun install(context: Context) {
        appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            recordFault("uncaught", error.stackTraceToString())
            previous?.uncaughtException(thread, error)
        }
        journal.startWriter { batch -> persistBatch(journalFile(), batch, JOURNAL_CAP, journalWritten, journal) }
        exceptionJournal.startWriter { batch ->
            persistBatch(exceptionFile(), batch, EXCEPTION_CAP, exceptionWritten, exceptionJournal)
        }
        filesDir()?.let { incidents.install(it) }
        installHost(context)
        log("notice", "diagnostics", "boot", "diagnostics installed")
    }

    public fun boundedDiagnosticText(
        session: S,
        maxBytes: Int = ManualProblemReport.ATTACHMENT_MAX_BYTES,
        maxChars: Int = ManualProblemReport.ATTACHMENT_MAX_CHARS,
    ): String {
        val env = environment(session)
        val body =
            BoundedDiagnosticFormatter.format(
                environment =
                    BoundedDiagnosticFormatter.Environment(
                        product = host.product,
                        appVersion = env.appVersion,
                        appBuild = env.appBuild,
                        osName = env.osName,
                        osVersion = env.osVersion,
                        deviceModel = env.deviceModel,
                        cameraFamily = env.cameraFamily,
                        cameraModel = env.cameraModel,
                        phase = env.phase,
                        vpnActive = env.vpnActive,
                        radio = env.radio,
                    ),
                journal = journalLines(),
                exceptions = exceptionLines(),
                extras = incidents.reportExtras(),
                cap = minOf(maxChars, BoundedDiagnosticFormatter.CHARACTER_CAP),
                isSafeNetwork = isSafeNetwork,
            )
        return ManualProblemReportEnvelope.utf8Prefix(body, maxBytes)
    }

    public fun log(level: String, category: String, code: String, message: String) {
        val line = host.redact("$level $category $code $message")
        when (level) {
            "error", "fault" -> Log.e(TAG, line)
            "warning" -> Log.w(TAG, line)
            else -> Log.i(TAG, line)
        }
        if (level != "debug") journal.append(line)
        if (level == "error" || level == "fault") exceptionJournal.append(line)
    }

    /** Journal line for a decoder error the shared `HevcDecoder` reports. */
    public fun logDecoderError(record: DecoderErrorRecord): Unit =
        log("warning", "decoder", record.origin.wire, record.journalLine())

    public fun recordFault(code: String, stack: String) {
        log("fault", "diagnostics", code, host.redact(stack.take(4000)))
    }

    public fun writeReport(context: Context, session: S): File? {
        val env = environment(session)
        val journal = journalLines()
        val exceptions = exceptionLines()
        return writeShareFiles(context, env, journal, exceptions, incidents.exportExtras())
            .firstOrNull { it.name == "report.txt" }
    }

    public fun shareReport(context: Context, session: S, emailSupport: Boolean = false, copyForFeedback: Boolean = true) {
        if (!sharing.compareAndSet(false, true)) {
            android.widget.Toast.makeText(context, "Preparing the report…", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        if (!emailSupport && copyForFeedback) copyCompact(context, session)
        val app = context.applicationContext
        val env = environment(session)
        val journal = journalLines()
        val exceptions = exceptionLines()
        Thread(
            {
                try {
                    val extras = incidents.exportExtras()
                    val files = writeShareFiles(app, env, journal, exceptions, extras)
                    Handler(Looper.getMainLooper()).post { launchShare(app, files, emailSupport) }
                } catch (_: Exception) {
                    Handler(Looper.getMainLooper()).post {
                        android.widget.Toast.makeText(app,
                            "Couldn't prepare the report. Please try again or email ${host.supportEmail}.",
                            android.widget.Toast.LENGTH_LONG).show()
                    }
                } finally {
                    sharing.set(false)
                }
            },
            "opc.diag.share",
        ).apply { isDaemon = true; start() }
    }

    private fun writeShareFiles(
        context: Context,
        env: Env,
        journal: List<String>,
        exceptions: List<String>,
        extras: List<Pair<String, String>>,
    ): List<File> {
        val dir = File(context.cacheDir, "diagnostics").apply { mkdirs() }
        dir.listFiles()?.filter { it.name.startsWith("incident-") || it.name == "incidents.txt" }?.forEach { it.delete() }
        val report = File(dir, "report.txt")
        var body = fullReport(env, journal, exceptions, extras)
        if (body.length > SHARE_MAX_BYTES) {
            body = fullReport(env, emptyList(), exceptions, extras)
        }
        if (body.length > SHARE_MAX_BYTES) {
            body = body.take(SHARE_MAX_BYTES.toInt())
        }
        report.writeText(body)
        val files = mutableListOf(report)
        var bytes = report.length()
        for ((name, body) in extras) {
            if (bytes >= SHARE_MAX_BYTES) break
            val safe = name.filter { it.isLetterOrDigit() || it == '-' || it == '.' }
            if (safe.isEmpty() || safe == "report.txt") continue
            val remaining = SHARE_MAX_BYTES - bytes
            if (body.length.toLong() > remaining) break
            val file = File(dir, safe)
            file.writeText(body)
            bytes += file.length()
            files += file
        }
        log("notice", "diagnostics", "report", "wrote diagnostic report attachments=${files.size}")
        return files
    }

    private fun launchShare(context: Context, files: List<File>, emailSupport: Boolean = false) {
        if (files.isEmpty()) {
            android.widget.Toast.makeText(context, "Couldn't prepare a diagnostic report. Please try again.",
                android.widget.Toast.LENGTH_LONG).show()
            return
        }
        val uris = ArrayList<Uri>()
        for (file in files) {
            val uri =
                runCatching {
                    FileProvider.getUriForFile(context, MediaShare.authority(context), file)
                }.getOrNull() ?: continue
            uris.add(uri)
        }
        if (uris.isEmpty()) {
            android.widget.Toast.makeText(context, "Couldn't attach the diagnostic report. Please try again.",
                android.widget.Toast.LENGTH_LONG).show()
            return
        }
        val clip = ClipData.newRawUri("${host.product} diagnostics", uris[0])
        for (i in 1 until uris.size) clip.addItem(ClipData.Item(uris[i]))
        val intent =
            if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    clipData = clip
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                    putExtra(Intent.EXTRA_TEXT, lastCompact)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "text/plain"
                    clipData = clip
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    putExtra(Intent.EXTRA_TEXT, lastCompact)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
        if (emailSupport) {
            intent.selector = Intent(Intent.ACTION_SENDTO, "mailto:".toUri())
            intent.putExtra(Intent.EXTRA_EMAIL, arrayOf(host.supportEmail))
            intent.putExtra(Intent.EXTRA_SUBJECT, supportSubject(host.product))
            intent.putExtra(Intent.EXTRA_TEXT,
                "What happened?\n\n\nTechnical details are attached to help us investigate. Please do not include private footage or passwords.")
        }
        val chooser = Intent.createChooser(intent, if (emailSupport) "Email support" else null)
        if (context !is android.app.Activity) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(chooser)
        } catch (_: android.content.ActivityNotFoundException) {
            android.widget.Toast.makeText(context,
                "Email ${host.supportEmail}. No compatible app is available.",
                android.widget.Toast.LENGTH_LONG).show()
        }
    }

    @Volatile public var lastCompact: String = ""
        private set

    public fun copyCompact(context: Context, session: S) {
        val text = compactSummary(environment(session), journalLines())
        lastCompact = text
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("${host.product} diagnostics", text))
        log("notice", "diagnostics", "feedback-paste", "copied compact diagnostics")
        onCopiedForFeedback?.invoke()
    }

    private fun environment(session: S): Env {
        val camera = camera(session)
        val vpn = appContext?.let { vpnActive(it) } ?: false
        return Env(
            appVersion = host.versionName,
            appBuild = host.versionCode.toString(),
            sourceRevision = host.sourceRevision,
            osName = "Android",
            osVersion = Build.VERSION.RELEASE ?: "?",
            deviceModel = Build.MODEL ?: "unknown",
            cameraFamily = camera.family,
            cameraModel = camera.model,
            phase = camera.phase,
            vpnActive = vpn,
            radio = appContext?.let { runCatching { DiscoveryPermissions.reportLines(it) }.getOrNull() }.orEmpty(),
        )
    }

    private fun compactSummary(env: Env, recent: List<String>): String =
        compactSummary(host, env, recent)

    private fun fullReport(
        env: Env,
        journal: List<String>,
        exceptions: List<String>,
        extras: List<Pair<String, String>> = emptyList(),
    ): String = fullReport(host, env, journal, exceptions, extras)

    private fun filesDir(): File? {
        val ctx = appContext ?: return null
        return File(ctx.filesDir, "diagnostics").apply { mkdirs() }
    }

    private fun journalFile(): File? = filesDir()?.let { File(it, "control-live.log") }

    private fun exceptionFile(): File? = filesDir()?.let { File(it, "exceptions.log") }

    private fun journalLines(): List<String> = journal.snapshot()

    private fun exceptionLines(): List<String> = exceptionJournal.snapshot()

    private fun persistBatch(
        file: File?,
        batch: List<String>,
        cap: Int,
        written: AtomicInteger,
        source: DiagnosticJournal,
    ) {
        if (file == null || batch.isEmpty()) return
        runCatching {
            val stamped = batch.joinToString("") { "${iso.format(Date())} $it\n" }
            file.appendText(stamped)
            val count = written.addAndGet(batch.size)
            if (count >= cap * 2) {
                val keep = source.snapshot()
                file.writeText(keep.joinToString("\n") + "\n")
                written.set(keep.size)
            }
        }
    }

    internal data class Env(
        val appVersion: String,
        val appBuild: String,
        val sourceRevision: String,
        val osName: String,
        val osVersion: String,
        val deviceModel: String,
        val cameraFamily: String,
        val cameraModel: String,
        val phase: String,
        val vpnActive: Boolean,
        val radio: List<String>,
    )

    public companion object {
        private const val TAG = "opc.diagnostics"
        public const val JOURNAL_CAP: Int = 2500
        public const val EXCEPTION_CAP: Int = 200
        private const val SHARE_MAX_BYTES = 2_097_152L

        /** The support email subject: the product, a colon, "report a problem". */
        internal fun supportSubject(product: String): String = "$product: report a problem"

        internal fun compactSummary(host: DiagnosticsHost, env: Env, recent: List<String>): String {
            val lines =
                mutableListOf(
                    "${host.product} diagnostics (no name, no location)",
                    "app ${env.appVersion} (${env.appBuild}) source=${env.sourceRevision} ${env.osName} ${env.osVersion} ${env.deviceModel}",
                    "camera ${env.cameraModel} family=${env.cameraFamily} phase=${env.phase} vpn=${if (env.vpnActive) "on" else "off"}",
                )
            if (env.radio.isNotEmpty()) lines += env.radio.joinToString(" · ")
            val tail = recent.takeLast(12)
            if (tail.isNotEmpty()) {
                lines += "recent:"
                lines += tail
            }
            return PrivacyRedactor.clampCompact(host.redact(lines.joinToString("\n")))
        }

        internal fun fullReport(
            host: DiagnosticsHost,
            env: Env,
            journal: List<String>,
            exceptions: List<String>,
            extras: List<Pair<String, String>> = emptyList(),
        ): String {
            val sections = mutableListOf<String>()
            sections +=
                """
                ${host.product} diagnostic report
                Privacy: no personal name, email, location, device name, or Wi-Fi password.
                Generated for a tester to paste or share. Not uploaded.

                app: ${env.appVersion} (${env.appBuild})
                source: ${env.sourceRevision}
                os: ${env.osName} ${env.osVersion}
                device: ${env.deviceModel}
                camera: ${env.cameraModel}
                family: ${env.cameraFamily}
                phase: ${env.phase}
                vpn: ${if (env.vpnActive) "on" else "off"}
                """.trimIndent() + env.radio.joinToString("") { "\n$it" }
            if (exceptions.isNotEmpty()) {
                sections += "Exceptions / faults\n" + exceptions.takeLast(EXCEPTION_CAP).joinToString("\n")
            }
            for ((name, body) in extras) {
                if (body.isNotBlank()) sections += "$name\n$body"
            }
            if (journal.isNotEmpty()) {
                sections +=
                    "Journal (last ${minOf(journal.size, JOURNAL_CAP)} lines)\n" +
                        journal.takeLast(JOURNAL_CAP).joinToString("\n")
            }
            return host.redact(sections.joinToString("\n\n"))
        }
    }
}
