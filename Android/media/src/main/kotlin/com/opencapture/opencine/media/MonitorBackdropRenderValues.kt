package com.opencapture.opencine.media

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** One native blur product; several presentation roles may share its pixels. */
data class MonitorBackdropBlurProduct(val radius: Double, val saturation: Double)

data class MonitorBackdropRasterSize(val width: Int, val height: Int, val scale: Double)

/** Native raster facts independent of camera and presentation roles. */
object MonitorBackdropRenderValues {
    const val MAXIMUM_DIMENSION = 320
    const val MINIMUM_INTERVAL = 1.0 / 60.0
    const val MINIMUM_INTERVAL_NS = 16_666_667L

    fun rasterSize(width: Double, height: Double): MonitorBackdropRasterSize? {
        if (!width.isFinite() || !height.isFinite() || width <= 1 || height <= 1) return null
        val scale = min(1.0, MAXIMUM_DIMENSION / max(width, height))
        return MonitorBackdropRasterSize(ceil(width * scale).toInt(), ceil(height * scale).toInt(), scale)
    }

    fun distinctProducts(products: List<MonitorBackdropBlurProduct>): List<MonitorBackdropBlurProduct> =
        products.distinct()
}

/** Absent map clipping means the requested FALSE map is not ready yet. */
data class MonitorBackdropLookState(val clipByte: Int, val mapClipByte: Int?)
