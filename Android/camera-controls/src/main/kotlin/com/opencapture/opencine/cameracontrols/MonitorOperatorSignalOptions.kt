package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorFalseColorReferenceValues

/** Only source-calibrated signal menus vary; the shared inspector owns navigation and lifetime. */
public data class MonitorOperatorSignalOptions(
    public val falseColor: (@Composable () -> Unit)? = null,
    public val zebra: (@Composable () -> Unit)? = null,
    public val reference: MonitorFalseColorReferenceValues? = null,
    public val referenceAvailable: Boolean? = null,
    public val level: (@Composable () -> Unit)? = null,
    public val instantReview: (@Composable () -> Unit)? = null,
)
