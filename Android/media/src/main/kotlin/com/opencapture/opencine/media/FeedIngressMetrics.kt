package com.opencapture.opencine.media

/** Fixed-size observations. The producer serializes access and supplies its monotonic clock. */
class FeedIngressMetrics {
    sealed interface Event {
        data class Datagram(val video: Boolean) : Event
        data object VideoGateDrop : Event
        data object InjectedVideoDrop : Event
        data object RegistrationSubmission : Event
        data object ReceiveError : Event
    }

    private var generation: Int? = null
    private var receivedDatagrams = 0
    private var videoDatagrams = 0
    private var videoGateDrops = 0
    private var injectedVideoDrops = 0
    private var registrationSubmissions = 0
    private var receiveErrors = 0
    private var lastDatagramAt: Double? = null
    private var lastVideoDatagramAt: Double? = null
    private var lastRegistrationSubmissionAt: Double? = null

    fun reset(generation: Int) {
        this.generation = generation
        receivedDatagrams = 0
        videoDatagrams = 0
        videoGateDrops = 0
        injectedVideoDrops = 0
        registrationSubmissions = 0
        receiveErrors = 0
        lastDatagramAt = null
        lastVideoDatagramAt = null
        lastRegistrationSubmissionAt = null
    }

    fun record(event: Event, at: Double, generation: Int): Boolean {
        if (this.generation != generation || !at.isFinite() || at < 0.0) return false
        when (event) {
            is Event.Datagram -> {
                receivedDatagrams = increment(receivedDatagrams)
                lastDatagramAt = at
                if (event.video) {
                    videoDatagrams = increment(videoDatagrams)
                    lastVideoDatagramAt = at
                }
            }
            Event.VideoGateDrop -> videoGateDrops = increment(videoGateDrops)
            Event.InjectedVideoDrop -> injectedVideoDrops = increment(injectedVideoDrops)
            Event.RegistrationSubmission -> {
                registrationSubmissions = increment(registrationSubmissions)
                lastRegistrationSubmissionAt = at
            }
            Event.ReceiveError -> receiveErrors = increment(receiveErrors)
        }
        return true
    }

    fun snapshot(now: Double, videoGateOpen: Boolean): FeedIncidentIngress? {
        val current = generation ?: return null
        fun age(at: Double?): Double? =
            at?.takeIf { now.isFinite() && now >= it }?.let { now - it }
        return FeedIncidentIngress(
            socketGeneration = current,
            receivedDatagrams = receivedDatagrams,
            videoDatagrams = videoDatagrams,
            videoGateDrops = videoGateDrops,
            injectedVideoDrops = injectedVideoDrops,
            registrationSubmissions = registrationSubmissions,
            receiveErrors = receiveErrors,
            lastDatagramAge = age(lastDatagramAt),
            lastVideoDatagramAge = age(lastVideoDatagramAt),
            lastRegistrationSubmissionAge = age(lastRegistrationSubmissionAt),
            videoGateOpen = videoGateOpen,
        )
    }

    private fun increment(value: Int): Int = if (value == Int.MAX_VALUE) value else value + 1
}
