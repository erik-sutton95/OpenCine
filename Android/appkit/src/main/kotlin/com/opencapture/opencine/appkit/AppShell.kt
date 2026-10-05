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
    public val privacy: (() -> Unit)? = null,
    public val terms: (() -> Unit)? = null,
    /** The cameras page's Pair, Media and Settings; `null` opens the shell's pair page or cover. */
    public val pair: (() -> Unit)? = null,
    public val media: (() -> Unit)? = null,
    public val settings: (() -> Unit)? = null,
    /** A tap on one of the app's own NEARBY rows ([AppShell]'s `extraNearby`), by its id. */
    public val extraNearby: ((String) -> Unit)? = null,
)

/**
 * The shared root over [ShellModel] (Swift `AppShell`): the cameras or pair page, or the monitor,
 * plus the cover pages. The monitor slot is keyed by [ShellModel.Monitor.id], so one host lives for
 * one monitor lifetime: covers, rotations and recomposition never create a second one.
 *
 * Temporary (SHELL-03 I-1): [monitor] is the app's existing native monitor, which presents the
 * shell's cover over itself while it still owns placement; [page] draws the cover pages over the
 * cameras and pair pages. [pageFrame] wraps those two pages in the app's insets. [extraNearby]:
 * the app's own NEARBY rows on the cameras page. [prePage]: the app's own page before the shared
 * ones (a first-pair wizard, a connect in progress), shown instead of the cameras or pair page
 * while it is set.
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
    extraNearby: List<CameraItem> = emptyList(),
    prePage: (@Composable () -> Unit)? = null,
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
            val route = if (shell.pairing || (cameras.saved.isEmpty() && !shell.camerasChosen)) {
                ShellModel.Route.PAIR
            } else {
                ShellModel.Route.CAMERAS
            }
            if (prePage != null) {
                prePage()
            } else {
                pageFrame(route) {
                    if (route == ShellModel.Route.PAIR) {
                        PairScreen(
                            model.cameras, onDone = model::endPairing, onDiagnostics = actions.diagnostics,
                            onReportProblem = actions.reportProblem, onWatchFeed = actions.watchFeed,
                            onPrivacy = actions.privacy, onTerms = actions.terms,
                        )
                    } else {
                        CamerasScreen(
                            model.cameras, brand.name, onPair = actions.pair ?: model::beginPairing,
                            onMedia = actions.media ?: { model.open(ShellModel.Cover.MEDIA) },
                            onSettings = actions.settings ?: { model.open(ShellModel.Cover.SETTINGS) },
                            nearbyNote = brand.nearbyNote, onMultiview = actions.multiview,
                            onIntegrationAction = actions.integrationAction,
                            extraNearby = extraNearby, onExtraNearby = actions.extraNearby ?: {},
                            onPrivacy = actions.privacy, onTerms = actions.terms,
                        )
                    }
                }
            }
            shell.cover?.let { page(it) }
        }
    }
}
