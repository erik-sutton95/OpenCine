package com.opencapture.opencine.vocabulary

/** Native ISO extensions are declared by the source; null means their support is unknown. */
public data class CaptureNativeISOCapabilities(public val hop: Boolean? = null, public val ceiling: Boolean? = null)
