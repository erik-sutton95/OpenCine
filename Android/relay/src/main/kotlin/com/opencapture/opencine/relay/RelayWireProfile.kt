package com.opencapture.opencine.relay

/** Immutable deployed wire facts; runtime decisions never branch on an app or manufacturer. */
public class RelayWireProfile(
    public val serviceType: String,
    public val version: Int,
    public val maximumPayloadBytes: Int = 8 * 1024 * 1024,
    public val servedCameraTXTKey: String,
    public val watchableTXTKey: String,
    public val presenceTcpPort: Int? = null,
    public val jpegCodec: Int? = null,
    public val hevcCodec: Int = 1,
    public val acceptsPeerCodecDeclaration: Boolean = false,
    messageKinds: Set<Int> = setOf(0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x11, 0x12),
) {
    public val messageKinds: Set<Int> = messageKinds.toSet()

    init {
        require(maximumPayloadBytes >= 0 && maximumPayloadBytes < Int.MAX_VALUE - 4)
        require(this.messageKinds.all { it in 0..255 })
        require(presenceTcpPort == null || presenceTcpPort in 1..65535)
    }

    public companion object {
        /** Original shared monitor protocol, unchanged. */
        public val SHARED_MONITOR: RelayWireProfile =
            RelayWireProfile(
                serviceType = "_opc-mon._tcp", version = 1,
                servedCameraTXTKey = "c", watchableTXTKey = "w",
            )
    }
}

public data class RelayNetworkPolicy(
    public val includePeerToPeer: Boolean = false,
    public val prohibitsCellular: Boolean = true,
    public val keepaliveIdle: Int = 10,
    public val keepaliveInterval: Int = 5,
    public val keepaliveCount: Int = 3,
)

/** Shared handshake facts. Absent codec lists retain the exact legacy HEVC admission. */
public data class RelayPeerHello(
    public val version: Int,
    public val hostName: String,
    public val cameraName: String? = null,
    public val passcode: String? = null,
    public val codecs: List<String>? = null,
    public val watcherID: String? = null,
) {
    public val acceptsHevc: Boolean get() = codecs?.contains("hevc") ?: true
}

/** Only video reference-chain facts cross into common frame delivery policy. */
public data class RelayVideoDescription(
    public val codec: Int,
    public val isKeyframe: Boolean,
    public val parameterSets: List<ByteArray>?,
)

/** Real wire implementations provide typed state/readings/commands and exact SDK JSON codecs. */
public interface RelayWireCodec<State, FrameMetadata, Command> {
    public val profile: RelayWireProfile
    public fun videoDescription(metadata: FrameMetadata): RelayVideoDescription
    public fun encodeHello(hello: RelayPeerHello): ByteArray
    public fun decodeHello(payload: ByteArray): RelayPeerHello
    public fun encodeState(state: State): ByteArray
    public fun decodeState(payload: ByteArray): State
    public fun encodeCommand(command: Command): ByteArray
    public fun decodeCommand(payload: ByteArray): Command
    public fun encodeFrame(metadata: FrameMetadata, image: ByteArray): ByteArray
    public fun decodeFrame(payload: ByteArray): RelayFramePayload<FrameMetadata>
}

public data class RelayFramePayload<Metadata>(public val metadata: Metadata, public val image: ByteArray)
