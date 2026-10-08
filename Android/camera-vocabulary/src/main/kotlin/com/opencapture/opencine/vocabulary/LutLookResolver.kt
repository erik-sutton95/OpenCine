package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.MonitorTransfer

/** File the live GPU path should pack, mirroring iOS `LUTResolver`. */
sealed class LutLookSource {
    data class Asset(
        val fileName: String,
        val inputTransfer: MonitorTransfer? = null,
        val title: String? = null,
    ) : LutLookSource()

    data class Custom(val fileName: String) : LutLookSource()

    data class Creative(val name: String) : LutLookSource()

    data object Off : LutLookSource()
}

/** Resolves Auto vs locked official/custom cubes. No I/O. */
object LutLookResolver {
    fun resolve(
        selection: String,
        lutOn: Boolean,
        colorMode: Int,
        profile: CameraLUTProfile? = null,
        isPhoto: Boolean = false,
        cameraLooks: List<LutEntry> = profile?.cameraLooks.orEmpty(),
    ): LutLookSource {
        if (!lutOn) return LutLookSource.Off
        if (isPhoto && isTechnicalLogSelection(selection)) return LutLookSource.Off
        profile?.selections?.get(selection)?.let { return it }
        cameraLooks.firstOrNull { it.id == selection }?.let { entry ->
            return entry.fileName?.let { LutLookSource.Asset(it, entry.inputTransfer, entry.title) }
                ?: LutLookSource.Off
        }
        if (selection == LutCatalog.AUTO || selection == LutCatalog.OFFICIAL_AUTO) {
            // Auto picks the camera look whose input transfer matches the live transfer (an I-Log conversion).
            autoCameraLook(colorMode, cameraLooks)?.let { return it }
            return profile?.automatic?.get(colorMode) ?: LutLookSource.Off
        }
        return when (selection) {
            LutCatalog.OFF -> LutLookSource.Off
            LutCatalog.AUTO, LutCatalog.OFFICIAL_AUTO -> profile?.automatic?.get(colorMode) ?: LutLookSource.Off
            "officialDLog" -> LutLookSource.Asset("DJI_Official_Pocket4P_DLog_Rec709_33.cube")
            "officialDLog2" -> LutLookSource.Asset("DJI_Official_Pocket4P_DLog2_Rec709_33.cube")
            "creativeMono", "creativeContrast", "creativeWarm", "creativeCool" ->
                LutLookSource.Creative(LutCatalog.creativeName(selection) ?: "Mono")
            "djiDLog" -> LutLookSource.Asset("DJI_Official_Pocket4P_DLog_Rec709_33.cube")
            "djiDLog2" -> LutLookSource.Asset("DJI_Official_Pocket4P_DLog2_Rec709_33.cube")
            "djiDLogM" -> profile?.selections?.get(selection) ?: LutLookSource.Off
            "djiAction6DLogM" -> LutLookSource.Asset("DJI_Official_Action6_DLogM_Rec709_33.cube")
            else -> {
                LutCatalog.customFileName(selection)?.let { LutLookSource.Custom(it) }
                    ?: LutCatalog.officialBuiltInLooks.firstOrNull { LutCatalog.matches(it, selection) }
                        ?.fileName
                        ?.let { LutLookSource.Asset(it) }
                    ?: LutCatalog.officialCameraCubes.firstOrNull { LutCatalog.matches(it, selection) }
                        ?.fileName
                        ?.let { LutLookSource.Asset(it) }
                    ?: LutLookSource.Off
            }
        }
    }

    /** iOS `LUTResolver.statusLabel`: Auto and the official Auto show the resolved cube title. */
    fun statusLabel(
        enabled: Boolean,
        selection: String,
        source: LutLookSource,
    ): String {
        val title = LutCatalog.titleFor(selection)
        if (!enabled) return "Off · $title"
        if (selection == LutCatalog.AUTO || selection == LutCatalog.OFFICIAL_AUTO) {
            return "Auto · ${sourceTitle(source)}"
        }
        return title
    }

    /** iOS `LUTResolver.autoCaption`; [noLook] is what the app says when Auto applies no cube. */
    fun autoCaption(source: LutLookSource, noLook: String, cameraLooks: List<LutEntry> = emptyList()): String =
        when (source) {
            LutLookSource.Off -> noLook
            is LutLookSource.Asset -> {
                val title = sourceTitle(source)
                val official =
                    LutCatalog.officialCameraCubes.any { it.fileName == source.fileName } ||
                        cameraLooks.any { it.fileName == source.fileName }
                if (official) "Applying official $title" else "Applying $title"
            }
            is LutLookSource.Custom -> "Applying ${LutCatalog.displayName(source.fileName)}"
            is LutLookSource.Creative -> "Applying ${source.name}"
        }

    fun sourceTitle(source: LutLookSource): String =
        when (source) {
            LutLookSource.Off -> "Off"
            is LutLookSource.Asset ->
                source.title
                    ?: LutCatalog.officialBuiltInLooks.firstOrNull { it.fileName == source.fileName }?.title
                    ?: LutCatalog.officialCameraCubes.firstOrNull { it.fileName == source.fileName }?.title
                    ?: LutCatalog.displayName(source.fileName)
            is LutLookSource.Custom -> LutCatalog.displayName(source.fileName)
            is LutLookSource.Creative -> source.name
        }

    /** Manual conversion changes the cube's exposure math, never source metering metadata. */
    fun exposureColorMode(source: LutLookSource, sourceColorMode: Int): Int =
        (source as? LutLookSource.Asset)?.inputTransfer?.colorMode ?: sourceColorMode

    private fun autoCameraLook(colorMode: Int, cameraLooks: List<LutEntry>): LutLookSource? {
        if (colorMode < 0) return null
        val transfer = MonitorTransfer.fromColorMode(colorMode)
        val entry = cameraLooks.firstOrNull { it.inputTransfer == transfer && it.fileName != null } ?: return null
        return LutLookSource.Asset(entry.fileName!!, entry.inputTransfer, entry.title)
    }

    /** DJI/official log conversions and log-specific custom slots. Creative and generic Custom stay. */
    fun isTechnicalLogSelection(selection: String): Boolean =
        when (selection) {
            LutCatalog.AUTO,
            LutCatalog.OFFICIAL_AUTO,
            "officialDLog",
            "officialDLog2",
            "djiDLog",
            "djiDLog2",
            "djiDLogM",
            "djiAction6DLogM",
            "customDLog",
            "customDLog2",
            -> true
            else -> false
        }
}
