package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.MonitorTransfer
import java.io.File

/** The picker tab a look sits on: the camera's official cubes (and camera looks), creative looks, imported cubes. */
enum class LutCategory {
    CAMERA,
    CREATIVE,
    CUSTOM,
}

data class LutEntry(
    val id: String,
    val title: String,
    val category: LutCategory,
    val fileName: String? = null,
    /** Declared cube input, independent of the transfer carried by the source frame. */
    val inputTransfer: MonitorTransfer? = null,
    val caption: String? = null,
)

/** Injected camera looks plus shared creative/custom catalogs and legacy selection compatibility. */
object LutCatalog {
    const val ASSET_DIRECTORY = "luts"
    const val CUSTOM_DIRECTORY = "luts"
    const val AUTO = "auto"
    const val OFF = "off"
    const val OFFICIAL_AUTO = "djiAuto"
    const val PHOTO_REC709_CAPTION = "Photo live view is Rec.709. Log conversions are off"

    private const val CUSTOM_PREFIX = "custom:"
    private const val ASSET_PREFIX = "asset:"

    val auto: LutEntry = LutEntry(AUTO, "Auto", LutCategory.CAMERA)
    var cameraLooks: List<LutEntry> = emptyList()
        private set

    /** Installed once by the app, alongside its backend and identity (empty: the official cubes alone). */
    fun configureCameraLooks(entries: List<LutEntry>) {
        require(entries.all {
            it.category == LutCategory.CAMERA && it.id.startsWith("camera:") &&
                it.fileName?.let { name -> isSafeFileName(name) && isCubeFileName(name) } == true
        })
        require(entries.map { it.id }.distinct().size == entries.size)
        cameraLooks = entries.toList()
    }

    fun cameraEntries(assetFileNames: Collection<String>, looks: List<LutEntry> = cameraLooks): List<LutEntry> =
        listOf(auto) + looks.filter { entry -> assetFileNames.any { it == entry.fileName } }

    fun normalizedSelection(id: String): String =
        if (id.isBlank() || id == OFFICIAL_AUTO) AUTO else id

    val officialAuto: LutEntry = LutEntry(OFFICIAL_AUTO, "Auto", LutCategory.CAMERA)

    val creative: List<LutEntry> =
        listOf(
            LutEntry("creativeMono", "Mono", LutCategory.CREATIVE),
            LutEntry("creativeContrast", "Contrast", LutCategory.CREATIVE),
            LutEntry("creativeWarm", "Warm", LutCategory.CREATIVE),
            LutEntry("creativeCool", "Cool", LutCategory.CREATIVE),
        )

    fun creativeName(id: String): String? = creative.firstOrNull { it.id == id }?.title

    /** Legacy app-authored Rec.709 conversions: hidden; reserved so they do not appear as extras. */
    val officialBuiltInLooks: List<LutEntry> =
        listOf(
            LutEntry(
                "officialDLog",
                "D-Log → Rec.709",
                LutCategory.CAMERA,
                "DJI_Pocket4P_DLog_Rec709_33.cube",
            ),
            LutEntry(
                "officialDLog2",
                "D-Log2 → Rec.709",
                LutCategory.CAMERA,
                "DJI_Pocket4P_DLog2_Rec709_33.cube",
            ),
        )

    /** Manufacturer Rec.709 cubes (`OfficialDJILUT` on iOS). */
    val officialCameraCubes: List<LutEntry> =
        listOf(
            LutEntry(
                "djiDLog",
                "D-Log → Rec.709",
                LutCategory.CAMERA,
                "DJI_Official_Pocket4P_DLog_Rec709_33.cube",
            ),
            LutEntry(
                "djiDLog2",
                "D-Log2 → Rec.709",
                LutCategory.CAMERA,
                "DJI_Official_Pocket4P_DLog2_Rec709_33.cube",
            ),
            LutEntry(
                "djiDLogM",
                "D-Log M → Rec.709",
                LutCategory.CAMERA,
                "DJI_Official_Nano_DLogM_Rec709_33.cube",
            ),
            LutEntry(
                "djiAction6DLogM",
                "Action 6 D-Log M → Rec.709",
                LutCategory.CAMERA,
                "DJI_Official_Action6_DLogM_Rec709_33.cube",
            ),
        )

    fun assetPath(fileName: String): String = "$ASSET_DIRECTORY/$fileName"

    fun customDirectory(filesDir: File): File = File(filesDir, CUSTOM_DIRECTORY)

    fun customId(fileName: String): String = "$CUSTOM_PREFIX$fileName"

    fun customFileName(id: String): String? =
        id.takeIf { it.startsWith(CUSTOM_PREFIX) }?.removePrefix(CUSTOM_PREFIX)

    fun isCubeFileName(name: String): Boolean = name.endsWith(".cube", ignoreCase = true)

    fun displayName(fileName: String): String =
        if (isCubeFileName(fileName)) fileName.dropLast(5) else fileName

    /** Rejects path components so a hostile name cannot escape the library directory. */
    fun isSafeFileName(name: String): Boolean =
        name.isNotEmpty() &&
            name == File(name).name &&
            '/' !in name &&
            '\\' !in name &&
            ':' !in name

    fun normalizedCubeFileName(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed != File(trimmed).name) return null
        if (trimmed == "." || trimmed == "..") return null
        val fileName = if (isCubeFileName(trimmed)) trimmed else "$trimmed.cube"
        return fileName.takeIf { isSafeFileName(it) }
    }

    fun officialEntries(assetFileNames: Collection<String>, isPhotoLive: Boolean = false): List<LutEntry> {
        val cubes = assetFileNames.filter(::isCubeFileName)
        val reserved =
            (officialCameraCubes + officialBuiltInLooks)
                .mapNotNull { it.fileName?.lowercase() }
                .toSet()
        val presentOfficial =
            officialCameraCubes.filter { entry ->
                cubes.any { name -> name.equals(entry.fileName, ignoreCase = true) }
            }
        val extras =
            cubes
                .filter { name -> name.lowercase() !in reserved }
                .sortedBy { it.lowercase() }
                .map { extraAsset(it) }
        val all = listOf(officialAuto) + presentOfficial + extras
        if (!isPhotoLive) return all
        return all.filter { it.id == OFFICIAL_AUTO || it.id.startsWith(ASSET_PREFIX) }
    }

    fun storedCustom(fromFileNames: Collection<String>): List<LutEntry> =
        fromFileNames
            .filter { isCubeFileName(it) && isSafeFileName(it) }
            .sortedBy { it.lowercase() }
            .map { LutEntry(customId(it), displayName(it), LutCategory.CUSTOM, it) }

    fun titleFor(id: String): String {
        cameraLooks.firstOrNull { it.id == id }?.let { return it.title }
        val canonical = migratedToOfficialCatalog(id)
        if (canonical.isBlank()) return "Auto"
        if (canonical == AUTO || canonical == OFFICIAL_AUTO) return officialAuto.title
        officialCameraCubes.firstOrNull { it.id == canonical }?.let { return it.title }
        creative.firstOrNull { it.id == canonical }?.let { return it.title }
        customFileName(canonical)?.let { return displayName(it) }
        if (canonical.startsWith(ASSET_PREFIX)) return displayName(canonical.removePrefix(ASSET_PREFIX))
        return when (canonical) {
            "off" -> "Off"
            "customRec709" -> "Custom"
            "customDLog" -> "Custom D-Log"
            "customDLog2" -> "Custom D-Log2"
            "customFile" -> "Custom"
            else -> id
        }
    }

    fun categoryOf(id: String): LutCategory =
        when {
            customFileName(id) != null ||
                id == "customFile" ||
                id == "customRec709" ||
                id == "customDLog" ||
                id == "customDLog2" -> LutCategory.CUSTOM
            creative.any { it.id == id } -> LutCategory.CREATIVE
            else -> LutCategory.CAMERA
        }

    fun migratedToOfficialCatalog(id: String): String =
        when (id) {
            AUTO -> OFFICIAL_AUTO
            "officialDLog" -> "djiDLog"
            "officialDLog2" -> "djiDLog2"
            else -> id
        }

    fun matches(entry: LutEntry, selection: String): Boolean {
        if (entry.id == selection) return true
        val fileName = entry.fileName ?: return false
        return selection.equals(fileName, ignoreCase = true) ||
            selection.equals("$ASSET_PREFIX$fileName", ignoreCase = true)
    }

    private fun isOfficialId(id: String): Boolean =
        id == OFFICIAL_AUTO ||
            officialCameraCubes.any { it.id == id } ||
            id.startsWith(ASSET_PREFIX) ||
            officialCameraCubes.any { it.fileName.equals(id, ignoreCase = true) }

    private fun extraAsset(fileName: String): LutEntry =
        LutEntry(
            id = "$ASSET_PREFIX$fileName",
            title = displayName(fileName),
            category = LutCategory.CAMERA,
            fileName = fileName,
        )
}

/**
 * iOS `PlaybackLUTColor`. `nclx` is Rec.709 even for D-Log2; the shot profile
 * is `com.dji.camera.ColorGammaSxS` on the **original** take. LRF / XRF
 * proxies are Rec.709 even for log: pass `clip` only from the original.
 * That clip value wins. Live `@2` is the body's current SET, used only when
 * the original has no Keys atom.
 */
object PlaybackLutColor {
    fun bindsAutoLut(code: Int): Boolean =
        when (code) {
            CameraCommands.COLOR_DLOG, CameraCommands.COLOR_DLOG2, CameraCommands.COLOR_DLOG_M ->
                true
            // Camera looks (an I-Log conversion) bind Auto the same way.
            else -> LutCatalog.cameraLooks.any { it.inputTransfer?.colorMode == code }
        }

    fun resolve(live: Int, last: Int): Int = resolve(clip = -1, live = live, last = last)

    fun resolve(clip: Int, live: Int, last: Int): Int {
        if (clip >= 0) return clip
        val liveMode = live.takeIf { it >= 0 }
        val lastMode = last.takeIf { it >= 0 }
        if (lastMode != null && bindsAutoLut(lastMode)) {
            if (liveMode == null || !bindsAutoLut(liveMode)) return lastMode
        }
        return liveMode ?: lastMode ?: -1
    }
}
