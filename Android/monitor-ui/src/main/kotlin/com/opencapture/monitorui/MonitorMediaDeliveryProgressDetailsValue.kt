package com.opencapture.monitorui

import androidx.compose.runtime.Immutable

/** Host-supplied delivery details; absent filename/destination stays unavailable. */
@Immutable
data class MonitorMediaDeliveryProgressDetailsValue(
    val filename: String? = null,
    val destination: String? = null,
)
