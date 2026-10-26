package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.background
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.key
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.*
import com.opencapture.monitorui.settings.*
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.MonitorSettingsCacheSource
import com.opencapture.opencine.appkit.MonitorSettingsAccountActions
import com.opencapture.opencine.appkit.MonitorSettingsAccountModel
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.appkit.diagnostics.FeedIncidentRuntime
import com.opencapture.opencine.appkit.MonitorRemoteShutter
import com.opencapture.opencine.core.RouteKind
import android.widget.Toast
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import com.opencapture.opencine.cameracontrols.gyro.GyroCopy

/** Captured account actions use the existing native authorization and route service. */
public class MonitorSettingsAccountSource(
    public val model: MonitorSettingsAccountModel, public val actions: MonitorSettingsAccountActions,
    public val identity: Any,
    public val title: String, public val help: String, public val state: MonitorAccountState,
    public val status: String, public val signInTitle: String, public val signOutTitle: String,
    public val busyTitle: String, public val failure: String?,
    public val consentTitle: String, public val consentMessage: String,
    public val consentAction: String, public val cancelTitle: String,
    public val refresh: () -> Unit,
)

/** The deployed display store supplies values and actions; the common page owns its form. */
@Deprecated("Compose an explicit typed display source when migrating the shared settings.")
public class MonitorOperatorBorrowedDisplay(
    public val layoutTitle: String,
    public val layoutHelp: String,
    public val choices: List<MonitorDisplayChoice>,
    public val selection: String,
    public val onSelect: (String) -> Unit,
    public val expandedSection: String?,
    public val onExpand: (String?) -> Unit,
    public val sections: List<MonitorDisplaySection>,
    public val order: MonitorDisplayOrderGroup,
    public val returnedFromEditor: () -> Unit = {},
)

/** Display rows over the one display owner: the modes the source declares, each mode's chrome, the clean-view
 * pins and, when a live monitor can host it, the Edit view. [available] is what the source can fill. */
public class MonitorOperatorDisplaySource(
    public val session: com.opencapture.opencine.appkit.MonitorOperatorSessionModel,
    public val available: Set<com.opencapture.opencine.appkit.MonitorDisplaySection>,
    public val edit: ((com.opencapture.opencine.appkit.MonitorDisplayMode) -> Unit)?,
)

/** An actual setting descriptor, including its observed selection and admitted write. */
public class MonitorSettingsChoiceSource(
    public val title: String, public val help: String?,
    public val choices: List<MonitorDisplayChoice>, public val selection: String?,
    public val select: (String) -> Unit, public val segmented: Boolean = false,
)
public data class MonitorSettingsReadoutSource(public val title: String, public val help: String?, public val value: String?)
public class MonitorSettingsLinkSource(
    public val transport: String, public val transportHelp: String, public val phase: String,
    public val phaseHelp: String, public val healthTitle: String, public val healthCaption: String,
    /** Unknown (no live path) draws the empty scale, as before any picture arrives. */
    public val score: Int?, public val choices: List<MonitorSettingsChoiceSource> = emptyList(),
    public val controlHolder: MonitorSettingsReadoutSource? = null,
    public val processingTitle: String? = null,
    public val processing: List<MonitorSettingsReadoutSource> = emptyList(),
    /** Processing the app offers on this phone (the feed upscaler), shown above [processing] readouts. */
    public val processingChoices: List<MonitorSettingsChoiceSource> = emptyList(),
    public val network: String? = null, public val networkHelp: String = "",
    /** The saved setups, or null where the app keeps none. */
    public val savedCameras: List<MonitorSavedCameraSummary>? = null,
    public val savedCamerasHelp: String = "",
)
public class MonitorSettingsSharingSource(
    public val watching: MonitorSettingsReadoutSource? = null,
    public val sharingTitle: String, public val sharingHelp: String,
    public val sharing: Boolean?, public val setSharing: ((Boolean) -> Unit)?,
    public val unavailable: String, public val failure: String? = null,
    public val watcherCount: MonitorSettingsReadoutSource? = null,
    public val priority: MonitorSettingsChoiceSource,
    public val passcodeTitle: String, public val passcodeHelp: String,
    public val passcode: String, public val setPasscode: (String) -> Unit,
    public val controlRequestsTitle: String, public val controlRequestsHelp: String,
    public val controlRequests: Boolean, public val setControlRequests: (Boolean) -> Unit,
    public val pending: MonitorSettingsReadoutSource? = null,
    public val declineTitle: String, public val decline: (() -> Unit)? = null,
    public val grantTitle: String, public val grant: (() -> Unit)? = null,
    public val holder: MonitorSettingsReadoutSource? = null,
    public val takeBackTitle: String, public val takeBack: (() -> Unit)? = null,
)
/** The on-screen joystick of a camera with a gimbal (Swift `MonitorSettingsJoystickSource`). */
public class MonitorSettingsJoystickSource(
    public val size: MonitorMotionChoiceSetting, public val invertPan: MonitorMotionToggleSetting,
    public val invertTilt: MonitorMotionToggleSetting, public val deadZone: MonitorMotionIntegerSetting,
    public val response: MonitorMotionChoiceSetting, public val identifier: String = "monitor.joystick",
)
/** Motion control rows, present only where the camera reports motion (Swift `MonitorSettingsMotionSource`). */
public class MonitorSettingsMotionSource(
    public val sensitivity: MonitorMotionIntegerSetting? = null,
    public val joystick: MonitorSettingsJoystickSource? = null,
    public val controller: MonitorMotionChoiceSetting? = null,
    public val controllerStatus: String = "Not connected", public val controllerHelp: String = "",
)
/** The remote shutter row: the host's stored choice with its title and caption (A2-32). */
public class MonitorSettingsRemoteShutter(
    public val enabled: Boolean, public val setEnabled: (Boolean) -> Unit,
    public val title: String = "Remote shutter", public val caption: String? = null,
) {
    public companion object {
        /** The media-button shutter [com.opencapture.opencine.appkit.MonitorRemoteShutter] runs, over the host's stored choice. */
        public fun mediaButtons(enabled: Boolean, setEnabled: (Boolean) -> Unit): MonitorSettingsRemoteShutter =
            MonitorSettingsRemoteShutter(enabled, setEnabled, MonitorRemoteShutter.TITLE, MonitorRemoteShutter.CAPTION)
    }
}

/** The auto-rotate row, for a source that reports the camera body's orientation (A2-32). */
public class MonitorSettingsAutoRotate(
    public val enabled: Boolean, public val setEnabled: (Boolean) -> Unit,
    public val title: String = "Auto-Rotate Feed", public val help: String = "",
)

/**
 * Controls tab. The remote shutter ([shutter]) and auto-rotate ([autoRotate]) are separate
 * optional capabilities (Swift `MonitorSettingsInputSource`); the flat `autoRotateFeed` pair
 * remains for hosts that have not moved to [autoRotate].
 */
public class MonitorSettingsControlsSource(
    public val recordConfirmation: Boolean, public val setRecordConfirmation: (Boolean) -> Unit,
    public val haptics: Boolean, public val setHaptics: (Boolean) -> Unit,
    public val keepAwake: Boolean, public val setKeepAwake: (Boolean) -> Unit,
    public val keepAwakeHelp: String,
    public val autoRotateFeed: Boolean? = null, public val setAutoRotateFeed: ((Boolean) -> Unit)? = null,
    public val rotationTitle: String = "Auto-Rotate Feed", public val rotationHelp: String = "",
    public val hapticsHelp: String? = null,
    public val motion: MonitorSettingsMotionSource? = null,
    public val shutter: MonitorSettingsRemoteShutter? = null,
    public val autoRotate: MonitorSettingsAutoRotate? = null,
) {
    /** The declared auto-rotate, else the flat pair, else none. */
    public val autoRotateRow: MonitorSettingsAutoRotate?
        get() = autoRotate ?: autoRotateFeed?.let { value ->
            setAutoRotateFeed?.let { MonitorSettingsAutoRotate(value, it, rotationTitle, rotationHelp) }
        }
}
/** Cache IO and copy. Clearing always asks first: one confirmation policy for every app. */
public class MonitorSettingsCachePresentation(
    public val source: MonitorSettingsCacheSource,
    public val formatBytes: ((Long) -> String)? = null,
    public val checking: String = "Checking…", public val readFailure: String = "Could not read the cache.",
    public val clearFailure: String = "Could not clear the cache. Try again.",
    public val scopeHelp: String = "Originals and playback proxies downloaded from the camera.",
    public val clearHelp: String = "Remove downloaded picture files while keeping the clip list.",
    public val summaryColor: Color = MonitorPalette.accent,
    public val cacheOriginals: Boolean? = null, public val setCacheOriginals: ((Boolean) -> Unit)? = null,
    public val cacheHelp: String = "Keep originals downloaded for playback.",
)
/** Help & Feedback. Privacy and terms come from [MonitorOperatorSettingsConfiguration.legal]. */
public class MonitorSettingsSupportSource(
    public val report: () -> Unit,
    public val automaticReports: Boolean? = null, public val available: Boolean = false,
    public val automaticHelp: String = "", public val unavailableHelp: String = "",
    public val setAutomaticReports: ((Boolean) -> Unit)? = null,
    public val reportTitle: String = "Report a problem",
    public val reportHelp: String = "Tell us what happened in the app. Choose whether to include technical details and an email for a reply.",
    public val reportActionTitle: String = "Open",
    public val status: MonitorReportStatus? = null, public val discard: (() -> Unit)? = null,
    public val actions: List<MonitorSupportAction> = emptyList(),
    public val sourceUrl: String? = null,
    public val sourceHelp: String = "", public val termsHelp: String = "",
    internal val legacyPrivacy: (() -> Unit)? = null,
    internal val legacySource: (() -> Unit)? = null,
    internal val legacyTerms: (() -> Unit)? = null,
) {
    /** Published callback values, retained for legacy readers. Current actions remain owned by legal/source URLs. */
    public val privacy: () -> Unit get() = legacyPrivacy ?: {}
    public val source: () -> Unit get() = legacySource ?: {}
    public val terms: () -> Unit get() = legacyTerms ?: {}

    public constructor(
        automaticReports: Boolean?, available: Boolean, automaticHelp: String, unavailableHelp: String,
        setAutomaticReports: ((Boolean) -> Unit)?, reportTitle: String, reportHelp: String,
        reportActionTitle: String, report: () -> Unit, privacy: () -> Unit,
        status: MonitorReportStatus?, discard: (() -> Unit)?, actions: List<MonitorSupportAction>,
        sourceHelp: String, termsHelp: String, source: () -> Unit, terms: () -> Unit,
    ) : this(report, automaticReports, available, automaticHelp, unavailableHelp,
        setAutomaticReports, reportTitle, reportHelp, reportActionTitle, status, discard,
        actions, sourceHelp = sourceHelp, termsHelp = termsHelp,
        legacyPrivacy = privacy, legacySource = source, legacyTerms = terms)
}
/** Saved feed reports on this phone: share a diagnostic report, delete the stored feed reports. */
public class MonitorSettingsDiagnosticsSource(
    public val save: () -> Unit,
    public val incidents: FeedIncidentRuntime,
    public val deleteHelp: String = "Remove saved feed reports from this phone. Connection logs remain. Turn off automatic reporting to clear pending uploads. Reports already sent cannot be removed here.",
)
public data class MonitorSettingsInformationSource(
    public val theme: String, public val protocolName: String, public val version: String,
    public val themeHelp: String, public val protocolHelp: String, public val versionHelp: String,
)
/**
 * Optional phone motion controls; capture and storage remain host-owned. [calibrate] opens the ring
 * calibration and adds the "Calibrate phone mount" row; null (no camera that can calibrate) hides it.
 */
public class MonitorSettingsGyroSource(
    public val enabled: Boolean, public val setEnabled: (Boolean) -> Unit,
    public val status: String, public val available: Boolean = true,
    public val openLogs: () -> Unit,
    public val calibrate: (() -> Unit)? = null,
) {
    /** The old mount preset's name; mount presets are gone. */
    @Deprecated("Mount presets are gone; pass calibrate")
    public var mountName: String? = null
        private set

    /** The old mount preset picker; mount presets are gone. */
    @Deprecated("Mount presets are gone; pass calibrate")
    public var configureMount: (() -> Unit)? = null
        private set

    /** The source with the old mount preset row, kept for existing callers until a later minor release. */
    @Deprecated("Mount presets are gone; pass calibrate")
    @Suppress("DEPRECATION")
    public constructor(
        enabled: Boolean, setEnabled: (Boolean) -> Unit,
        status: String, available: Boolean = true,
        openLogs: () -> Unit,
        mountName: String?,
        configureMount: (() -> Unit)? = null,
        calibrate: (() -> Unit)? = null,
    ) : this(enabled, setEnabled, status, available, openLogs, calibrate) {
        this.mountName = mountName
        this.configureMount = configureMount
    }
}

/** The rows of the settings gyro card, in order. */
internal enum class MonitorSettingsGyroRow {
    /** The logging toggle. */
    LOGGING,
    /** The capture status line. */
    STATUS,
    /** The deprecated mount preset row, only for a caller that still passes one. */
    MOUNT,
    /** Opens the ring calibration, only when the host can calibrate. */
    CALIBRATE,
}

/** The gyro card's rows for [source]: the calibrate row only when the host passes [MonitorSettingsGyroSource.calibrate]. */
@Suppress("DEPRECATION")
internal fun monitorSettingsGyroRows(source: MonitorSettingsGyroSource): List<MonitorSettingsGyroRow> = buildList {
    add(MonitorSettingsGyroRow.LOGGING)
    add(MonitorSettingsGyroRow.STATUS)
    if (source.configureMount != null) add(MonitorSettingsGyroRow.MOUNT)
    if (source.calibrate != null) add(MonitorSettingsGyroRow.CALIBRATE)
}
/**
 * Every app's settings: one value per tab, built by the app from its model. Absent capability
 * sections (motion, sharing, account, cache) are null; the recipe for each tab is the same.
 * [monitorSettingsTabs] leaves out a tab whose whole domain is absent (Swift's tab rule).
 */
public class MonitorOperatorSettingsConfiguration(
    public val brand: String, public val isLive: Boolean, public val phase: String,
    public val close: () -> Unit, public val disconnect: (() -> Unit)?, public val feedback: () -> Unit,
    public val link: MonitorSettingsLinkSource, public val sharing: MonitorSettingsSharingSource?,
    public val sharingSubtitle: String?, public val sharingRail: String?,
    public val controls: MonitorSettingsControlsSource,
    public val cache: MonitorSettingsCachePresentation?,
    public val account: MonitorSettingsAccountSource? = null,
    /** An account the app names but cannot configure yet; shown as not configured. */
    public val unconfiguredAccount: MonitorSettingsReadoutSource? = null,
    public val support: MonitorSettingsSupportSource,
    public val diagnostics: MonitorSettingsDiagnosticsSource? = null,
    public val legal: MonitorLegalDocuments? = null,
    public val information: MonitorSettingsInformationSource? = null,
    /** By default a tab with nothing in it is left out (iOS hides an empty Sharing tab too). */
    tabs: List<MonitorSettingsTab>? = null,
    /** Legacy captured cards remain available beside typed assist composition. */
    public val assistSections: List<MonitorAssistSettingsSection> = emptyList(),
    public val assist: MonitorOperatorAssistSettingsSource? = null,
    public val gyro: MonitorSettingsGyroSource? = null,
) {
    /** Explicit tab lists keep their order; the default includes each supplied optional domain. */
    public val tabs: List<MonitorSettingsTab> = tabs ?: monitorSettingsTabs(sharing, cache, account, unconfiguredAccount, gyro)
    /** Published positional list constructor; every current capability field keeps its default. */
    @Deprecated("Compose an explicit typed assist source when migrating the shared settings.")
    public constructor(
        brand: String, isLive: Boolean, phase: String,
        close: () -> Unit, disconnect: (() -> Unit)?, feedback: () -> Unit,
        link: MonitorSettingsLinkSource, sharing: MonitorSettingsSharingSource?,
        sharingSubtitle: String?, sharingRail: String?,
        assistSections: List<MonitorAssistSettingsSection>, controls: MonitorSettingsControlsSource,
        cache: MonitorSettingsCachePresentation?, account: MonitorSettingsAccountSource? = null,
        support: MonitorSettingsSupportSource, information: MonitorSettingsInformationSource?,
    ) : this(brand, isLive, phase, close, disconnect, feedback, link, sharing, sharingSubtitle,
        sharingRail, controls, cache, account, support = support, information = information,
        assistSections = assistSections)
}

/** Stable tab order with Sharing only for a sharing domain and Storage only for a cache or account. */
public fun monitorSettingsTabs(
    sharing: MonitorSettingsSharingSource?, cache: MonitorSettingsCachePresentation?,
    account: MonitorSettingsAccountSource?, unconfiguredAccount: MonitorSettingsReadoutSource? = null,
    gyro: MonitorSettingsGyroSource? = null,
): List<MonitorSettingsTab> = MonitorSettingsTab.entries.filter {
    when (it) {
        MonitorSettingsTab.SHARING -> sharing != null
        MonitorSettingsTab.STORAGE -> gyro != null || cache != null || account != null || unconfiguredAccount != null
        else -> true
    }
}

/** Complete settings ownership using actual stores, optional services and bounded native leaves. */
@Composable
public fun MonitorOperatorSettingsScreen(
    configuration: MonitorOperatorSettingsConfiguration,
    assistSections: List<MonitorAssistSettingsSection>,
    display: MonitorOperatorDisplaySource,
    initialTab: MonitorSettingsTab = MonitorSettingsTab.LINK,
    sourceIdentity: Any? = null,
): Unit {
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(configuration, selectedTab, { selectedTab = it },
        MonitorOperatorPictureSettings.Configured(assistSections, display), sourceIdentity))
}

/**
 * Settings over the one display owner (A2-84): the page opens on [session]'s last tab and restores
 * each tab's scroll offset, the twin of Swift's configured `MonitorOperatorSettingsScreen`.
 */
@Composable
public fun MonitorOperatorSettingsScreen(
    configuration: MonitorOperatorSettingsConfiguration,
    assistSections: List<MonitorAssistSettingsSection>,
    display: MonitorOperatorDisplaySource,
    session: MonitorOperatorSessionModel,
    sourceIdentity: Any? = null,
): Unit {
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(configuration, session.settingsTab, { session.settingsTab = it },
        MonitorOperatorPictureSettings.Configured(assistSections, display), sourceIdentity,
        scrollOffsets = session.settingsScrollOffsets, onScroll = session::noteSettingsScroll))
}

/** Shared typed composition through the current settings and legal owners. */
@Composable
public fun MonitorOperatorSettingsScreen(
    configuration: MonitorOperatorSettingsConfiguration,
    display: MonitorOperatorDisplaySource,
    initialTab: MonitorSettingsTab = MonitorSettingsTab.LINK,
    sourceIdentity: Any? = null,
): Unit {
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(configuration, selectedTab, { selectedTab = it },
        MonitorOperatorPictureSettings.Configured(configuration.assistSections, display, assist = configuration.assist),
        sourceIdentity))
}

/** Published borrowed values and callbacks rendered by the current settings owner. */
@Deprecated("Compose an explicit typed display source when migrating the shared settings.")
@Composable
public fun MonitorOperatorSettingsScreen(
    configuration: MonitorOperatorSettingsConfiguration,
    borrowedDisplay: MonitorOperatorBorrowedDisplay,
    initialTab: MonitorSettingsTab = MonitorSettingsTab.LINK,
    sourceIdentity: Any? = null,
): Unit {
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(configuration, selectedTab, { selectedTab = it },
        MonitorOperatorPictureSettings.Configured(configuration.assistSections, null, borrowedDisplay, configuration.assist),
        sourceIdentity))
}

/** Settings summaries of the saved setups: name, model and the camera's own network where it has one. */
public fun monitorSavedCameraSummaries(saved: List<SavedCamera>): List<MonitorSavedCameraSummary> =
    saved.map { camera ->
        val network = camera.routes.firstOrNull { it.kind == RouteKind.CAMERA_ACCESS_POINT }?.network
        MonitorSavedCameraSummary(camera.id, camera.displayName, camera.model + (network?.let { " · $it" } ?: ""), network)
    }

@Composable
internal fun SettingsAccount(source: MonitorSettingsAccountSource) {
    val model = source.model
    val operation by model.state.collectAsState()
    androidx.compose.runtime.SideEffect { model.bind(source.actions) }
    LaunchedEffect(source.identity) { source.refresh() }
    MonitorAccountSettings(source.title, source.help, source.state, model::requestSignIn, model::signOut,
        statusLabel = source.status, signInTitle = source.signInTitle, signOutTitle = source.signOutTitle,
        busyLabel = source.busyTitle.takeIf { operation.busy },
        errorMessage = source.failure ?: operation.failure, pillActions = true)
    if (operation.confirmationPresented) AlertDialog(onDismissRequest = model::cancelConfirmation,
        title = { Text(source.consentTitle) }, text = { Text(source.consentMessage) },
        confirmButton = { TextButton(onClick = model::confirmSignIn) { Text(source.consentAction) } },
        dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(source.cancelTitle) } })
}

@Composable
private fun SettingsChoice(source: MonitorSettingsChoiceSource) {
    MonitorSettingsInlineRow(source.title, source.help) {
        if (source.segmented) MonitorSettingsSegmented(source.choices.map { it.title },
            source.choices.firstOrNull { it.id == source.selection }?.title ?: "--") { title ->
            source.choices.firstOrNull { it.title == title }?.let { source.select(it.id) }
        } else MonitorSettingsChoices(source.choices.map { it.id }, source.selection ?: "--",
            compact = false, title = { id -> source.choices.first { it.id == id }.title }, onSelect = source.select)
    }
}
@Composable
private fun SettingsReadout(source: MonitorSettingsReadoutSource, first: Boolean = false) {
    MonitorSettingsInlineRow(source.title, source.help, showTopDivider = !first) { MonitorSettingsValueText(source.value ?: "--") }
}
@Composable
internal fun SettingsLink(source: MonitorSettingsLinkSource) {
    MonitorLinkHealthScale(source.healthTitle, source.healthCaption, source.score ?: 0)
    MonitorConnectionSettings(source.transport, source.transportHelp, source.phase, source.phaseHelp,
        source.network?.takeIf { it.isNotEmpty() }, source.networkHelp)
    if (source.choices.isNotEmpty() || source.controlHolder != null) MonitorSettingsRowCard("Picture") {
        source.controlHolder?.let { SettingsReadout(it) }
        source.choices.forEach { SettingsChoice(it) }
    }
    if (source.processingChoices.isNotEmpty() || source.processing.isNotEmpty()) {
        MonitorSettingsRowCard(source.processingTitle ?: "Processing") {
            source.processingChoices.forEachIndexed { index, choice ->
                MonitorSettingsInlineRow(choice.title, choice.help, showTopDivider = index > 0) {
                    MonitorSettingsSegmented(choice.choices.map { it.title },
                        choice.choices.firstOrNull { it.id == choice.selection }?.title ?: "--",
                        compact = true, fillWidth = false) { title ->
                        choice.choices.firstOrNull { it.title == title }?.let { choice.select(it.id) }
                    }
                }
            }
            source.processing.forEachIndexed { index, value ->
                SettingsReadout(value, first = index == 0 && source.processingChoices.isEmpty())
            }
        }
    }
    source.savedCameras?.let { MonitorSavedCameraSettings(it, source.savedCamerasHelp) }
}
@Composable
internal fun SettingsSharing(source: MonitorSettingsSharingSource?, feedback: () -> Unit) {
    if (source == null) {
        MonitorSettingsRowCard {
            Text("Coming soon...", style = LiveType.ui(15f, FontWeight.Medium), color = LiveDesign.muted,
                modifier = Modifier.fillMaxWidth().padding(vertical = 18.dp, horizontal = 2.dp))
        }
        return
    }
    val watching = source.watching
    if (watching != null) { MonitorSettingsRowCard { SettingsReadout(watching, true) }; return }
    var draft by remember { mutableStateOf(source.passcode) }
    MonitorSettingsRowCard {
        val setSharing = source.setSharing
        if (source.sharing != null && setSharing != null) MonitorSettingsSwitchInlineRow(source.sharingTitle,
            source.sharing, source.sharingHelp, showTopDivider = false) { setSharing(!source.sharing); feedback() }
        else SettingsReadout(MonitorSettingsReadoutSource(source.sharingTitle, source.sharingHelp, source.unavailable), true)
        source.failure?.let { Text(it, color = MonitorPalette.recording) }
        source.watcherCount?.let { SettingsReadout(it) }
        SettingsChoice(source.priority)
        MonitorSettingsInlineRow(source.passcodeTitle, source.passcodeHelp) {
            // The shared rule: only a code that takes effect reaches setPasscode (trimmed, empty
            // for an open feed); a shorter entry stays a draft and the code in force is kept.
            Column(horizontalAlignment = Alignment.End) {
                SettingsPasscodeField(draft, source.passcodeTitle) { value ->
                    draft = value
                    MonitorWatcherPasscodeRule.entry(value).passcode?.let(source.setPasscode)
                }
                if (MonitorWatcherPasscodeRule.entry(draft) == MonitorWatcherPasscodeRule.Entry.TooShort) {
                    Text(MonitorWatcherPasscodeRule.TOO_SHORT_HINT, color = LiveDesign.muted, fontSize = 11.sp,
                        textAlign = TextAlign.End, modifier = Modifier.width(160.dp))
                }
            }
        }
        MonitorSettingsSwitchInlineRow(source.controlRequestsTitle, source.controlRequests, source.controlRequestsHelp) {
            source.setControlRequests(!source.controlRequests); feedback()
        }
        source.pending?.let { pending -> MonitorSettingsInlineRow(pending.title, pending.help) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                source.decline?.let { MonitorSettingsActionPill(source.declineTitle, onClick = it) }
                source.grant?.let { MonitorSettingsActionPill(source.grantTitle, onClick = it) }
            }
        } }
        source.holder?.let { holder -> MonitorSettingsInlineRow(holder.title, holder.help) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                MonitorSettingsValueText(holder.value ?: "--")
                source.takeBack?.let { MonitorSettingsActionPill(source.takeBackTitle, onClick = it) }
            }
        } }
    }
}
/** The gyro card; still renders the deprecated mount row for a caller that passes one. */
@Suppress("DEPRECATION")
@Composable
internal fun SettingsGyro(source: MonitorSettingsGyroSource?, feedback: () -> Unit) {
    source?.let { gyro ->
        MonitorSettingsRowCard("Gyro logging") {
            for (row in monitorSettingsGyroRows(gyro)) when (row) {
                MonitorSettingsGyroRow.LOGGING -> MonitorSettingsSwitchInlineRow("Log gyro with camera recordings", gyro.enabled,
                    help = "Mount this phone firmly to the camera. Synchronize exported logs in Gyroflow.",
                    showTopDivider = false) {
                    if (gyro.available) { feedback(); gyro.setEnabled(!gyro.enabled) }
                }
                MonitorSettingsGyroRow.STATUS -> MonitorSettingsInlineRow("Status", null) {
                    MonitorSettingsValueText(gyro.status)
                }
                MonitorSettingsGyroRow.MOUNT -> gyro.configureMount?.let { configureMount ->
                    MonitorSettingsInlineRow("Phone mount",
                        "Choose the phone's position relative to the camera. Keep the mount unchanged during a take; rotating the whole rig needs no new selection.") {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            gyro.mountName?.let { MonitorSettingsValueText(it) }
                            MonitorSettingsActionPill("Configure", onClick = configureMount)
                        }
                    }
                }
                MonitorSettingsGyroRow.CALIBRATE -> gyro.calibrate?.let { calibrate ->
                    MonitorSettingsInlineRow(GyroCopy.settingsCalibrate, null) {
                        MonitorSettingsActionPill("Open", onClick = { feedback(); calibrate() })
                    }
                }
            }
        }
    }
}

@Composable
internal fun SettingsControls(source: MonitorSettingsControlsSource, feedback: () -> Unit) {
    if (source.hapticsHelp != null) {
        MonitorOperatorSafetySettings(source.recordConfirmation, source.haptics, source.keepAwake,
            source.setRecordConfirmation, source.setHaptics, source.setKeepAwake, hapticsHelp = source.hapticsHelp,
            keepScreenAwakeHelp = source.keepAwakeHelp, feedback = feedback)
    } else {
        MonitorOperatorSafetySettings(source.recordConfirmation, source.haptics, source.keepAwake,
            source.setRecordConfirmation, source.setHaptics, source.setKeepAwake,
            keepScreenAwakeHelp = source.keepAwakeHelp, feedback = feedback)
    }
    val shutter = source.shutter
    val rotation = source.autoRotateRow
    MonitorInputOrientationSettings(shutter?.enabled, shutter?.setEnabled,
        remoteTitle = shutter?.title ?: "Remote shutter", remoteCaption = shutter?.caption,
        autoRotateFeed = rotation?.enabled, onAutoRotateFeed = rotation?.setEnabled,
        rotationTitle = rotation?.title ?: "Auto-Rotate Feed", rotationHelp = rotation?.help.orEmpty(),
        feedback = feedback)
    val motion = source.motion ?: return
    motion.sensitivity?.let { MonitorGimbalSettings(it) }
    motion.joystick?.let { joystick ->
        MonitorJoystickSettings(joystick.size, joystick.invertPan, joystick.invertTilt, joystick.deadZone,
            joystick.response, identifierPrefix = joystick.identifier)
    }
    motion.controller?.let { MonitorControllerSettings(it, motion.controllerStatus, motion.controllerHelp) }
}

@Suppress("DEPRECATION") // The storage help still mentions a mount preset for a caller that passes one.
@Composable
internal fun SettingsStorage(configuration: MonitorOperatorSettingsConfiguration) {
    configuration.gyro?.let { gyro ->
        MonitorSettingsRowCard("Gyro logs") {
            MonitorSettingsInlineRow("Saved motion logs",
                if (gyro.configureMount == null)
                    "Share a log with the matching camera video, then select its lens and mount orientation in Gyroflow."
                else "Share a log with the matching camera video, then select its lens in Gyroflow. A configured phone mount is included in each new log.",
                showTopDivider = false) {
                MonitorSettingsActionPill("Open", onClick = gyro.openLogs)
            }
        }
    }

    configuration.account?.let { SettingsAccount(it) }
    configuration.unconfiguredAccount?.let { account ->
        MonitorAccountSettings(account.title, account.help.orEmpty(), MonitorAccountState.NOT_CONFIGURED,
            statusLabel = account.value)
    }
    configuration.cache?.let { cache ->
        MonitorOperatorCacheSettings(cache.source, cache.cacheOriginals, cache.setCacheOriginals,
            cacheHelp = cache.cacheHelp, scopeHelp = cache.scopeHelp, clearHelp = cache.clearHelp,
            formatBytes = cache.formatBytes, feedback = configuration.feedback, checkingLabel = cache.checking,
            readFailureLabel = cache.readFailure, clearFailureLabel = cache.clearFailure,
            summaryColor = cache.summaryColor)
    }
}

@Composable
internal fun SettingsSystem(configuration: MonitorOperatorSettingsConfiguration, openLegal: (MonitorLegalPage) -> Unit) {
    val context = LocalContext.current
    val support = configuration.support
    val legal = configuration.legal
    MonitorSupportSettings(support.automaticReports, support.available, support.automaticHelp, support.unavailableHelp,
        support.setAutomaticReports, support.report, legal?.let { { openLegal(MonitorLegalPage.PRIVACY) } } ?: support.legacyPrivacy,
        support.status, support.discard, configuration.feedback, support.reportTitle, support.reportHelp,
        support.reportActionTitle, support.actions)
    configuration.diagnostics?.let { diagnostics ->
        var expanded by remember { mutableStateOf(false) }
        MonitorDiagnosticSettings(expanded, { expanded = it }, diagnostics.deleteHelp, diagnostics.save,
            delete = {
                diagnostics.incidents.deleteStoredReports { deleted ->
                    Toast.makeText(context,
                        if (deleted) "Saved feed reports deleted" else "Couldn't delete saved feed reports. Please try again.",
                        Toast.LENGTH_LONG).show()
                }
            })
    }
    if (legal != null) {
        MonitorProjectLegalSettings(support.sourceHelp, support.termsHelp,
            source = {
                val url = support.sourceUrl
                if (url != null && !openMonitorLink(context, url)) {
                    Toast.makeText(context, MONITOR_LINK_UNAVAILABLE, Toast.LENGTH_SHORT).show()
                }
            },
            privacy = { openLegal(MonitorLegalPage.PRIVACY) }, terms = { openLegal(MonitorLegalPage.TERMS) },
            licenses = { openLegal(MonitorLegalPage.LICENSES) }, notice = { openLegal(MonitorLegalPage.NOTICE) })
    }
    if (legal == null && support.legacySource != null && support.legacyPrivacy != null && support.legacyTerms != null) {
        MonitorProjectLegalSettings(support.sourceHelp, support.termsHelp,
            source = support.legacySource, privacy = support.legacyPrivacy, terms = support.legacyTerms)
    }
    configuration.information?.let { information ->
        MonitorAppInformationSettings(information.theme, information.protocolName, information.version,
            information.themeHelp, information.protocolHelp, information.versionHelp)
    }
}

/** The placeholder an empty passcode field shows, as on iOS (`SecureField("Optional")`). */
internal const val SETTINGS_PASSCODE_PLACEHOLDER = "Optional"

/**
 * The watcher passcode entry: an outlined field with a placeholder, so an empty code is still a
 * visible target, named by its row title for TalkBack (hardware pass 3.5). The placeholder is
 * drawn, not composed: a child text node would make Compose move the field's name onto a separate
 * node, leaving the editable node unnamed. The settings page pads its scroll area by the keyboard,
 * so the focused field scrolls clear of it.
 */
@Composable
internal fun SettingsPasscodeField(value: String, title: String, onValueChange: (String) -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    val measurer = rememberTextMeasurer()
    val placeholderStyle = LocalTextStyle.current.copy(color = MonitorPalette.faint, fontSize = 14.sp)
    BasicTextField(value, onValueChange = onValueChange,
        textStyle = LocalTextStyle.current.copy(color = MonitorPalette.text, fontSize = 14.sp, textAlign = TextAlign.End),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), singleLine = true,
        cursorBrush = SolidColor(MonitorPalette.accent),
        visualTransformation = PasswordVisualTransformation(),
        modifier = Modifier.width(120.dp).testTag(SETTINGS_PASSCODE_TAG)
            .semantics { contentDescription = title },
        decorationBox = { field ->
            Box(Modifier.fillMaxWidth().background(MonitorPalette.background.copy(alpha = 0.5f), shape)
                .border(1.dp, MonitorPalette.border, shape)
                .padding(horizontal = 10.dp, vertical = 8.dp)
                .drawBehind {
                    if (value.isEmpty()) {
                        val layout = measurer.measure(SETTINGS_PASSCODE_PLACEHOLDER, placeholderStyle)
                        drawText(layout, topLeft = Offset(size.width - layout.size.width,
                            (size.height - layout.size.height) / 2f))
                    }
                }, contentAlignment = Alignment.CenterEnd) {
                field()
            }
        })
}

internal const val SETTINGS_PASSCODE_TAG = "monitor.settings.sharing.passcode"
