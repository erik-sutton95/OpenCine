package com.opencapture.opencine.nikon

/**
 * Stills picker ladders: the fallbacks a picker draws when the body has not advertised its own
 * enum. Twin of `StillPickerLadders` in `Sources/OpenCineNikon/NikonPickerLadders.swift`; both
 * suites read `Fixtures/nikon-picker-ladders.tsv`.
 */
object StillPickerLadders {
    val ISO_OPTIONS: List<String> =
        listOf(
            "100", "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000",
            "1250", "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000", "10000",
            "12800", "16000", "20000", "25600", "32000", "40000", "51200",
        )

    val SHUTTER_OPTIONS: List<String> =
        listOf(
            "30s", "15s", "8s", "4s", "2s", "1s", "1/2", "1/4", "1/8", "1/15", "1/30", "1/60",
            "1/125", "1/200", "1/250", "1/500", "1/1000", "1/2000", "1/4000", "1/8000", "Bulb",
        )

    /** One decimal place throughout, matching the body's f-number readout. */
    val IRIS_OPTIONS: List<String> =
        listOf(
            "f/1.2", "f/1.4", "f/1.8", "f/2.0", "f/2.2", "f/2.5", "f/2.8", "f/3.2", "f/3.5",
            "f/4.0", "f/4.5", "f/5.0", "f/5.6", "f/6.3", "f/7.1", "f/8.0", "f/9.0", "f/10.0",
            "f/11.0", "f/13.0", "f/14.0", "f/16.0", "f/18.0", "f/20.0", "f/22.0",
        )

    /**
     * Release-mode fallback in the body's release order (Single, CL, CH, CH+, then the high-speed
     * positions), minus the dial-only Quick position and the body's Self-timer, which the Built-in
     * Timer tab owns (#274). A connected body's advertised set always wins over this.
     */
    val DRIVE_OPTIONS: List<String> =
        listOf(
            "Single", "Continuous L", "Continuous H", "Continuous H+",
            "C15", "C30", "C60", "C120",
        )

    /** The in-app countdown ladder. */
    val APP_TIMER_OPTIONS: List<String> =
        listOf("Off", "1s", "2s", "3s", "5s", "10s", "20s", "30s", "60s")

    val FOCUS_MODE_OPTIONS: List<String> = listOf("AF-S", "AF-C", "AF-A", "MF")

    /**
     * AF-area modes. `3D tracking` is spelled the way the body spells it so it never reads as the
     * adjacent subject-detection tab; the two are separate Nikon settings (#274).
     */
    val FOCUS_AREA_OPTIONS: List<String> =
        listOf(
            "Pinpoint", "Single", "Dyn-S", "Dyn-M", "Dyn-L", "Wide-S", "Wide-L",
            "3D tracking", "Auto",
        )

    val FOCUS_SUBJECT_OPTIONS: List<String> =
        listOf("Off", "Auto", "People", "Animal", "Vehicle", "Bird", "Airplane")

    /**
     * MODE fallback. No user banks: a body with U1/U2/U3 advertises them in its
     * `ExposureProgramMode` enum, and inferring them offered a Zf three modes it lacks (#274).
     */
    val MODE_OPTIONS: List<String> = listOf("Auto", "P", "S", "A", "M")

    /** A user bank's inner program. */
    val USER_MODE_OPTIONS: List<String> = listOf("P", "S", "A", "M")

    val METER_OPTIONS: List<String> = listOf("Matrix", "Center", "Spot", "Highlight")

    /** The full picture-control set: built-ins, creative looks, custom and cloud slots. */
    val PICTURE_OPTIONS: List<String> =
        listOf(
            "Auto", "Standard", "Neutral", "Vivid", "Monochrome", "Portrait", "Landscape",
            "Flat", "Flat Mono", "Deep Tone Mono", "Rich Tone Portrait",
            "Dream", "Morning", "Pop", "Sunday", "Somber", "Drama", "Silence", "Bleach",
            "Melancholic", "Pure", "Denim", "Toy", "Sepia", "Blue", "Red", "Pink",
            "Charcoal", "Graphite", "Binary", "Carbon",
        ) + (1..9).map { "Custom $it" } + (1..9).map { "Cloud $it" }

    /** Sensor-crop image areas. */
    val AREA_OPTIONS: List<String> = listOf("FX", "DX", "1:1", "16:9")

    val SIZE_OPTIONS: List<String> = listOf("Size L", "Size M", "Size S")

    /** The compression ladder minus the ★ size-priority variants and TIFF. */
    val QUALITY_OPTIONS: List<String> =
        listOf(
            "RAW", "RAW+JPEG Fine", "RAW+JPEG Normal", "RAW+JPEG Basic", "JPEG Fine",
            "JPEG Normal", "JPEG Basic",
        )

    /** NEF (RAW) recording compression. */
    val NEF_OPTIONS: List<String> =
        listOf("High efficiency", "High efficiency★", "Lossless compression")

    /**
     * The DRIVE drum's options: the body's advertised set in release order ([DRIVE_OPTIONS]),
     * minus the Self-timer and Quick positions this drum does not own. Advertised modes this build
     * does not know follow the ones it can order, so a newer body's position stays reachable.
     * Twin of the Swift `StillDriveMode.driveDrumOptions`.
     */
    fun driveDrumOptions(advertised: List<String>): List<String> {
        val offered = advertised.filterNot { it == "Self-timer" || it == "Quick" }
        if (offered.isEmpty()) return emptyList()
        val known = DRIVE_OPTIONS.filter(offered::contains)
        return known + offered.filterNot(DRIVE_OPTIONS::contains)
    }
}
