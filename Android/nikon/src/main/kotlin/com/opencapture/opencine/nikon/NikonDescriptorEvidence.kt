package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.ControlCapability

/** Semantic result of one descriptor read, independent of effective write authorization. */
public enum class NikonDescriptorReadOutcome {
    UNKNOWN, NOT_ATTEMPTED, PENDING, DESCRIBED, MISSING, UNSUPPORTED, REJECTED, MALFORMED,
    TRANSPORT_FAILED, MEDIA_BUSY,
}

/** Source of the existing effective option domain; fallback is never camera advertisement. */
public enum class NikonDescriptorOptionOrigin { UNKNOWN, DESCRIPTOR, LEGACY_FALLBACK }

/** Parsed descriptor form; UNKNOWN also covers an absent descriptor in old readback payloads. */
public enum class NikonDescriptorForm { UNKNOWN, NONE, RANGE, ENUMERATION }

/** Nikon-owned semantic facts; protocol bytes stay in the Swift descriptor cache. */
public data class NikonDescriptorObservation(
    public val outcome: NikonDescriptorReadOutcome = NikonDescriptorReadOutcome.UNKNOWN,
    public val capability: ControlCapability<List<String>> = ControlCapability.unknown(),
    public val form: NikonDescriptorForm = NikonDescriptorForm.UNKNOWN,
    public val operation: String? = null,
    public val response: Int? = null,
)

/** Retained generation and latest attempt are separate; neither authorizes control writes. */
public data class NikonDescriptorEvidence(
    public val observation: NikonDescriptorObservation = NikonDescriptorObservation(),
    public val latestAttempt: NikonDescriptorObservation = observation,
    public val optionOrigin: NikonDescriptorOptionOrigin = NikonDescriptorOptionOrigin.UNKNOWN,
    /** Latest actually parsed owner/property fact, also retained across abandoned generations. */
    public val lastValidObservation: NikonDescriptorObservation? = null,
)
