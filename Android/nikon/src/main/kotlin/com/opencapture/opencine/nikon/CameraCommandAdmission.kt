package com.opencapture.opencine.nikon

/** Authority for one queued operation on an exact session instance.
 *
 * The supplied predicate reads the producer's thread-safe captured receipt. It must not send
 * commands or infer authority from a name. Direct camera operations do not require this value.
 */
public class CameraCommandAdmission(
    private val owner: CameraSession,
    private val isCurrent: () -> Boolean,
) {
    /** A replacement session cannot borrow the old receipt, even with the same camera name. */
    public fun admits(session: CameraSession): Boolean =
        owner === session && runCatching(isCurrent).getOrDefault(false)
}
