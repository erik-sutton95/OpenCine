package com.opencapture.opencine.appkit

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID

/** Filesystem discovery grants ownership only to real child directories and exact retirement names. */
internal object MonitorMediaCacheNamespaces {
    fun names(parent: File): List<String> = parent.listFiles().orEmpty().mapNotNull { child ->
        if (!isDirectory(child)) return@mapNotNull null
        val name = child.name
        if (!name.startsWith(".")) return@mapNotNull name.takeIf(::validNamespace)
        for (prefix in listOf(".clearing-", ".retiring-")) {
            if (!name.startsWith(prefix)) continue
            val encoded = name.removePrefix(prefix)
            if (encoded.length <= 37 || encoded[encoded.length - 37] != '-') return@mapNotNull null
            val suffix = encoded.takeLast(36)
            if (!runCatching { UUID.fromString(suffix).toString().equals(suffix, ignoreCase = true) }.getOrDefault(false)) {
                return@mapNotNull null
            }
            return@mapNotNull encoded.dropLast(37).takeIf(::validNamespace)
        }
        null
    }.distinct().sorted()

    fun isDirectory(file: File): Boolean = Files.isDirectory(file.toPath(), LinkOption.NOFOLLOW_LINKS)
    private fun validNamespace(name: String): Boolean = name.isNotEmpty() && !name.startsWith(".") &&
        '/' !in name && '\\' !in name
}
