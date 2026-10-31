package com.opencapture.opencine.appkitnative

import android.graphics.Bitmap
import android.os.Build
import com.opencapture.opencine.cameracontrols.MonitorStillLook
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.runtime.MonitorBitmapEffects

/**
 * The still viewer's picture assists on the phone's own effect chain: the AGSL pass the live feed
 * draws with (peaking, false colour, zebra), baked into a copy at most [maximumWidth] pixels wide.
 * Below API 33 (no AGSL) it renders nothing and the still shows unchanged.
 */
public class MonitorBitmapStillLook(private val maximumWidth: Int = DEFAULT_MAXIMUM_WIDTH) : MonitorStillLook {
    override fun render(picture: Bitmap, plan: FeedEffectsRenderPlan): Bitmap? {
        if (Build.VERSION.SDK_INT < 33 || picture.width <= 0 || picture.height <= 0) return null
        return MonitorBitmapEffects.create(plan, falseColorReady = plan.falseColorOn, zebraPolicy = plan.zebraMaskPolicy)
            .use { it.bakePreview(picture, maximumWidth) }
    }

    public companion object {
        /** Wide enough to stay sharp on a tablet at the page's 4x zoom ceiling over a fitted still. */
        public const val DEFAULT_MAXIMUM_WIDTH: Int = 3072
    }
}
