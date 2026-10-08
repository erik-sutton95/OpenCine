package com.opencapture.opencine.appkit

public data class MonitorDeliveryFileFacts(public val filename: String, public val sizeBytes: Long?)
public data class MonitorDeliverySelectionFacts(public val files: List<MonitorDeliveryFileFacts>,
    public val cachedCount: Int?, public val connected: Boolean?) {
    public val hasDeliverable: Boolean get() = (cachedCount ?: 0) > 0 || (connected == true && files.isNotEmpty())
}
public data class MonitorDeliveryChoice<V>(public val id: String, public val label: String, public val value: V)
public class MonitorDeliveryExportOptions<C, F>(
    public val curves: List<MonitorDeliveryChoice<C>>, public val formats: List<MonitorDeliveryChoice<F>>,
    public val lutAvailable: () -> Boolean?, public val convertLogAvailable: () -> Boolean?,
    public val lutLabel: () -> String?, public val convertHelp: String, public val convertUnavailableHelp: String,
    public val bakeExposureAvailable: () -> Boolean?, public val formatsForRemoteUpload: Boolean?,
    public val filename: (MonitorDeliveryExportConfiguration<C, F>) -> String?,
) {
    public constructor(curves: List<MonitorDeliveryChoice<C>>, formats: List<MonitorDeliveryChoice<F>>,
        lutAvailable: () -> Boolean?, convertLogAvailable: () -> Boolean?, lutLabel: () -> String?,
        convertHelp: String, convertUnavailableHelp: String,
        filename: (MonitorDeliveryExportConfiguration<C, F>) -> String?) :
        this(curves, formats, lutAvailable, convertLogAvailable, lutLabel, convertHelp,
            convertUnavailableHelp, { true }, true, filename)
}
public data class MonitorDeliveryProject<P>(public val id: String, public val name: String,
    public val uploadable: Boolean?, public val payload: P)
public data class MonitorDeliveryProjectListing<X, P>(public val context: X, public val projects: List<MonitorDeliveryProject<P>>)
public data class MonitorDeliveryRemoteFacts(public val configured: Boolean?, public val connected: Boolean?,
    public val onCameraNetwork: Boolean?, public val savedProjectID: String?, public val savedProjectName: String?)
public data class MonitorDeliveryRemotePresentation(public val displayName: String, public val progressCaption: String)
public class MonitorDeliveryRemoteService<P, X, H>(
    public val presentation: MonitorDeliveryRemotePresentation,
    public val observe: () -> MonitorDeliveryRemoteFacts,
    public val load: suspend () -> MonitorDeliveryProjectListing<X, P>,
    public val create: suspend (String, X) -> MonitorDeliveryProject<P>,
    public val persist: (MonitorDeliveryProject<P>, X) -> Unit,
    public val internet: MonitorDeliveryInternetService<H>, public val transfer: (H) -> H?,
)
public data class MonitorDeliveryPreparedRequest<C, F, H>(public val destination: MonitorDeliveryDestination,
    public val configuration: MonitorDeliveryExportConfiguration<C, F>?,
    public val action: MonitorDeliveryPostExportAction, public val internetLease: H?)
