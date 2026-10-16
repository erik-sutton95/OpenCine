package com.opencapture.monitorui

/** Side-rail visibility from stored preferences and live safety facts. Swift: MonitorSideRailPlan. */
data class MonitorSideRailPlan(
    val lock: Boolean,
    val batteries: Boolean,
    val disp: Boolean,
    val record: Boolean,
    val media: Boolean,
    val settings: Boolean,
) {
    val isEmpty: Boolean get() = !(lock || batteries || disp || record || media || settings)

    companion object {
        fun showsLock(visible: Boolean, interfaceLocked: Boolean): Boolean = visible || interfaceLocked
        fun showsSettings(visible: Boolean, reachable: Boolean): Boolean = visible || !reachable

        fun resolve(lockVisible: Boolean, batteriesVisible: Boolean, recordVisible: Boolean,
            mediaVisible: Boolean, settingsVisible: Boolean, settingsReachable: Boolean,
            interfaceLocked: Boolean, recordingOrPending: Boolean): MonitorSideRailPlan =
            MonitorSideRailPlan(showsLock(lockVisible, interfaceLocked), batteriesVisible, true,
                recordVisible || recordingOrPending, mediaVisible,
                showsSettings(settingsVisible, settingsReachable))
    }
}
