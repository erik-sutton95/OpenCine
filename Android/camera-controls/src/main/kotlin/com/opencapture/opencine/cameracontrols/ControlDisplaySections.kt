package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.vocabulary.ControlCapabilities

/** Display preferences for the camera's zoom and gimbal controls and color readout.
 * Other sections can be filled by host services; their current data and connection gates
 * belong to the live monitor, not to camera support. */
public val ControlCapabilities.displaySections: Set<MonitorDisplaySection>
    get() = MonitorDisplaySection.entries.filterTo(mutableSetOf()) { section ->
        when (section) {
            MonitorDisplaySection.ZOOM_CHIP -> zoom.isOffered
            MonitorDisplaySection.GIMBAL_STICK -> gimbal.isOffered
            MonitorDisplaySection.COLOR -> codecColor.isShown && codecColor.offer?.showsColor != false
            else -> true
        }
    }
