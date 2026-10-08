package com.opencapture.opencine.appkit

public object MonitorDeliveryFileNaming {
    public fun <C, F> filename(original: String, configuration: MonitorDeliveryExportConfiguration<C, F>,
        formatExtension: String, transformToken: String? = null): String {
        val lastDot = original.lastIndexOf('.'); val stem = if (lastDot > 0) original.substring(0, lastDot) else original
        if (configuration.convertLog && transformToken != null) return "$stem.$transformToken.$formatExtension"
        if (!configuration.bakeLUT && !configuration.convertLog) return original
        return "$stem.$formatExtension"
    }
}
public data class MonitorDeliveryMetadataFacts(public val filename: String, public val captureDate: String?, public val sizeBytes: Long?)
public object MonitorDeliveryMetadataSummary {
    public fun text(files: List<MonitorDeliveryMetadataFacts>, formatBytes: (Long) -> String): String = files.joinToString("\n") {
        "${it.filename} · ${it.captureDate ?: "unknown date"} · ${it.sizeBytes?.let(formatBytes) ?: "unknown size"}"
    }
}
public data class MonitorDeliveryMetadataSelection(public val included: Boolean, public val bakedLook: Boolean,
    public val bakedExposure: Boolean, public val convertedCurve: Boolean) {
    public constructor(configuration: MonitorDeliveryExportConfiguration<*, *>) : this(configuration.includeMetadata,
        configuration.includeMetadata && !configuration.convertLog && configuration.bakeLUT,
        configuration.includeMetadata && !configuration.convertLog && configuration.bakeLUT && configuration.bakeLUTExposure,
        configuration.includeMetadata && configuration.convertLog)
}
