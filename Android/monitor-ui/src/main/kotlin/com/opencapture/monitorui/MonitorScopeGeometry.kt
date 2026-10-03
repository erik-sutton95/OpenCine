package com.opencapture.monitorui

data class MonitorScopeRect(val x: Float, val y: Float, val width: Float, val height: Float) {
    val minX get() = x
    val minY get() = y
    val maxX get() = x + width
    val maxY get() = y + height
    val midX get() = x + width / 2f
    val midY get() = y + height / 2f
}

object MonitorScopeGeometry {
    fun waveformPlot(width: Float, height: Float, density: Float = 1f): MonitorScopeRect {
        val side = 6f * density
        val top = 26f * density
        return MonitorScopeRect(side, top, width - side * 2f, maxOf(1f, height - top - 2f * density))
    }
    fun vectorscopeSquare(width: Float, height: Float, density: Float = 1f): MonitorScopeRect {
        val sidePad = 6f * density
        val top = 26f * density
        val plot = MonitorScopeRect(sidePad, top, width - sidePad * 2f, maxOf(1f, height - top - 8f * density))
        val side = minOf(plot.width, plot.height)
        return MonitorScopeRect(plot.midX - side / 2f, plot.midY - side / 2f, side, side)
    }
    fun plotY(ire: Double, plot: MonitorScopeRect, density: Float = 1f): Float =
        plot.maxY - density - (ire / 100.0).toFloat() * (plot.height - 2f * density)
    fun laneX(xRatio: Double, lane: Int, mode: MonitorParadeMode, plot: MonitorScopeRect): Float {
        val width = plot.width / mode.laneCount
        return plot.minX + lane * width + xRatio.toFloat() * (width - 1f)
    }
}
