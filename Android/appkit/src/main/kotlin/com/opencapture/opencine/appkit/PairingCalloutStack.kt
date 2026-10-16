package com.opencapture.opencine.appkit

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import kotlinx.coroutines.delay

/** The app's words in the pairing callouts: what it calls the camera and its vendor-app advice. */
public data class PairingCalloutCopy(
    /** "find your <cameraNoun>" in the Bluetooth and permission callouts. */
    public val cameraNoun: String,
    /** Shown while choosing a camera: what to close before pairing. */
    public val precheck: String,
    /** Shown after 20 s of scanning without a camera. */
    public val stillLooking: String,
)

/**
 * The pair wizard's content: the Swift core, Bluetooth, permission and Location fixes with their
 * actions, then, while choosing a camera, the vendor-app precheck or, after 20 s without a
 * camera, the still-looking tip. The app passes its session's scan phase and radio state.
 */
@Composable
public fun PairingCalloutStack(
    cameras: CamerasModel,
    coreLoaded: Boolean,
    scanning: Boolean,
    radioOn: Boolean,
    discovery: PermissionGate,
    copy: PairingCalloutCopy,
    log: (level: String, category: String, code: String, message: String) -> Unit,
    onEnableBluetooth: () -> Unit,
) {
    val context = LocalContext.current
    val state by cameras.state.collectAsState()
    val permissionsGranted = discovery.granted
    var locationOff by remember { mutableStateOf(false) }
    if (DiscoveryPermissions.discoveryNeedsLocationServices()) {
        LaunchedEffect(Unit) {
            while (true) {
                locationOff = !DiscoveryPermissions.locationServicesOn(context)
                delay(1_000)
            }
        }
    }
    // The tips belong to choosing a camera, as on the pair page this app has always shown.
    val choosing = state.attempts.isEmpty()
    val waitingForCamera =
        PairingCalloutRules.waitingForCamera(choosing, scanning, radioOn, permissionsGranted, locationOff, state.nearby.isEmpty())
    var slowScan by remember { mutableStateOf(false) }
    LaunchedEffect(waitingForCamera) {
        slowScan = false
        if (!waitingForCamera) return@LaunchedEffect
        delay(SLOW_SCAN_HINT_MS)
        slowScan = true
        log("info", "ble", "scan", "scan: no camera after ${SLOW_SCAN_HINT_MS / 1_000} s, hint shown")
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!coreLoaded) {
            PairingCallout(
                title = "Swift core",
                body = "Swift core isn't loaded. Build with `just android-core` on an arm64 device.",
                icon = MonitorIcon.TRIANGLE_ALERT,
            )
        }
        if (!radioOn) {
            PairingCallout(
                title = "Bluetooth",
                body = PairingCalloutRules.bluetoothBody(copy),
                icon = MonitorIcon.RADIO,
                action = "Turn on",
                onAction = onEnableBluetooth,
            )
        }
        if (!permissionsGranted) {
            val name = DiscoveryPermissions.settingsName(DiscoveryPermissions.discovery())
            PairingCallout(
                title = name,
                body = PairingCalloutRules.permissionBody(
                    copy, name, discovery.needsSettings, DiscoveryPermissions.discoveryNeedsLocationServices(),
                ),
                icon = MonitorIcon.RADIO,
                action = if (discovery.needsSettings) "Open Settings" else "Allow",
                onAction = discovery::request,
            )
        }
        if (permissionsGranted && locationOff) {
            PairingCallout(
                title = "Location",
                body = "Android 10 and 11 only find Bluetooth cameras while Location is on.",
                icon = MonitorIcon.RADIO,
                action = "Turn on",
                onAction = { runCatching { context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) } },
            )
        }
        if (slowScan && waitingForCamera) {
            PairingCallout(title = "Still looking", body = copy.stillLooking, icon = MonitorIcon.RADIO)
        } else if (choosing) {
            PairingCallout(title = "Before you pair", body = copy.precheck, icon = MonitorIcon.TRIANGLE_ALERT)
        }
    }
}

/** The callouts' decisions and copy, separate from Compose so they are unit tested. */
internal object PairingCalloutRules {
    /** Scanning with everything on and nothing nearby yet: the still-looking clock runs. */
    fun waitingForCamera(
        choosing: Boolean,
        scanning: Boolean,
        radioOn: Boolean,
        permissionsGranted: Boolean,
        locationOff: Boolean,
        nothingNearby: Boolean,
    ): Boolean = choosing && scanning && radioOn && permissionsGranted && !locationOff && nothingNearby

    fun bluetoothBody(copy: PairingCalloutCopy): String =
        "Turn Bluetooth on so we can find your ${copy.cameraNoun}."

    fun permissionBody(copy: PairingCalloutCopy, name: String, needsSettings: Boolean, needsLocation: Boolean): String =
        when {
            needsSettings ->
                "Android won’t ask again. Open Settings › Permissions › $name and choose Allow."
            needsLocation ->
                "Android 10 and 11 need Location to scan for Bluetooth cameras. It is only used to find your ${copy.cameraNoun}."
            else -> "Allow Nearby devices so we can find your ${copy.cameraNoun} over Bluetooth. Location isn’t needed."
        }
}

@Composable
private fun PairingCallout(
    title: String,
    body: String,
    icon: MonitorIcon,
    action: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val shape = RoundedCornerShape(11.dp)
    Column(
        Modifier.fillMaxWidth()
            .background(Color.White.copy(alpha = 0.03f), shape)
            .border(1.dp, Color.White.copy(alpha = 0.06f), shape)
            .then(if (onAction != null) Modifier.clickable(role = Role.Button, onClick = onAction) else Modifier)
            .padding(13.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Box(
                Modifier.size(26.dp).background(MonitorPalette.accent.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center,
            ) {
                MonitorIcon(icon, null, Modifier.size(14.dp), MonitorPalette.accent)
            }
            Text(
                title.uppercase(),
                color = MonitorPalette.secondary,
                style = MonitorTypography.text(9f, FontWeight.Bold).copy(letterSpacing = 1.4.sp),
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            if (action != null) {
                Text(action, color = MonitorPalette.accent, style = MonitorTypography.text(11f, FontWeight.SemiBold), maxLines = 1)
            }
        }
        Text(body, color = MonitorPalette.secondary, style = MonitorTypography.text(12.5f).copy(lineHeight = 15.5.sp))
    }
}

private const val SLOW_SCAN_HINT_MS = 20_000L
