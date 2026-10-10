package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayBroadcast
import com.opencapture.opencine.relay.RelayDiscoveryIndex
import com.opencapture.opencine.relay.RelayDiscoveryRow
import com.opencapture.opencine.relay.RelayWireProfile
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flow

/** Existing passive browser facts cross the port; no discovery sweep or PTP probe lives here. */
public sealed interface RelayServiceEvent {
    public data class Found(public val name: String) : RelayServiceEvent
    public data class Lost(public val name: String) : RelayServiceEvent
    public class Resolved(
        public val name: String, public val host: String, public val port: Int,
        attributes: Map<String, String>,
    ) : RelayServiceEvent {
        public val attributes: Map<String, String> = attributes.toMap()
    }
}

/** Each collection owns its passive listing window, TXT projection and deterministic order. */
public class RelayServiceDirectory(private val profile: RelayWireProfile) {
    public fun broadcasts(events: Flow<RelayServiceEvent>): Flow<List<RelayBroadcast>> = flow {
        val index = RelayDiscoveryIndex<RelayBroadcast>(RelayDiscoveryIndex.Order.NAME)
        val source = index.start()
        val known = mutableMapOf<String, RelayDiscoveryRow<RelayBroadcast>>()
        val lost = mutableSetOf<String>()
        emit(emptyList())
        try {
            events.collect { event ->
                if (!index.admits(source)) return@collect
                when (event) {
                    is RelayServiceEvent.Found -> lost.remove(event.name)
                    is RelayServiceEvent.Lost -> { known.remove(event.name); lost.add(event.name) }
                    is RelayServiceEvent.Resolved -> {
                        if (event.name in lost) return@collect
                        val row = RelayBroadcast(
                            name = event.name, host = event.host, port = event.port,
                            servedCameraHost = event.attributes[profile.servedCameraTXTKey]?.takeIf(String::isNotBlank),
                            isWatchable = event.attributes[profile.watchableTXTKey] != "0",
                        )
                        known[event.name] = RelayDiscoveryRow(
                            id = row.name, name = row.name, endpoint = row,
                            servedCameraHost = row.servedCameraHost, isWatchable = row.isWatchable,
                        )
                    }
                }
                if (index.replace(known.values.toList(), origin = "passive", token = source)) {
                    emit(index.results.map { it.endpoint })
                }
            }
        } finally { index.stop() }
    }.distinctUntilChanged()
}
