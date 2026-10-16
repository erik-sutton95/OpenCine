package com.opencapture.opencine.appkit

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp

/** What the shared root shows of the app's brand (Swift `ShellBrand`). Values only. */
public data class ShellBrand(
    public val name: String,
    /** How nearby cameras are found, under NEARBY ("announcing over Bluetooth"). */
    public val nearbyNote: String = "announcing over Bluetooth",
    /** Superseded by the integration's [com.opencapture.opencine.core.IntegrationPresentation.namesSetups]; `false` still hides Rename setup. */
    @Deprecated("Integrations declare it: IntegrationPresentation.namesSetups")
    public val renamesSetups: Boolean = true,
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
    /**
     * The cameras page's Pair a new camera, Media and Settings; `null` opens the shell's pair page or
     * cover. A nearby card always opens the shell's pair page ([CamerasModel.openNearby] decides
     * whether it connects at once).
     */
    public val pair: (() -> Unit)? = null,
    public val media: (() -> Unit)? = null,
    public val settings: (() -> Unit)? = null,
    /** A tap on one of the app's own NEARBY rows ([AppShell]'s `extraNearby`), by its id. */
    public val extraNearby: ((String) -> Unit)? = null,
)

/**
 * The pair page's frame in every app: the safe area plus the page margins. [AppShell] applies it
 * to the pair route; an app's own pair flow shown instead of it (a first-pair wizard) uses it too.
 */
public fun Modifier.pairPageFrame(): Modifier =
    safeDrawingPadding().padding(horizontal = 14.dp, vertical = 16.dp)

/** Existing native hosts may retain their cover placement while their callers migrate. */
public enum class ShellCoverPresentation { MONITOR, SHELL }

/**
 * The shared root over [ShellModel] (Swift `AppShell`): the cameras or pair page, or the monitor,
 * plus the cover pages. The monitor slot is keyed by [ShellModel.Monitor.id], so one host lives for
 * one monitor lifetime: covers, rotations and recomposition never create a second one.
 *
 * [ShellCoverPresentation.SHELL] retains the keyed native monitor beneath one sibling cover;
 * the covered monitor contributes no exposed controls. The pair page sits in [pairPageFrame], and
 * Back there stops a connect and returns to the cameras page when it has something to show.
 * [pageFrame] wraps the camera and pair pages in the app's own ground and overlays. [extraNearby]:
 * the app's own NEARBY rows on the cameras page. [prePage]: the app's own page before the shared
 * ones (a first-pair wizard, a connect in progress), shown instead of the cameras or pair page
 * while it is set. [pairingFlow]: the app's own rail and actions on the pair page
 * ([PairScreen]'s `pairingFlow`).
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
    pairingFlow: IntegrationPairingFlow? = null,
    coverPresentation: ShellCoverPresentation = ShellCoverPresentation.MONITOR,
): Unit = OperatorConsentPresenter(model.cameras.consent) {
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
                val hidden = coverPresentation == ShellCoverPresentation.SHELL && shell.cover != null
                Box(if (hidden) Modifier.clearAndSetSemantics { } else Modifier) { monitor(live) }
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
                        Box(Modifier.fillMaxSize().pairPageFrame()) {
                            BackHandler(enabled = cameras.attempts.isNotEmpty() || cameras.saved.isNotEmpty()) {
                                model.cameras.cancelAll()
                                model.endPairing()
                            }
                            PairScreen(
                                model.cameras, onDone = model::endPairing, onDiagnostics = actions.diagnostics,
                                onReportProblem = actions.reportProblem, onWatchFeed = actions.watchFeed,
                                pairingFlow = pairingFlow, onPrivacy = actions.privacy, onTerms = actions.terms,
                            )
                        }
                    } else {
                        CamerasScreen(
                            model.cameras, brand.name, onPair = actions.pair ?: model::beginPairing,
                            onMedia = actions.media ?: { model.open(ShellModel.Cover.MEDIA) },
                            onSettings = actions.settings ?: { model.open(ShellModel.Cover.SETTINGS) },
                            nearbyNote = brand.nearbyNote, onMultiview = actions.multiview,
                            onIntegrationAction = actions.integrationAction,
                            extraNearby = extraNearby, onExtraNearby = actions.extraNearby ?: {},
                            onPrivacy = actions.privacy, onTerms = actions.terms,
                            renamesSetups = @Suppress("DEPRECATION") brand.renamesSetups,
                            onPairNearby = model::beginPairing,
                        )
                    }
                }
            }
        }
        if (live == null || coverPresentation == ShellCoverPresentation.SHELL) shell.cover?.let { page(it) }
    }
}
