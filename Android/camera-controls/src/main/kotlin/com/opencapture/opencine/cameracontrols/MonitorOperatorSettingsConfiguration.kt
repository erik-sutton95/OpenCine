package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.background
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.*
import com.opencapture.monitorui.settings.*
import com.opencapture.opencine.appkit.MonitorSettingsCacheSource
import com.opencapture.opencine.appkit.MonitorSettingsAccountActions
import com.opencapture.opencine.appkit.MonitorSettingsAccountModel
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.appkit.diagnostics.FeedIncidentRuntime
import com.opencapture.opencine.core.RouteKind
import android.widget.Toast
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight

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
public class MonitorSettingsControlsSource(
    public val recordConfirmation: Boolean, public val setRecordConfirmation: (Boolean) -> Unit,
    public val haptics: Boolean, public val setHaptics: (Boolean) -> Unit,
    public val keepAwake: Boolean, public val setKeepAwake: (Boolean) -> Unit,
    public val keepAwakeHelp: String,
    public val remoteShutter: Boolean? = null, public val setRemoteShutter: ((Boolean) -> Unit)? = null,
    public val remoteTitle: String = "Remote shutter", public val remoteCaption: String? = null,
    public val autoRotateFeed: Boolean? = null, public val setAutoRotateFeed: ((Boolean) -> Unit)? = null,
    public val rotationTitle: String = "Auto-Rotate Feed", public val rotationHelp: String = "",
    public val hapticsHelp: String? = null,
    public val motion: MonitorSettingsMotionSource? = null,
)
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
)
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
 * Every app's settings: one value per tab, built by the app from its model. Absent capability
 * sections (motion, sharing, account, cache) are null; the recipe for each tab is the same.
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
    public val tabs: List<MonitorSettingsTab> = MonitorSettingsTab.entries,
)

/** Complete settings ownership using actual stores, optional services and bounded native leaves. */
@Composable
public fun MonitorOperatorSettingsScreen(
    configuration: MonitorOperatorSettingsConfiguration,
    assistSections: List<MonitorAssistSettingsSection>,
    borrowedDisplay: MonitorOperatorBorrowedDisplay,
    initialTab: MonitorSettingsTab = MonitorSettingsTab.LINK,
    sourceIdentity: Any? = null,
): Unit {
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(configuration, selectedTab, { selectedTab = it },
        MonitorOperatorPictureSettings.Configured(assistSections, borrowedDisplay), sourceIdentity))
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
            BasicTextField(draft, onValueChange = { value ->
                draft = value.filter(Char::isDigit).take(4)
                if (draft.length == 4 || draft.isEmpty()) source.setPasscode(draft)
            }, textStyle = LocalTextStyle.current.copy(color = MonitorPalette.text, fontSize = 14.sp, textAlign = TextAlign.End),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), singleLine = true,
                modifier = Modifier.width(96.dp))
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
    MonitorInputOrientationSettings(source.remoteShutter, source.setRemoteShutter,
        remoteTitle = source.remoteTitle, remoteCaption = source.remoteCaption,
        autoRotateFeed = source.autoRotateFeed, onAutoRotateFeed = source.setAutoRotateFeed,
        rotationTitle = source.rotationTitle, rotationHelp = source.rotationHelp, feedback = feedback)
    val motion = source.motion ?: return
    motion.sensitivity?.let { MonitorGimbalSettings(it) }
    motion.joystick?.let { joystick ->
        MonitorJoystickSettings(joystick.size, joystick.invertPan, joystick.invertTilt, joystick.deadZone,
            joystick.response, identifierPrefix = joystick.identifier)
    }
    motion.controller?.let { MonitorControllerSettings(it, motion.controllerStatus, motion.controllerHelp) }
}

@Composable
internal fun SettingsStorage(configuration: MonitorOperatorSettingsConfiguration) {
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
        support.setAutomaticReports, support.report, legal?.let { { openLegal(MonitorLegalPage.PRIVACY) } },
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
    configuration.information?.let { information ->
        MonitorAppInformationSettings(information.theme, information.protocolName, information.version,
            information.themeHelp, information.protocolHelp, information.versionHelp)
    }
}
