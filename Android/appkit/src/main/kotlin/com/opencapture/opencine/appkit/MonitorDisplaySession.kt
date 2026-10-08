package com.opencapture.opencine.appkit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Display intent and editor return, over source-supplied admitted mode order. No camera IO. */
public class MonitorDisplaySession<Mode>(mode: Mode) {
    public var mode: Mode by mutableStateOf(mode)
    public var locked: Boolean by mutableStateOf(false)
    public var editingMode: Mode? by mutableStateOf(null)
    public var returnedMode: Mode? by mutableStateOf(null)
    public val isEditing: Boolean get() = editingMode != null

    public fun select(next: Mode, order: List<Mode>): Boolean {
        if (locked || next == mode || next !in order) return false
        mode = next
        return true
    }

    public fun cycle(order: List<Mode>): Boolean {
        if (locked) return false
        return next(order, mode)?.let { select(it, order) } ?: false
    }

    /** Disabled cycle modes remain editable; Done reconciles the live mode with source facts. */
    public fun beginEditing(mode: Mode): Unit { this.mode = mode; editingMode = mode }

    public fun finishEditing(order: List<Mode>): Mode? {
        val edited = editingMode ?: return null
        returnedMode = edited
        editingMode = null
        reconcile(order)
        return edited
    }

    public fun reconcile(order: List<Mode>): Boolean {
        if (mode in order) return false
        val first = order.firstOrNull() ?: return false
        mode = first
        return true
    }

    /** Retires editor presentation without changing current mode, lock or camera ownership. */
    public fun retireEditor(): Unit { editingMode = null; returnedMode = null }

    public companion object {
        public fun <Mode> next(order: List<Mode>, current: Mode): Mode? {
            if (order.isEmpty()) return null
            val index = order.indexOf(current)
            return if (index < 0) order.first() else order[(index + 1) % order.size]
        }
    }
}
