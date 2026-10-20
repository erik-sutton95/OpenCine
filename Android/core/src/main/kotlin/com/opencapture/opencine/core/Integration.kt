package com.opencapture.opencine.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlin.reflect.KClass

// The integration contract: how shared code finds, pairs, connects and forgets cameras of any
// integration (SHELL-02). Swift twin: Sources/OpenCineCore/Integration.swift.

/** How the phone reaches a camera. [rawValue] is the stored name (same as Swift). */
public enum class RouteKind(public val rawValue: String) {
    /** The phone joins the camera's own Wi-Fi access point. */
    CAMERA_ACCESS_POINT("cameraAccessPoint"),

    /** Phone and camera share a router network. */
    INFRASTRUCTURE_NETWORK("infrastructureNetwork"),

    /** The camera joins the phone's personal hotspot. */
    PHONE_HOTSPOT("phoneHotspot"),

    /** Camera control over a USB interface. */
    USB("usb"),

    /** A UVC/HDMI capture device: picture only. */
    CAPTURE_DEVICE("captureDevice"),
    ;

    public companion object {
        public fun of(rawValue: String): RouteKind? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** One body an integration knows and how it is reached (the device and profile catalogue). */
public data class CameraProfile(
    /** Namespaced, for example `org.example.cameras.model.0x22`. */
    public val id: String,
    public val title: String,
    public val routes: Set<RouteKind>,
    /** Routes the operator can add to a saved camera; non-empty offers "Add setup". */
    public val addableRoutes: Set<RouteKind> = emptySet(),
)

public enum class DiscoveryMode {
    /**
     * Listen only: advertisements, multicast browse, local USB enumeration, and presence dials that
     * cannot reach a camera's control service. Never a control-port connect, never protocol bytes.
     */
    PASSIVE,

    /** May sweep and probe control ports. Only for an operator who is pairing or adding a setup. */
    ACTIVE,
}

/** One camera discovery sees now. */
public data class NearbyCamera(
    /** Sighting key (a peripheral identifier, a hashed hardware address, host and path). */
    public val id: String,
    /** The saved camera this sighting is, when the integration knows. */
    public val savedID: String? = null,
    public val name: String,
    public val model: String,
    public val routes: Set<RouteKind>,
    /** `null` when the sighting carries no signal strength. */
    public val signalBars: Int? = null,
    /** `Unavailable(Busy)`: another device holds the camera. */
    public val availability: Availability = Availability.Available,
    /** The [SavedRoute.key] of the saved camera's route this sighting reaches, when the integration knows. */
    public val routeKey: String? = null,
)

/**
 * A route the operator is adding (from an add-setup slot). The secret goes to the integration's
 * credential store, never into the saved document, and never into [toString].
 */
public data class RouteDraft(
    public val kind: RouteKind,
    public val network: String? = null,
    public val secret: String? = null,
    public val title: String? = null,
) {
    override fun toString(): String =
        "RouteDraft($kind, network: $network, secret: ${if (secret == null) "null" else "<redacted>"})"
}

public sealed interface ConnectTarget {
    public data class Saved(public val camera: SavedCamera, public val route: ConnectionRouteID) : ConnectTarget

    public data class Nearby(public val camera: NearbyCamera) : ConnectTarget

    /** Provisioning a new route on a saved camera. */
    public data class AddRoute(public val camera: SavedCamera, public val draft: RouteDraft) : ConnectTarget

    /**
     * The camera an attempt is for: the saved id, else the sighting's saved id, else its key. At
     * most one attempt per camera is live.
     */
    public val cameraID: String
        get() = when (this) {
            is Saved -> camera.id
            is AddRoute -> camera.id
            is Nearby -> camera.savedID ?: camera.id
        }
}

/** One step of an attempt's plan, in integration copy. */
public data class ConnectionStep(public val title: String, public val detail: String = "")

public data class ConnectionProgress(
    public val attempt: ConnectionAttemptID,
    /** The same phase the session's [ConnectionState] carries. */
    public val phase: ConnectionPhase,
    /** This attempt's plan (it depends on the route). */
    public val steps: List<ConnectionStep>,
    /** Index into [steps] of the step running now. */
    public val current: Int,
    /** Live text, for example the network being joined. */
    public val note: String? = null,
)

/**
 * An integration-owned prompt type, rendered by the app's prompt slot. It carries its own typed
 * reply callbacks; [fallbackText] is shown when no slot renders it.
 */
public interface IntegrationPrompt {
    public val fallbackText: String
}

/** An explicit operator decision, presented once by the shell for its current source lifetime. */
public interface ConfirmationPrompt : IntegrationPrompt {
    public val confirmationID: String
    public val confirmationTitle: String
    public val confirmTitle: String
    public val cancelTitle: String
    public val confirm: () -> Unit
    public val cancel: () -> Unit
}

/** Something the operator must do for the attempt to continue. */
public sealed interface ConnectionPrompt {
    public val text: String

    /** Approve the connection on the camera; the text is integration copy. */
    public data class ApproveOnCamera(override val text: String) : ConnectionPrompt

    /** Accept the phone's prompt to join [network]; the text is integration copy. */
    public data class AcceptNetworkJoin(public val network: String, override val text: String) : ConnectionPrompt

    public data class Integration(public val prompt: IntegrationPrompt) : ConnectionPrompt {
        override val text: String get() = prompt.fallbackText
    }
}

/** Why an attempt ended without a camera, with integration copy and what the operator can do. */
public data class ConnectionFailure(
    public val reason: Reason,
    /** The phase the attempt was in; `null` when it failed before one started. */
    public val phase: ConnectionPhase? = null,
    public val title: String,
    public val message: String,
    public val actions: List<RecoveryAction>,
    /** Stable diagnostics code, for example `org.example.cameras.link.silent`. */
    public val code: String,
) {
    public sealed interface Reason {
        public data class Permission(public val permission: ConnectionFailure.Permission) : Reason
        public data class RadioOff(public val radio: Radio) : Reason
        public data object NotFound : Reason
        public data object TimedOut : Reason
        public data object NotApproved : Reason
        public data object CredentialsRejected : Reason

        /** Another device holds the camera. */
        public data object HeldElsewhere : Reason
        public data object WrongCamera : Reason
        public data object JoinFailed : Reason
        public data object LinkLost : Reason
        public data object Unsupported : Reason
        public data object Cancelled : Reason
        public data object Other : Reason
    }

    public enum class Permission { BLUETOOTH, LOCAL_NETWORK, LOCATION, NEARBY_DEVICES, USB }

    public enum class Radio { BLUETOOTH, WIFI }
}

public sealed interface RecoveryAction {
    public data object Retry : RecoveryAction
    public data class UseRoute(public val route: ConnectionRouteID) : RecoveryAction
    public data class EditRoute(public val route: ConnectionRouteID) : RecoveryAction
    public data object PairAgain : RecoveryAction
    public data object OpenSettings : RecoveryAction

    /** An integration-only action, for example taking over a camera another device holds. */
    public data class Integration(public val id: String, public val title: String) : RecoveryAction
}

public sealed interface ConnectionEvent {
    public data class Progress(public val progress: ConnectionProgress, public val prompt: ConnectionPrompt? = null) :
        ConnectionEvent

    /** Terminal. */
    public data class Connected(public val camera: ConnectedCamera) : ConnectionEvent

    /** Terminal. */
    public data class Failed(public val failure: ConnectionFailure) : ConnectionEvent
}

/** What a successful attempt produces. */
public data class ConnectedCamera(
    /** The record to upsert; the integration applied its save rules. */
    public val saved: SavedCamera,
    public val session: CameraSession,
    public val services: CameraServices = CameraServices(),
)

/**
 * Typed optional services of a connected camera, looked up by type, so Core never names the
 * module that declares one.
 */
public class CameraServices private constructor(@PublishedApi internal val services: Map<KClass<*>, Any>) {
    public constructor() : this(emptyMap())

    public inline fun <reified T : Any> get(): T? = services[T::class] as? T

    /** A copy with [service] registered as [type]. */
    public fun <T : Any> plus(type: KClass<T>, service: T): CameraServices = CameraServices(services + (type to service))
}

/**
 * How the shared cameras and pair pages treat an integration's cameras. The meaning is shared; each
 * integration declares its value, so no app passes a brand flag or its own tap handler.
 */
public data class IntegrationPresentation(
    public val nearbyTap: NearbyTap = NearbyTap.SELECT,
    /** A saved setup's menu offers Rename setup. */
    public val namesSetups: Boolean = true,
) {
    /** What a tap on a nearby camera's card does. */
    public enum class NearbyTap {
        /** Opens the pair page with the camera chosen; its Connect starts the attempt. */
        SELECT,

        /** Starts the attempt at once; the pair page shows its steps (a pairing the camera approves). */
        CONNECT,
    }
}

/** One camera integration as shared code sees it. Apps list their integrations explicitly. */
public interface CameraIntegration {
    /** Registration and diagnostics only: shared code never chooses behavior from it. */
    public val id: IntegrationID
    public val profiles: List<CameraProfile>
    public val discoveryModes: Set<DiscoveryMode>

    /** How the shared pages present this integration's cameras. */
    public val presentation: IntegrationPresentation get() = IntegrationPresentation()

    /**
     * The latest nearby list per element; cancelling the collector stops discovery. A mode not in
     * [discoveryModes] completes at once. In [DiscoveryMode.PASSIVE] it never opens a control-port
     * connection or sends protocol bytes.
     */
    public fun discover(mode: DiscoveryMode): Flow<List<NearbyCamera>>

    /**
     * Whether discovery is running now: `false` while the radio is off, the permission is denied
     * or the last scan failed, so the pages never claim to scan when nothing can (IA-336). The
     * default reports running for an integration that cannot tell.
     */
    public val discoveryRunning: Flow<Boolean> get() = flowOf(true)

    /**
     * One attempt per collection; cancelling the collector cancels it. [ConnectionEvent.Connected]
     * and [ConnectionEvent.Failed] are terminal. Events from an older attempt are never emitted
     * after a newer attempt for the same camera ([ConnectTarget.cameraID]) starts.
     */
    public fun connect(target: ConnectTarget): Flow<ConnectionEvent>

    /**
     * Drops what the integration stores per camera (route credentials). Never the per-install
     * identity (an approval or pairing identity shared by every camera).
     */
    public suspend fun forget(camera: SavedCamera)
}
