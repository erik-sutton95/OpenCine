package com.opencapture.opencine.dji

import com.opencapture.opencine.motion.NativeProgramZoomCommand
import com.opencapture.opencine.vocabulary.CamFov
import com.opencapture.opencine.vocabulary.CameraCommands

/** The `0x02/0xB8` body of each programmed zoom command (Swift `GimbalWaypoint+DJI`). */
internal val NativeProgramZoomCommand.payload: ByteArray
    get() = when (this) {
        is NativeProgramZoomCommand.Position -> CameraCommands.zoomLens(CamFov.lensPosition(factor))
        is NativeProgramZoomCommand.Track -> CameraCommands.zoomLens(CamFov.lensPosition(factor))
        NativeProgramZoomCommand.Stop -> CameraCommands.zoomStop()
    }
