package com.opencapture.monitorui

import androidx.compose.runtime.Immutable

/** Host values and typed actions only; no file, route, credential or delivery owner. */
@Immutable
data class MonitorMediaDeliveryValue(
    val step: Step,
    val title: String = "Share",
    val selectionLabel: String,
    val notices: List<Notice> = emptyList(),
    val destinations: List<Destination> = emptyList(),
    val upcoming: List<String> = emptyList(),
    val service: Service? = null,
    val export: Export? = null,
    val footer: Footer? = null,
    val status: String? = null,
) {
    enum class Step { DESTINATION, OPTIONS }
    enum class Option { CONVERT_LOG, BAKE_LUT, BAKE_EXPOSURE, INCLUDE_METADATA, REUPLOAD }
    enum class Selection { OUTPUT_CURVE, FORMAT, POST_EXPORT, PROJECT }
    sealed interface Action {
        data object Close : Action
        data object Back : Action
        data object Begin : Action
        data object HopToInternet : Action
        data object RetryProjects : Action
        data object CreateProject : Action
        data class Destination(val id: String) : Action
        data class Option(val option: MonitorMediaDeliveryValue.Option, val on: Boolean) : Action
        data class Selection(val selection: MonitorMediaDeliveryValue.Selection, val id: String) : Action
    }
    @Immutable data class Choice(val id: String, val label: String)
    @Immutable data class Notice(val text: String, val accented: Boolean = false)
    @Immutable data class Destination(val id: String, val title: String, val subtitle: String, val enabled: Boolean)
    @Immutable data class Toggle(val title: String, val help: String, val isOn: Boolean, val enabled: Boolean = true)
    @Immutable data class Choices(val title: String, val help: String? = null, val options: List<Choice>, val selectedID: String?)
    @Immutable data class Export(
        val filename: String? = null,
        val convertLog: Toggle? = null,
        val outputCurve: Choices? = null,
        val bakeLUT: Toggle? = null,
        val bakeExposure: Toggle? = null,
        val format: Choices? = null,
        val includeMetadata: Toggle? = null,
        val reupload: Toggle? = null,
    )
    sealed interface Service {
        @Immutable data class InternetGate(val heading: String, val message: String, val busy: Boolean,
            val busyTitle: String = "Switching networks…") : Service
        @Immutable data class Projects(val heading: String, val help: String, val signInNotice: String? = null,
            val loading: Boolean, val error: String? = null, val choices: List<Choice>?, val selectedID: String?,
            val allowsCreation: Boolean = true, val selectedLabel: String? = null) : Service {
            /** A known listed ID wins over the supplied label outside the offered choices. */
            val selectedProjectLabel: String?
                get() = choices?.firstOrNull { it.id == selectedID }?.label ?: selectedLabel
        }
    }
    @Immutable data class Footer(val summary: String? = null, val postExport: Choices? = null,
        val actionTitle: String, val enabled: Boolean)
}

/** Progress copy and weighting are supplied by the host. */
@Immutable
data class MonitorMediaDeliveryProgressValue(val status: String, val batch: String? = null,
    val fraction: Double, val preparing: Boolean, val showsProgress: Boolean = !preparing)
