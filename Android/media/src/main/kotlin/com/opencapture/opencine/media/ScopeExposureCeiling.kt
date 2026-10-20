package com.opencapture.opencine.media

import kotlin.math.round

/** Source-qualified preview saturation on one transfer curve. Supplied by the integration. */
data class ScopeClipCalibration(
    val referenceIso: Int,
    val referenceByte: Int,
    val refinementMaximumByte: Int = referenceByte,
    val noiseAllowance: Int = 2,
    val refinementAtOrAboveReference: Boolean = false,
) {
    init {
        require(referenceIso > 0)
        require(referenceByte in 1..254)
        require(refinementMaximumByte in referenceByte..254)
        require(noiseAllowance >= 0)
    }
}

data class ScopeClipProfile(
    val calibrations: Map<MonitorTransfer, ScopeClipCalibration> = emptyMap(),
    val defaultIso: Int? = null,
    /**
     * ISO the ceiling assumes when the source reports that its ISO is not known (an Auto ISO
     * camera that does not publish the applied value). `null` keeps the last known report.
     * A source whose clip falls below its reference ISO names its lowest ISO here, so an
     * unreported Auto ISO can only warn early, never miss a clip. Swift `unreportedISO`.
     */
    val unreportedIso: Int? = null,
) {
    init { require(unreportedIso == null || unreportedIso in 50..102_400) }
}

/** Read-only clip facts accepted by portable scope math. */
interface ScopeClipSource {
    fun clipByte(transfer: MonitorTransfer, iso: Int? = null): Int
    fun clipEncoded(transfer: MonitorTransfer, iso: Int? = null): Double = clipByte(transfer, iso) / 255.0
}

/** Immutable sampling-time clip fact. Later ISO changes cannot rescale this publication. */
data class ScopeClipSnapshot(val transfer: MonitorTransfer? = null, val byte: Int = 255) : ScopeClipSource {
    init { require(byte in 1..255) }
    override fun clipByte(transfer: MonitorTransfer, iso: Int?): Int = if (this.transfer == transfer) byte else 255
}

/** One source's ISO and tap history. Curve calibration never comes from a manufacturer branch. */
open class ScopeExposureCeiling(private val profile: ScopeClipProfile = ScopeClipProfile()) : ScopeClipSource {
    companion object {
        const val CLIP_SHELF_CODES = 7
        val UNOBSERVED: ScopeExposureCeiling get() = ScopeExposureCeiling()
    }
    private var iso: Int? = profile.defaultIso
    private val refined = HashMap<MonitorTransfer, Int>()
    private val observed = HashMap<Pair<MonitorTransfer, Int?>, Int>()
    private val declared = HashMap<MonitorTransfer, Int>()
    private val lock = Any()

    fun setISO(value: Int) {
        if (value in 50..102_400) synchronized(lock) { iso = value }
    }
    /**
     * Applies a camera report. A positive ISO is set as [setISO] does. `null`, zero or a negative
     * value means the camera did not report its applied ISO: the ceiling moves to the profile's
     * [ScopeClipProfile.unreportedIso] when it names one, else keeps the last report.
     */
    fun syncISO(value: Int?) {
        if (value != null && value > 0) { setISO(value); return }
        val unreported = profile.unreportedIso ?: return
        synchronized(lock) { iso = unreported }
    }
    fun resolvedISO(): Int? = synchronized(lock) { iso }
    /** The profile's assumption for an unreported ISO; `null` keeps the last report. */
    val unreportedIso: Int? get() = profile.unreportedIso
    /**
     * A clip the source states for [transfer] at its current settings (a camera's published
     * overexposure warning code for its ISO), in place of measured calibration and tap history
     * for that transfer. `null` withdraws it. [reset] clears it with the rest of the source's state.
     */
    fun declare(clipByte: Int?, transfer: MonitorTransfer) = synchronized(lock) {
        if (clipByte == null) declared.remove(transfer) else declared[transfer] = clipByte.coerceIn(1, 255)
    }
    fun reset() = synchronized(lock) {
        iso = profile.defaultIso
        refined.clear()
        observed.clear()
        declared.clear()
    }
    override fun clipEncoded(transfer: MonitorTransfer, iso: Int?): Double = clipByte(transfer, iso) / 255.0
    override fun clipByte(transfer: MonitorTransfer, iso: Int?): Int = synchronized(lock) {
        declared[transfer]?.let { return@synchronized it }
        val ei = iso?.takeIf { it > 0 } ?: this.iso
        maxOf(tableByte(transfer, ei), observed[transfer to ei] ?: 0)
    }
    fun observeTapMax(byte: Int, transfer: MonitorTransfer): Pair<Int, Boolean> = synchronized(lock) {
        val calibration = profile.calibrations[transfer]?.takeIf { transfer !in declared }
            ?: return@synchronized clipByte(transfer) to false
        if (byte <= 0 || byte >= 255) return@synchronized clipByte(transfer) to false
        val ei = iso ?: calibration.referenceIso
        val atReference = if (calibration.refinementAtOrAboveReference) ei >= calibration.referenceIso
            else ei == calibration.referenceIso
        if (atReference && byte > (refined[transfer] ?: calibration.referenceByte) &&
            byte <= calibration.refinementMaximumByte) refined[transfer] = byte
        val table = tableByte(transfer, iso)
        val key = transfer to iso
        val previous = observed[key] ?: 0
        val raised = minOf(maxOf(previous, byte), minOf(254, table + calibration.noiseAllowance))
        if (raised > table) observed[key] = raised
        maxOf(table, observed[key] ?: 0) to (raised > previous)
    }
    private fun tableByte(transfer: MonitorTransfer, iso: Int?): Int {
        val calibration = profile.calibrations[transfer] ?: return 255
        val ei = iso ?: calibration.referenceIso
        val reference = refined[transfer] ?: calibration.referenceByte
        val refLinear = LiveColorScience.linearize(reference / 255.0, transfer)
        val linear = if (ei >= calibration.referenceIso) refLinear else refLinear * ei / calibration.referenceIso
        return minOf(254, maxOf(1, round(LiveColorScience.encode(linear, transfer) * 255).toInt()))
    }
}
