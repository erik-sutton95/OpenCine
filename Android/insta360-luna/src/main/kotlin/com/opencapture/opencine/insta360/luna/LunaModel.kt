package com.opencapture.opencine.insta360.luna

/**
 * A Luna body this integration supports (Swift twin `LunaModel`, same members): the model string
 * it reports in device-information option 48, its name for the operator and what its lenses can
 * do. Insta360's Bluetooth service BE80 is shared by more of its cameras, so only a body listed in
 * [supported] gets the Luna profile.
 *
 * Sources: Luna Ultra is hardware-qualified (owner, firmware 1.1.15 to 1.2.7). Luna Pro is
 * untested: its model string and lens figures come from Insta360's public Luna Pro manual
 * ("Insta360 Luna Pro"; one 1-inch main camera, no telephoto; common focal lengths 1x, 2x and 4x,
 * 4x maximum) and the luna_ultra-vs-luna_pro compare page, not from a camera.
 */
public data class LunaModel(
    /** What the camera reports in option 48, for example "Insta360 Luna Ultra". */
    public val reportedName: String,
    /** The operator's name for the body, for example "Luna Ultra". */
    public val name: String,
    /**
     * A separate telephoto camera (Ultra's 3x). Without one, every factor past 1x is a crop of the
     * main camera, so the monitor shows no tele stop or "TELE" caption.
     */
    public val hasTelephoto: Boolean,
    /** The highest zoom factor the body takes. */
    public val maximumZoom: Double,
    /** The zoom presets the official app offers, ascending, 1x first. */
    public val zoomPresets: List<Double>,
    /** Whether the body has been tried on hardware with this integration. */
    public val hardwareQualified: Boolean,
) {
    /** The factors a lens gives without a crop: 1x, and 3x on a body with a telephoto. */
    public val opticalZoomStops: List<Double> get() = if (hasTelephoto) listOf(1.0, 3.0) else listOf(1.0)

    public companion object {
        /** Main camera and 3x telephoto; presets as the official app offered them on fw 1.1.15. */
        public val ULTRA: LunaModel = LunaModel(
            "Insta360 Luna Ultra", "Luna Ultra", hasTelephoto = true, maximumZoom = 15.0,
            zoomPresets = listOf(1.0, 2.0, 3.0, 6.0, 15.0), hardwareQualified = true,
        )

        /** The Ultra's main camera without the telephoto. Untested: no Luna Pro has connected yet. */
        public val PRO: LunaModel = LunaModel(
            "Insta360 Luna Pro", "Luna Pro", hasTelephoto = false, maximumZoom = 4.0,
            zoomPresets = listOf(1.0, 2.0, 4.0), hardwareQualified = false,
        )

        /** Every body the integration connects to. */
        public val supported: List<LunaModel> = listOf(ULTRA, PRO)

        /** The name for a Luna whose body is not known yet: a Bluetooth sighting carries no model. */
        public const val FAMILY_NAME: String = "Luna"

        /** [FAMILY_NAME] as a camera reports it. */
        public const val FAMILY_REPORTED_NAME: String = "Insta360 Luna"

        /**
         * The supported body that reported [reported]. The known names are compared without case,
         * surrounding or repeated spaces and the "Insta360" prefix, so "Insta360 Luna Pro" and
         * "Luna Pro" are the Pro. Null for any other camera, including a Luna variant not listed in
         * [supported]: its wire behaviour is unverified, so it is refused rather than guessed.
         */
        public fun identify(reported: String): LunaModel? {
            val key = comparable(reported)
            if (key.isEmpty()) return null
            return supported.firstOrNull { comparable(it.reportedName) == key }
        }

        /** Whether [reported] names a Luna at all ("Insta360 Luna ..."), supported or not. */
        public fun isLunaFamily(reported: String): Boolean {
            val key = comparable(reported)
            return key == "luna" || key.startsWith("luna ")
        }

        /** "Insta360 Luna Ultra and Luna Pro": the supported bodies for operator copy. */
        public val supportedNames: String get() {
            val names = supported.map { it.name }
            val list = if (names.size < 2) names.joinToString("") else names.dropLast(1).joinToString(", ") + " and " + names.last()
            return "Insta360 $list"
        }

        /**
         * The operator copy for a camera the gate refused: which camera it is and what [appName]
         * supports. An unknown Luna variant is named as one, so its owner can report the model.
         */
        public fun unsupportedMessage(reported: String, appName: String): String {
            val model = reported.trim().split(WHITESPACE).filter { it.isNotEmpty() }.joinToString(" ")
            val supports = "$appName currently supports the $supportedNames."
            return when {
                model.isEmpty() -> "This camera did not report its model. $supports"
                isLunaFamily(model) -> "This camera is $model, a Luna model $appName does not support yet. $supports"
                else -> "This camera is $model. $supports"
            }
        }

        private val WHITESPACE = Regex("\\s+")

        private fun comparable(value: String): String {
            val words = value.lowercase().trim().split(WHITESPACE).filter { it.isNotEmpty() }.toMutableList()
            if (words.firstOrNull() == "insta360") words.removeAt(0)
            return words.joinToString(" ")
        }
    }
}
