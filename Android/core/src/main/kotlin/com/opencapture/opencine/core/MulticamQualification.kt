package com.opencapture.opencine.core

/**
 * An integration's verdict for adding a camera configuration to a multiview stage. This
 * qualifies the requested configuration, not unreported camera state or a future command.
 */
public sealed interface MulticamQualification {
    public data object Qualified : MulticamQualification

    /** The integration has not established whether this configuration is supported. */
    public data object Unknown : MulticamQualification
    public data class Refused(public val reason: MulticamQualificationRefusal) : MulticamQualification
}

/**
 * Common policy explanations. Integrations keep their more specific explanations beside
 * their own qualification rules; shared admission needs only these actionable categories.
 */
public enum class MulticamQualificationRefusal {
    ALREADY_MEMBER,
    UNSUPPORTED_CONFIGURATION,
    OPERATION_UNAVAILABLE,
    NOT_REACHABLE,
}
