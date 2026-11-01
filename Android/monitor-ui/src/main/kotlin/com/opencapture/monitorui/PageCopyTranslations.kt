package com.opencapture.monitorui

/**
 * Copy for the shared pages outside playback, keyed by the English text.
 *
 * A missing row reads English, so a page never shows a blank label.
 */
internal object PageCopyTranslations {
    val simplifiedChinese: Map<String, String> =
        mapOf(
            "Pair a camera" to "\u914d\u5bf9\u76f8\u673a",
            "TARGET" to "\u76ee\u6807",
            "Report a problem" to "\u53cd\u9988\u95ee\u9898",
            "Continue" to "\u7ee7\u7eed",
            "STEP %1\$d OF %2\$d" to "\u7b2c %1\$d \u6b65\uff0c\u5171 %2\$d \u6b65",
            "Pairing help and diagnostics" to "\u914d\u5bf9\u5e2e\u52a9\u4e0e\u8bca\u65ad",
            "Share Diagnostics" to "\u5206\u4eab\u8bca\u65ad\u4fe1\u606f",
            "Watch a feed" to "\u89c2\u770b\u753b\u9762",
        )
}

private val PAGE_CATALOG: CopyCatalog =
    CopyCatalog(mapOf(CopyLanguage.SIMPLIFIED_CHINESE to PageCopyTranslations.simplifiedChinese))

/** [english] in the operator's language, for shared pages built outside a composable. */
internal fun pageText(english: String): String = PAGE_CATALOG.text(english, CopyLanguage.preferred())
