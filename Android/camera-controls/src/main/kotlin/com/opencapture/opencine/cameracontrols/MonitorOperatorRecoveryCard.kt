package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.appkit.MonitorRecoveryOverlay
import com.opencapture.opencine.vocabulary.SessionDropSuspect
import com.opencapture.opencine.vocabulary.SessionRecoveryCopy
import com.opencapture.opencine.vocabulary.SessionRecoveryDrive
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlinx.coroutines.delay

/**
 * The recovery card over a held picture after an established session dropped, with the one presentation
 * policy (Swift `SessionRecoveryOverlay`): the first automatic retry waits out a short grace, so a blip that
 * heals within it stays quiet, while later attempts and the operator's choice show at once; the actions keep
 * the platform's 48 dp touch target. Sources pass state and copy only.
 */
@Composable
public fun MonitorOperatorRecoveryCard(
    state: SessionRecoveryUi,
    cameraName: String,
    onRetry: () -> Unit,
    onOperatorMenu: () -> Unit,
    modifier: Modifier = Modifier,
    /** The likely cause the paused card names, when the source can tell. */
    dropSuspect: SessionDropSuspect? = null,
) {
    if (!state.isRecovering) return
    // Restarts with each recovery: the card leaves composition while the session is idle.
    var graceElapsed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(SessionRecoveryDrive.CARD_GRACE_MS)
        graceElapsed = true
    }
    if (!showsRecoveryCard(state, graceElapsed)) return
    MonitorRecoveryOverlay(
        retrying = state is SessionRecoveryUi.Retrying,
        title = SessionRecoveryCopy.title(state),
        detail = SessionRecoveryCopy.detail(state, cameraName, dropSuspect),
        retryTitle = SessionRecoveryCopy.RETRY_CONNECTION,
        operatorMenuTitle = SessionRecoveryCopy.OPERATOR_MENU,
        onRetry = onRetry,
        onOperatorMenu = onOperatorMenu,
        modifier = modifier,
        actionMinHeight = 48.dp,
    )
}

/** Whether the card shows now: always while recovering, except the first retry inside its grace. */
internal fun showsRecoveryCard(state: SessionRecoveryUi, graceElapsed: Boolean): Boolean = when (state) {
    SessionRecoveryUi.Idle -> false
    is SessionRecoveryUi.Retrying -> state.attempt > 1 || graceElapsed
    else -> true
}
