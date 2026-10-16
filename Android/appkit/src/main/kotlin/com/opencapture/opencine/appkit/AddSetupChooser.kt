package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.RouteKind

/** One host-advertised setup capability, with the words for its current availability. */
public data class AddSetupOption(
    public val id: String,
    public val kind: RouteKind,
    public val title: String,
    public val detail: String,
    public val actionTitle: String,
    public val enabled: Boolean = true,
)

/** An optional host capability notice with an explicit action, such as permission for network names. */
public data class AddSetupNotice(public val id: String, public val message: String, public val actionTitle: String)

/** The shared setup chooser consumes capabilities and copy, never an app or manufacturer. */
public data class AddSetupChooser(
    public val title: String,
    public val detail: String,
    public val options: List<AddSetupOption>,
    public val footer: String? = null,
    public val identifierPrefix: String = "addSetup",
    public val notice: AddSetupNotice? = null,
) {
    /** Dispatches only a currently advertised, enabled option to its host. */
    public fun select(id: String, onSelect: (AddSetupOption) -> Unit): Boolean {
        val option = options.firstOrNull { it.id == id && it.enabled } ?: return false
        onSelect(option)
        return true
    }
}
