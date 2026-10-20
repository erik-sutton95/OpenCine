package com.opencapture.opencine.appkit

import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Popup options/project lookup/approved route lease. The existing DeliveryModel owns the batch. */
public class MonitorDeliveryPreparationModel<C, F, P, X, H>(
    scope: CoroutineScope,
    private val observeSelection: () -> MonitorDeliverySelectionFacts,
    configuration: MonitorDeliveryExportConfiguration<C, F>?,
    public val exportOptions: MonitorDeliveryExportOptions<C, F>?,
    private val remote: MonitorDeliveryRemoteService<P, X, H>? = null,
    preferredDestination: MonitorDeliveryDestination? = null,
    private val sourceCurrent: () -> Boolean,
    private val beforeInternetHop: (suspend () -> Unit)?,
    private val sleep: suspend (Duration) -> Unit = { delay(it) },
) {
    public constructor(scope: CoroutineScope, observeSelection: () -> MonitorDeliverySelectionFacts,
        configuration: MonitorDeliveryExportConfiguration<C, F>?,
        exportOptions: MonitorDeliveryExportOptions<C, F>?,
        remote: MonitorDeliveryRemoteService<P, X, H>? = null,
        preferredDestination: MonitorDeliveryDestination? = null,
        sourceCurrent: () -> Boolean, sleep: suspend (Duration) -> Unit = { delay(it) }) :
        this(scope, observeSelection, configuration, exportOptions, remote, preferredDestination,
            sourceCurrent, null, sleep)
    public enum class Step { DESTINATION, OPTIONS }
    public data class State<C, F, P, X>(
        public val step: Step, public val destination: MonitorDeliveryDestination?,
        public val configuration: MonitorDeliveryExportConfiguration<C, F>?,
        public val action: MonitorDeliveryPostExportAction = MonitorDeliveryPostExportAction.SYSTEM_SHARE,
        public val selection: MonitorDeliverySelectionFacts, public val remoteFacts: MonitorDeliveryRemoteFacts? = null,
        public val listing: MonitorDeliveryProjectListing<X, P>? = null, public val projectsLoading: Boolean = false,
        public val projectsError: String? = null, public val selectedProjectID: String? = null,
        public val hopping: Boolean = false,
    )
    private val owner = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val mutable = MutableStateFlow(State<C, F, P, X>(
        if (preferredDestination == null) Step.DESTINATION else Step.OPTIONS,
        preferredDestination, configuration, selection = observeSelection()))
    public val state: StateFlow<State<C, F, P, X>> = mutable.asStateFlow()
    private var epoch = UUID.randomUUID(); private var closed = false; private var begun = false
    private var projectsRequest: UUID? = null; private var hopRequest: UUID? = null
    private var projectsTask: Job? = null; private var hopTask: Job? = null; private var pollingTask: Job? = null
    private var lease: H? = null
    /** The export options the selection can use: none when every file is a still (ZIB-469). */
    public val clipExportOptions: MonitorDeliveryExportOptions<C, F>? get() = if (state.value.selection.allStills) null else exportOptions
    public val remotePresentation: MonitorDeliveryRemotePresentation? get() = remote?.presentation
    /** Re-upload is a choice only where the remote skips already uploaded records. */
    public val offersReupload: Boolean get() = state.value.destination == MonitorDeliveryDestination.REMOTE_UPLOAD && remote?.skipsUploaded == true
    public val selectedProject: MonitorDeliveryProject<P>? get() = state.value.listing?.projects?.firstOrNull { it.id == state.value.selectedProjectID }
    public val uploadableProjects: List<MonitorDeliveryProject<P>> get() = state.value.listing?.projects?.filter { it.uploadable == true }.orEmpty()
    public val internetGate: Boolean get() = state.value.destination == MonitorDeliveryDestination.REMOTE_UPLOAD && state.value.remoteFacts?.onCameraNetwork == true
    public val canContinue: Boolean get() {
        val value = state.value
        if (value.destination == null || !value.selection.hasDeliverable || value.hopping || closed) return false
        if (exportOptions != null && value.configuration == null) return false
        value.configuration?.let {
            if (it.bakeLUT && clipExportOptions?.lutAvailable?.invoke() != true) return false
            if (it.convertLog && clipExportOptions?.convertLogAvailable?.invoke() != true) return false
        }
        return value.destination != MonitorDeliveryDestination.REMOTE_UPLOAD || (value.remoteFacts?.connected == true &&
            (selectedProject?.uploadable == true || value.remoteFacts.savedProjectID != null || value.remoteFacts.onCameraNetwork == true))
    }
    public fun destinationEnabled(value: MonitorDeliveryDestination): Boolean = !closed && state.value.selection.hasDeliverable &&
        (value == MonitorDeliveryDestination.NATIVE_SHARE || (remote != null && state.value.remoteFacts?.configured == true && state.value.remoteFacts?.connected == true))
    public fun start() {
        if (begun || closed) return
        begun = true; val captured = epoch
        if (!current(captured)) return
        refresh(captured)
        if (!current(captured)) return
        val lut = clipExportOptions?.lutAvailable?.invoke(); if (!current(captured)) return
        val convert = clipExportOptions?.convertLogAvailable?.invoke(); if (!current(captured)) return
        if (!publish(captured) { it.copy(configuration = it.configuration?.copy(
                bakeLUT = it.configuration.bakeLUT && lut == true, convertLog = it.configuration.convertLog && convert == true),
                selectedProjectID = it.remoteFacts?.savedProjectID) }) return
        val next = owner.launch(start = CoroutineStart.LAZY) {
            while (current(captured)) {
                refresh(captured); if (!current(captured)) return@launch
                val value = state.value
                if (value.step == Step.OPTIONS && value.destination == MonitorDeliveryDestination.REMOTE_UPLOAD &&
                    value.remoteFacts?.configured == true && value.remoteFacts.connected == true && value.remoteFacts.onCameraNetwork == false &&
                    value.listing == null && !value.projectsLoading && value.projectsError == null) loadProjects()
                sleep(1.seconds)
            }
        }
        pollingTask = next; if (current(captured)) next.start() else { pollingTask = null; next.cancel() }
    }
    public fun selectDestination(value: MonitorDeliveryDestination) {
        val captured = epoch
        if (!current(captured) || !destinationEnabled(value) || !current(captured)) return
        if (!publish(captured) { it.copy(destination = value, step = Step.OPTIONS) }) return
        if (value == MonitorDeliveryDestination.REMOTE_UPLOAD) loadProjects()
    }
    public fun back() {
        if (closed) return
        val captured = epoch
        retireProjects(); if (current(captured) && projectsRequest == null) publish(captured) { it.copy(step = Step.DESTINATION) }
    }
    public fun setConvertLog(value: Boolean) {
        val captured = epoch
        if (!current(captured) || (value && clipExportOptions?.convertLogAvailable?.invoke() != true) || !current(captured)) return
        publish(captured) { it.copy(configuration = it.configuration?.copy(convertLog = value, bakeLUT = if (value) false else it.configuration.bakeLUT)) }
    }
    public fun setBakeLUT(value: Boolean) {
        val captured = epoch
        if (!current(captured) || (value && clipExportOptions?.lutAvailable?.invoke() != true) || !current(captured)) return
        publish(captured) { it.copy(configuration = it.configuration?.copy(bakeLUT = value, convertLog = if (value) false else it.configuration.convertLog)) }
    }
    public fun setAction(value: MonitorDeliveryPostExportAction) { if (!closed) publish(epoch) { it.copy(action = value) } }
    public fun updateConfiguration(change: (MonitorDeliveryExportConfiguration<C, F>) -> MonitorDeliveryExportConfiguration<C, F>) {
        val captured = epoch; if (!current(captured)) return
        val configuration = state.value.configuration?.let(change) ?: return
        if (current(captured)) publish(captured) { it.copy(configuration = configuration) }
    }
    public fun selectProject(id: String) {
        val captured = epoch; if (!current(captured)) return
        val listing = state.value.listing ?: return
        val project = listing.projects.firstOrNull { it.id == id && it.uploadable == true } ?: return
        remote?.persist?.invoke(project, listing.context)
        if (publish(captured) { it.copy(selectedProjectID = id) }) refresh(captured)
    }
    public fun loadProjects() {
        val captured = epoch; val service = remote ?: return
        if (!current(captured)) return
        refresh(captured)
        if (!current(captured) || state.value.destination != MonitorDeliveryDestination.REMOTE_UPLOAD || state.value.remoteFacts?.onCameraNetwork != false) return
        val request = UUID.randomUUID(); projectsRequest = request
        val old = projectsTask; projectsTask = null; old?.cancel()
        if (!acceptsProjects(captured, request)) return
        if (!publish(captured, request) { it.copy(projectsLoading = true, projectsError = null) }) return
        val next = owner.launch(start = CoroutineStart.LAZY) {
            if (!acceptsProjects(captured, request)) return@launch
            try {
                val result = service.load(); if (!acceptsProjects(captured, request)) return@launch
                val selected = state.value.selectedProjectID ?: state.value.remoteFacts?.savedProjectID ?: result.projects.firstOrNull()?.id
                result.projects.firstOrNull { it.id == selected }?.let { project ->
                    service.persist(project, result.context); if (!acceptsProjects(captured, request)) return@launch
                }
                if (publish(captured, request) { it.copy(listing = result, selectedProjectID = selected, projectsLoading = false) }) projectsTask = null
            } catch (failure: Throwable) {
                if (publish(captured, request) { it.copy(projectsError = failure.message ?: failure.toString(), projectsLoading = false) }) projectsTask = null
            }
        }
        if (!acceptsProjects(captured, request)) { next.cancel(); return }
        projectsTask = next; next.start()
    }
    public fun createProject(rawName: String) {
        val name = rawName.trim(); val captured = epoch; val service = remote ?: return
        val context = state.value.listing?.context ?: return
        if (name.isEmpty() || !current(captured)) return
        val request = UUID.randomUUID(); projectsRequest = request
        val old = projectsTask; projectsTask = null; old?.cancel()
        if (!publish(captured, request) { it.copy(projectsLoading = true, projectsError = null) }) return
        val next = owner.launch(start = CoroutineStart.LAZY) {
            if (!acceptsProjects(captured, request)) return@launch
            try {
                val project = service.create(name, context); if (!acceptsProjects(captured, request)) return@launch
                service.persist(project, context); if (!acceptsProjects(captured, request)) return@launch
                if (publish(captured, request) { it.copy(listing = it.listing?.copy(projects = listOf(project) + it.listing.projects),
                        selectedProjectID = project.id, projectsLoading = false) }) projectsTask = null
            } catch (failure: Throwable) {
                if (publish(captured, request) { it.copy(projectsError = failure.message ?: failure.toString(), projectsLoading = false) }) projectsTask = null
            }
        }
        if (!acceptsProjects(captured, request)) { next.cancel(); return }
        projectsTask = next; next.start()
    }
    public fun hopToInternet() {
        val captured = epoch; val service = remote ?: return
        if (!current(captured)) return
        val request = UUID.randomUUID(); hopRequest = request
        val oldTask = hopTask; val oldLease = lease; hopTask = null; lease = null
        oldTask?.cancel(); oldLease?.let(service.internet.restore)
        if (!current(captured) || hopRequest != request) return
        val preflight = beforeInternetHop
        if (preflight != null) {
            if (!publish(captured) { it.copy(hopping = true) } || hopRequest != request) return
            val next = owner.launch(start = CoroutineStart.LAZY) {
                if (!current(captured) || hopRequest != request || !currentCoroutineContext().isActive) return@launch
                try { preflight() } catch (failure: Throwable) {
                    if (!current(captured) || hopRequest != request || !currentCoroutineContext().isActive) return@launch
                    if (publish(captured) { it.copy(hopping = false, projectsError = failure.message ?: failure.toString()) } && hopRequest == request) hopTask = null
                    return@launch
                }
                if (!current(captured) || hopRequest != request || !currentCoroutineContext().isActive) return@launch
                val acquired = acquireHop(captured, request, service) ?: return@launch
                awaitHop(captured, request, service, acquired)
            }
            if (!current(captured) || hopRequest != request) { next.cancel(); return }
            hopTask = next; next.start()
            return
        }
        val acquired = acquireHop(captured, request, service) ?: return
        val next = owner.launch(start = CoroutineStart.LAZY) { awaitHop(captured, request, service, acquired) }
        if (!current(captured) || hopRequest != request) { next.cancel(); return }
        hopTask = next; next.start()
    }
    private fun acquireHop(captured: UUID, request: UUID, service: MonitorDeliveryRemoteService<P, X, H>): H? {
        fun refuse(message: String): H? {
            if (current(captured) && hopRequest == request &&
                publish(captured) { it.copy(hopping = false, projectsError = message) }) hopTask = null
            return null
        }
        val acquired = try { service.internet.begin() } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            return refuse(failure.message ?: failure.toString())
        } ?: // Another hop holds the route; this popup never steals it.
            return refuse("Couldn't leave the camera's Wi-Fi while another network switch is running.")
        if (!current(captured) || hopRequest != request || !service.internet.owns(acquired) || !current(captured)) {
            service.internet.restore(acquired); return null
        }
        lease = acquired
        if (!publish(captured) { it.copy(hopping = true) } || hopRequest != request) return null
        return acquired
    }
    private suspend fun awaitHop(captured: UUID, request: UUID, service: MonitorDeliveryRemoteService<P, X, H>, acquired: H) {
        val online = service.internet.wait(acquired)
        if (!current(captured) || hopRequest != request || !service.internet.owns(acquired) || !current(captured)) return
        if (!publish(captured) { it.copy(hopping = false) } || hopRequest != request) return
        hopTask = null; refresh(captured)
        if (!current(captured) || hopRequest != request) return
        if (online) loadProjects() else publish(captured) { it.copy(projectsError =
            "Couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or home Wi-Fi.") }
    }
    /** Accept an already transferred lease without a leave/wait. Refusal retains caller cleanup. */
    public fun adoptInternetLease(acquired: H): Boolean {
        val captured = epoch
        val service = remote ?: return false
        if (!current(captured) || lease != null || hopTask != null || !service.internet.owns(acquired) ||
            !current(captured) || !service.internet.owns(acquired) || !current(captured)) return false
        lease = acquired
        return publish(captured) { it.copy(destination = MonitorDeliveryDestination.REMOTE_UPLOAD, step = Step.OPTIONS) } &&
            service.internet.owns(acquired) && current(captured)
    }
    public fun takeRequest(): MonitorDeliveryPreparedRequest<C, F, P, X, H>? {
        val captured = epoch
        if (!current(captured) || !canContinue || !current(captured)) return null
        val value = state.value; val destination = value.destination ?: return null
        var transferred: H? = null
        val owned = lease; val service = remote
        if (owned != null && service != null) {
            if (!service.internet.owns(owned) || !current(captured)) return null
            transferred = service.transfer(owned)
            if (transferred == null || !current(captured) || !service.internet.owns(transferred) || !current(captured)) {
                transferred?.let(service.internet.restore); return null
            }
            lease = null
        }
        val remoteUpload = destination == MonitorDeliveryDestination.REMOTE_UPLOAD
        val project = if (remoteUpload) selectedProject else null
        val result = MonitorDeliveryPreparedRequest(destination, value.configuration, value.action, transferred,
            project, if (project != null) value.listing?.context else null)
        close(); return result
    }
    public fun close() {
        if (closed) return
        closed = true; epoch = UUID.randomUUID(); projectsRequest = null; hopRequest = null
        val oldProjects = projectsTask; val oldHop = hopTask; val oldPoll = pollingTask; val owned = lease
        projectsTask = null; hopTask = null; pollingTask = null; lease = null
        oldProjects?.cancel(); oldHop?.cancel(); oldPoll?.cancel(); owned?.let { remote?.internet?.restore?.invoke(it) }
        owner.cancel()
    }
    private fun refresh(captured: UUID) {
        if (!current(captured)) return
        val facts = observeSelection(); if (!publish(captured) { it.copy(selection = facts) }) return
        remote?.let { service -> val facts = service.observe(); publish(captured) { it.copy(remoteFacts = facts) } }
    }
    private fun retireProjects() {
        projectsRequest = null; val old = projectsTask; projectsTask = null
        publish(epoch) { it.copy(projectsLoading = false) }; old?.cancel()
    }
    private fun current(captured: UUID): Boolean {
        if (closed || epoch != captured) return false
        val accepted = sourceCurrent(); return accepted && !closed && epoch == captured
    }
    private fun acceptsProjects(captured: UUID, request: UUID): Boolean = current(captured) && projectsRequest == request
    private fun publish(captured: UUID, request: UUID? = null, change: (State<C, F, P, X>) -> State<C, F, P, X>): Boolean {
        if (!current(captured) || (request != null && projectsRequest != request)) return false
        mutable.value = change(state.value)
        return current(captured) && (request == null || projectsRequest == request)
    }
}
