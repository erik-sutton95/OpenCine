package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.ConfirmationPrompt
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Values and explicit host actions for one operator decision (Swift `OperatorConsentRequest`). */
public class OperatorConsentRequest(
    public val title: String,
    public val message: String,
    public val confirmTitle: String,
    public val cancelTitle: String = "Cancel",
    public val id: String = UUID.randomUUID().toString(),
    internal val onConfirm: () -> Unit,
    internal val onCancel: () -> Unit = {},
)

/**
 * One pending decision, confined to the main thread. A reply consumes its ID before invoking
 * the current host; replacement and retirement invalidate replies without sending any command.
 */
public class OperatorConsent {
    private val mutable: MutableStateFlow<OperatorConsentRequest?> = MutableStateFlow(null)
    public val pending: StateFlow<OperatorConsentRequest?> = mutable.asStateFlow()
    private val settledIDs: MutableSet<String> = mutableSetOf()
    private var source: Any? = null
    private var isCurrent: () -> Boolean = { false }

    /** Presents a current host decision; a repeated publication keeps the same pending reply. */
    public fun present(request: OperatorConsentRequest, source: Any, isCurrent: () -> Boolean = { true }) {
        if (request.id in settledIDs || (mutable.value?.id == request.id && this.source == source)) return
        retire()
        this.source = source
        this.isCurrent = isCurrent
        mutable.value = request
    }

    /** Adapts an integration's neutral confirmation without depending on that integration. */
    public fun present(prompt: ConfirmationPrompt, source: Any, isCurrent: () -> Boolean = { true }) {
        present(
            OperatorConsentRequest(prompt.confirmationTitle, prompt.fallbackText, prompt.confirmTitle, prompt.cancelTitle,
                prompt.confirmationID, prompt.confirm, prompt.cancel),
            source, isCurrent,
        )
    }

    /** Admits only a current, unanswered confirmation. */
    public fun confirm(id: String): Unit = consume(id, confirmed = true)

    /** Declines only a current, unanswered decision. */
    public fun cancel(id: String): Unit = consume(id, confirmed = false)

    /** Invalidates a retired source without invoking either host action; null retires all. */
    public fun retire(source: Any? = null) {
        if (source != null && this.source != source) return
        mutable.value?.let { settledIDs += it.id }
        this.source = null
        isCurrent = { false }
        mutable.value = null
    }

    private fun consume(id: String, confirmed: Boolean) {
        val request = mutable.value?.takeIf { it.id == id } ?: return
        val admits = isCurrent
        retire()
        if (!admits()) return
        if (confirmed) request.onConfirm() else request.onCancel()
    }
}
