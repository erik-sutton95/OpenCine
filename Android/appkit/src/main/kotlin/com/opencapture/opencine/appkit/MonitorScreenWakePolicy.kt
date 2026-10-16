package com.opencapture.opencine.appkit

/** The operator preference applies to every active foreground surface. */
public object MonitorScreenWakePolicy {
    public fun keepAwake(enabled: Boolean, sceneActive: Boolean): Boolean = enabled && sceneActive
}

/** One root owns native wake requests across changes of foreground surface. */
public class MonitorScreenWakeOwner(private val apply: (Boolean) -> Unit) {
    private var applied: Boolean? = null

    public fun update(enabled: Boolean, sceneActive: Boolean) {
        set(MonitorScreenWakePolicy.keepAwake(enabled, sceneActive))
    }

    public fun retire() { set(false) }

    private fun set(value: Boolean) {
        if (applied == value) return
        applied = value
        apply(value)
    }
}
