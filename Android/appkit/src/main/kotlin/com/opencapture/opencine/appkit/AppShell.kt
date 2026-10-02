package com.opencapture.opencine.appkit

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier

/** What the shared root shows of the app's brand (Swift `ShellBrand`). Values only. */
public data class ShellBrand(
    public val name: String,
    /** How nearby cameras are found, under NEARBY ("announcing over Bluetooth"). */
    public val nearbyNote: String = "announcing over Bluetooth",
)

/** The app's own actions the shared pages offer (Swift `ShellActions`). `null` hides an entry. */
public class ShellActions(
    public val diagnostics: () -> Unit,
    public val reportProblem: () -> Unit,
    public val watchFeed: (() -> Unit)? = null,
    public val multiview: (() -> Unit)? = null,
    /** Camera id, integration action id ([com.opencapture.opencine.core.RecoveryAction.Integration]). */
    public val integrationAction: ((String, String) -> Unit)? = null,
)

/**
 * The shared root over [ShellModel] (Swift `AppShell`): the cameras or pair page, or the monitor,
 * plus the cover pages. The monitor slot is keyed by [ShellModel.Monitor.id], so one host lives for
 * one monitor lifetime: covers, rotations and recomposition never create a second one.
 *
 * Temporary (SHELL-03 I-1): [monitor] is the app's existing native monitor, which presents the
 * shell's cover over itself while it still owns placement; [page] draws the cover pages over the
 * cameras and pair pages. [pageFrame] wraps those two pages in the app's insets.
 */
@Composable
public fun AppShell(
    model: ShellModel,
    brand: ShellBrand,
    actions: ShellActions,
    monitor: @Composable (ShellModel.Monitor) -> Unit,
    page: @Composable (ShellModel.Cover) -> Unit,
    modifier: Modifier = Modifier,
    pageFrame: @Composable (route: ShellModel.Route, content: @Composable () -> Unit) -> Unit = { _, content -> content() },
) {
    val shell by model.state.collectAsState()
    val cameras by model.cameras.state.collectAsState()
    Box(modifier.fillMaxSize()) {
        val live = shell.monitor
        if (live != null) {
            key(live.id) {
                DisposableEffect(Unit) {
                    model.noteHost(mounted = true)
                    onDispose { model.noteHost(mounted = false) }
                }
                monitor(live)
            }
        } else {
            val route = if (shell.pairing || cameras.saved.isEmpty()) ShellModel.Route.PAIR else ShellModel.Route.CAMERAS
            pageFrame(route) {
                if (route == ShellModel.Route.PAIR) {
                    PairScreen(
                        model.cameras, onDone = model::endPairing, onDiagnostics = actions.diagnostics,
                        onReportProblem = actions.reportProblem, onWatchFeed = actions.watchFeed,
                    )
                } else {
                    CamerasScreen(
                        model.cameras, brand.name, onPair = model::beginPairing,
                        onMedia = { model.open(ShellModel.Cover.MEDIA) }, onSettings = { model.open(ShellModel.Cover.SETTINGS) },
                        nearbyNote = brand.nearbyNote, onMultiview = actions.multiview,
                        onIntegrationAction = actions.integrationAction,
                    )
                }
            }
            shell.cover?.let { page(it) }
        }
    }
}
