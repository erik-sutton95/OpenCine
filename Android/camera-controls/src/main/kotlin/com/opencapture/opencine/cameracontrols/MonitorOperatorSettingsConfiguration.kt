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
    public val score: Int?, public val choices: List<MonitorSettingsChoiceSource> = emptyList(),
    public val controlHolder: MonitorSettingsReadoutSource? = null,
    public val processingTitle: String? = null,
    public val processing: List<MonitorSettingsReadoutSource> = emptyList(),
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
public class MonitorSettingsControlsSource(
    public val recordConfirmation: Boolean, public val setRecordConfirmation: (Boolean) -> Unit,
    public val haptics: Boolean, public val setHaptics: (Boolean) -> Unit,
    public val keepAwake: Boolean, public val setKeepAwake: (Boolean) -> Unit,
    public val keepAwakeHelp: String,
    public val remoteShutter: Boolean? = null, public val setRemoteShutter: ((Boolean) -> Unit)? = null,
    public val remoteTitle: String = "Remote shutter", public val remoteCaption: String? = null,
    public val autoRotateFeed: Boolean? = null, public val setAutoRotateFeed: ((Boolean) -> Unit)? = null,
    public val rotationTitle: String = "Auto-Rotate Feed", public val rotationHelp: String,
)
public class MonitorSettingsCachePresentation(
    public val source: MonitorSettingsCacheSource,
    public val formatBytes: (Long) -> String,
    public val checking: String, public val readFailure: String, public val clearFailure: String,
    public val scopeHelp: String, public val clearHelp: String,
    public val summaryColor: Color = MonitorPalette.accent,
    public val confirmClear: Boolean = true,
)
public class MonitorSettingsSupportSource(
    public val automaticReports: Boolean?, public val available: Boolean,
    public val automaticHelp: String, public val unavailableHelp: String,
    public val setAutomaticReports: ((Boolean) -> Unit)?,
    public val reportTitle: String, public val reportHelp: String, public val reportActionTitle: String,
    public val report: () -> Unit, public val privacy: () -> Unit,
    public val status: MonitorReportStatus?, public val discard: (() -> Unit)?,
    public val actions: List<MonitorSupportAction>,
    public val sourceHelp: String, public val termsHelp: String,
    public val source: () -> Unit, public val terms: () -> Unit,
)
public data class MonitorSettingsInformationSource(
    public val theme: String, public val protocolName: String, public val version: String,
    public val themeHelp: String, public val protocolHelp: String, public val versionHelp: String,
)
/** Optional phone motion controls; capture and storage remain host-owned. */
public class MonitorSettingsGyroSource(
    public val enabled: Boolean, public val setEnabled: (Boolean) -> Unit,
    public val status: String, public val available: Boolean = true,
    public val openLogs: () -> Unit,
    public val mountName: String? = null,
    public val configureMount: (() -> Unit)? = null,
)
public class MonitorOperatorSettingsConfiguration(
    public val brand: String, public val isLive: Boolean, public val phase: String,
    public val close: () -> Unit, public val disconnect: (() -> Unit)?, public val feedback: () -> Unit,
    public val link: MonitorSettingsLinkSource, public val sharing: MonitorSettingsSharingSource?,
    public val sharingSubtitle: String?, public val sharingRail: String?,
    public val assistSections: List<MonitorAssistSettingsSection>,
    public val controls: MonitorSettingsControlsSource,
    public val cache: MonitorSettingsCachePresentation?,
    public val account: MonitorSettingsAccountSource? = null,
    public val support: MonitorSettingsSupportSource,
    public val information: MonitorSettingsInformationSource,
    public val gyro: MonitorSettingsGyroSource? = null,
)

/** Complete settings ownership using actual stores, optional services and bounded native leaves. */
@Composable
public fun MonitorOperatorSettingsScreen(
    configuration: MonitorOperatorSettingsConfiguration,
    borrowedDisplay: MonitorOperatorBorrowedDisplay,
    initialTab: MonitorSettingsTab = MonitorSettingsTab.LINK,
    sourceIdentity: Any? = null,
): Unit {
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(
        brand = configuration.brand, selection = selectedTab, onSelect = { selectedTab = it },
        isLive = configuration.isLive, phase = configuration.phase, close = configuration.close,
        disconnect = configuration.disconnect, feedback = configuration.feedback,
        source = MonitorOperatorSettingsSource.Configured(configuration, borrowedDisplay),
        sourceIdentity = sourceIdentity,
        sharingSubtitle = configuration.sharingSubtitle, sharingRail = configuration.sharingRail,
    ))
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
    source.score?.let { MonitorLinkHealthScale(source.healthTitle, source.healthCaption, it) }
    MonitorConnectionSettings(source.transport, source.transportHelp, source.phase, source.phaseHelp)
    if (source.choices.isNotEmpty() || source.controlHolder != null) MonitorSettingsRowCard("Picture") {
        source.controlHolder?.let { SettingsReadout(it) }
        source.choices.forEach { SettingsChoice(it) }
    }
    if (source.processing.isNotEmpty()) MonitorSettingsRowCard(source.processingTitle) {
        source.processing.forEachIndexed { index, value -> SettingsReadout(value, index == 0) }
    }
}
@Composable
internal fun SettingsSharing(source: MonitorSettingsSharingSource, feedback: () -> Unit) {
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
internal fun SettingsSystem(source: MonitorSettingsSupportSource, information: MonitorSettingsInformationSource,
    feedback: () -> Unit) {
    MonitorSupportSettings(source.automaticReports, source.available, source.automaticHelp, source.unavailableHelp,
        source.setAutomaticReports, source.report, source.privacy, source.status, source.discard, feedback,
        source.reportTitle, source.reportHelp, source.reportActionTitle, source.actions)
    MonitorProjectLegalSettings(source.sourceHelp, source.termsHelp, source.source, source.privacy, source.terms)
    MonitorAppInformationSettings(information.theme, information.protocolName, information.version,
        information.themeHelp, information.protocolHelp, information.versionHelp)
}
