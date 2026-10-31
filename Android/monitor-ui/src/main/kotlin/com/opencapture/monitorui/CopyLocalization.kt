package com.opencapture.monitorui

import java.util.Locale

/**
 * The languages the shared copy can be shown in.
 *
 * The English string is the key. Every copy constant keeps its English text as its identity, so a
 * missing translation falls back to the words the app already shows, and the contracts that pin
 * those words stay untouched: `Fixtures/playback-copy.tsv`, the parity tests and the Swift twin
 * (`MonitorPlaybackCopy` in `Sources/MonitorPresentation`) keep reading the English constants.
 *
 * A host that shows its own language picker provides [LocalCopyLanguage]; nothing here reads a
 * global preference store.
 */
public enum class CopyLanguage(val tag: String) {
    ENGLISH("en"),
    SIMPLIFIED_CHINESE("zh-Hans"),
    ;

    companion object {
        /**
         * The first preferred tag this catalog has a table for, else English.
         *
         * Matching is on the BCP 47 language subtag, so `zh-Hans`, `zh-Hans-CN` and `zh_Hans_CN`
         * all resolve. A traditional Chinese tag (`zh-Hant`, `zh-TW`, `zh-HK`, `zh-MO`) reads
         * English on purpose: those scripts are not translated yet, and showing the simplified
         * table there would be the wrong script rather than a missing translation.
         */
        fun resolve(preferredTags: List<String>): CopyLanguage {
            for (raw in preferredTags) {
                val tag = raw.replace('_', '-').lowercase(Locale.ROOT)
                if (tag == "en" || tag.startsWith("en-")) return ENGLISH
                if (tag != "zh" && !tag.startsWith("zh-")) continue
                val traditional =
                    tag.contains("hant") ||
                        tag.startsWith("zh-tw") ||
                        tag.startsWith("zh-hk") ||
                        tag.startsWith("zh-mo")
                return if (traditional) ENGLISH else SIMPLIFIED_CHINESE
            }
            return ENGLISH
        }

        /** What this process should show, from the device's current locale. */
        fun preferred(): CopyLanguage = resolve(listOf(Locale.getDefault().toLanguageTag()))
    }
}

/**
 * One language's translations, keyed by the English copy.
 *
 * A value, not a global: a test builds one from a literal table, the screens read
 * [CopyCatalog.bundled], and nothing depends on mutable state. [text] returns the English key
 * unchanged when the language or the entry is missing, so an untranslated label reads as English
 * rather than as an empty control.
 */
public class CopyCatalog(private val tables: Map<CopyLanguage, Map<String, String>>) {
    constructor(translations: Map<String, String>, language: CopyLanguage) :
        this(mapOf(language to translations))

    /** The translation of [english], or [english] itself when there is none. */
    fun text(english: String, language: CopyLanguage): String = tables[language]?.get(english) ?: english

    /** The languages this catalog carries a table for. */
    val languages: Set<CopyLanguage> get() = tables.keys

    /** Every row of [language], for diagnostics and for the style checks over translated text. */
    fun entries(language: CopyLanguage): Map<String, String> = tables[language] ?: emptyMap()

    /** The English keys with no entry for [language]. Empty means fully translated. */
    fun missingKeys(keys: Collection<String>, language: CopyLanguage): List<String> {
        val table = tables[language] ?: return keys.toList()
        return keys.filter { it !in table }
    }

    /**
     * Entries for [language] whose English key is not in [keys]. A row that stops matching means
     * the English copy was edited and the translation is now stale, which this surfaces instead of
     * leaving it silently unused.
     */
    fun unusedKeys(keys: Collection<String>, language: CopyLanguage): List<String> {
        val table = tables[language] ?: return emptyList()
        val known = keys.toSet()
        return table.keys.filter { it !in known }.sorted()
    }

    companion object {
        /** The catalog shipped with this library. */
        val bundled: CopyCatalog =
            CopyCatalog(mapOf(CopyLanguage.SIMPLIFIED_CHINESE to CopyTranslations.simplifiedChinese))
    }
}
