package com.opencapture.opencine.appkit

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf

/** The shell's one decision presenter, with replies bound to the alert that produced them. */
@Composable
public fun OperatorConsentDialog(owner: OperatorConsent) {
    val pending by owner.pending.collectAsState()
    pending?.let { request ->
        AlertDialog(
            onDismissRequest = { owner.cancel(request.id) },
            title = { Text(request.title) },
            text = { Text(request.message) },
            confirmButton = { TextButton(onClick = { owner.confirm(request.id) }) { Text(request.confirmTitle) } },
            dismissButton = { TextButton(onClick = { owner.cancel(request.id) }) { Text(request.cancelTitle) } },
        )
    }
}

/** The owners (by identity) whose decisions an ancestor already presents. */
private val LocalOperatorConsentPresenters = staticCompositionLocalOf<Set<OperatorConsent>> { emptySet() }

/**
 * Presents [owner]'s decisions once in a composition ancestry (Swift `operatorConsentPresenter`):
 * the outermost presenter for this exact owner renders [OperatorConsentDialog] and nested ones
 * defer to it; another owner's presenter never suppresses this one. Leaving composition sends
 * no reply and retires nothing.
 */
@Composable
internal fun OperatorConsentPresenter(owner: OperatorConsent, content: @Composable () -> Unit) {
    val ancestors = LocalOperatorConsentPresenters.current
    if (owner in ancestors) {
        content()
    } else {
        CompositionLocalProvider(LocalOperatorConsentPresenters provides ancestors + owner, content = content)
        OperatorConsentDialog(owner)
    }
}
