package com.opencapture.opencine.relay

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RelayPortableOwnerTest {
    @Test
    fun splitAndCoalescedFramesKeepEachStreamsOwnPartialBytes() {
        val first = RelayStreamFraming.encode(1, "{}".toByteArray())
        val second = RelayStreamFraming.encode(0x12, byteArrayOf(0x80.toByte(), 0xFF.toByte()))
        val joined = first + second
        for (split in 0..joined.size) {
            val reader = RelayStreamBuffer(RelayWireProfile.SHARED_MONITOR)
            val early = reader.append(joined.copyOfRange(0, split))
            val late = reader.append(joined.copyOfRange(split, joined.size))
            assertEquals(listOf(1, 0x12), (early + late).map { it.kind })
            assertContentEquals("{}".toByteArray(), (early + late)[0].payload)
            assertContentEquals(byteArrayOf(0x80.toByte(), 0xFF.toByte()), (early + late)[1].payload)
            assertEquals(0, reader.pendingByteCount)
        }
        val retired = RelayStreamBuffer(RelayWireProfile.SHARED_MONITOR)
        assertTrue(retired.append(first.copyOfRange(0, 6)).isEmpty())
        retired.reset()
        assertEquals(listOf(0x12), retired.append(second).map { it.kind })
    }

    @Test
    fun unsignedLengthAndZeroAreRejectedWithoutAllocatingBody() {
        val profile = RelayWireProfile.SHARED_MONITOR
        val oversized = assertFailsWith<RelayStreamFraming.DecodeError.PayloadTooLarge> {
            RelayStreamFraming.decode(byteArrayOf(-1, -1, -1, -1, 3), profile)
        }
        assertEquals(4_294_967_294L, oversized.declared)
        val zero = assertFailsWith<RelayStreamFraming.DecodeError.PayloadTooLarge> {
            RelayStreamFraming.decode(byteArrayOf(0, 0, 0, 0, 3), profile)
        }
        assertEquals(0L, zero.declared)
    }

    @Test
    fun profileLimitRejectsOversizedHeaderBeforeBodyAndUnknownKindAfterCompleteFrame() {
        val profile = RelayWireProfile("_fixture._tcp", 7, maximumPayloadBytes = 2,
            servedCameraTXTKey = "c", watchableTXTKey = "w")
        val oversized = assertFailsWith<RelayStreamFraming.DecodeError.PayloadTooLarge> {
            RelayStreamFraming.decode(byteArrayOf(0, 0, 0, 4, 3), profile)
        }
        assertEquals(3L, oversized.declared)
        assertNull(RelayStreamFraming.decode(byteArrayOf(0, 0, 0, 3, 0x99.toByte(), 1), profile))
        val unknown = assertFailsWith<RelayStreamFraming.DecodeError.UnknownKind> {
            RelayStreamFraming.decode(byteArrayOf(0, 0, 0, 3, 0x99.toByte(), 1, 2), profile)
        }
        assertEquals(0x99, unknown.kind)
        assertContentEquals(byteArrayOf(1, 2),
            RelayStreamFraming.decode(byteArrayOf(0, 0, 0, 3, 3, 1, 2), profile)?.payload)
    }

    @Test
    fun malformedMetadataCannotConsumePictureBytesAndOpaqueImageIsPreserved() {
        val malformed = assertFailsWith<RelayFrameBlob.Truncated> {
            RelayFrameBlob.decode(byteArrayOf(-1, -1, -1, -1, 1))
        }
        assertEquals(4_294_967_295L, malformed.declared)
        val short = assertFailsWith<RelayFrameBlob.Truncated> { RelayFrameBlob.decode(byteArrayOf(0, 1, 2)) }
        assertEquals(3L, short.declared)
        val metadata = "{\"codec\":1}".toByteArray()
        val image = byteArrayOf(-1, 0, 0x80.toByte(), -1)
        val decoded = RelayFrameBlob.decode(RelayFrameBlob.encode(metadata, image))
        assertContentEquals(metadata, decoded.metadata)
        assertContentEquals(image, decoded.image)
    }

    @Test
    fun sharedProfileAndLegacyCodecAdmissionStayCompatible() {
        val profile = RelayWireProfile.SHARED_MONITOR
        assertEquals("_opc-mon._tcp", profile.serviceType)
        assertEquals(1, profile.version)
        assertEquals(8_388_608, profile.maximumPayloadBytes)
        assertEquals("c", profile.servedCameraTXTKey)
        assertEquals("w", profile.watchableTXTKey)
        assertEquals(1, profile.hevcCodec)
        assertFalse(profile.acceptsPeerCodecDeclaration)
        assertTrue(RelayPeerHello(1, "legacy").acceptsHevc)
        assertFalse(RelayPeerHello(2, "JPEG", codecs = listOf("jpeg")).acceptsHevc)
        assertTrue(RelayPeerHello(2, "HEVC", codecs = listOf("hevc", "jpeg")).acceptsHevc)
    }

    @Test
    fun qualityQueueAndKeyframeCooldownRemainBounded() {
        val profile = RelayEncoderProfile.QUALITY
        assertEquals("quality", profile.wireValue)
        assertEquals(120, profile.maxKeyframeInterval)
        val lane = RelayEncodePolicy(depth = profile.maxInFlightFramesPerPeer)
        repeat(4) { assertTrue(lane.admit()) }
        repeat(100) { assertFalse(lane.admit()) }
        assertEquals(4, lane.inFlight)
        lane.complete()
        assertTrue(lane.admit())
        assertTrue(lane.forceKeyframe(true, 0.0))
        for (tick in 1 until 100) assertFalse(lane.forceKeyframe(true, tick / 100.0))
        assertTrue(lane.forceKeyframe(true, 1.0))
        repeat(10) { lane.complete() }
        assertEquals(0, lane.inFlight)
    }

    @Test
    fun adaptationUsesSuppliedLadderAndRequiresConsecutivePressureAndCleanRecovery() {
        val policy = RelayBitratePolicy(ladder = listOf(900, 600), maxFrameQPLadder = listOf(31, 37))
        val adaptation = RelayBitrate(now = 0.0, policy = policy)
        for (tick in 1..5) adaptation.recordTick(saturated = tick % 2 == 0, now = tick.toDouble())
        assertEquals(0, adaptation.rungIndex)
        assertEquals(900, adaptation.bitsPerSecond)
        for (tick in 6..10) adaptation.recordTick(saturated = false, cameraStarving = true, now = tick.toDouble())
        assertEquals(1, adaptation.rungIndex)
        assertEquals(600, adaptation.bitsPerSecond)
        assertEquals(37, adaptation.maxFrameQP)
        for (tick in 11..39) adaptation.recordTick(saturated = false, now = tick.toDouble())
        assertEquals(1, adaptation.rungIndex)
        assertEquals(900, adaptation.recordTick(saturated = false, now = 40.0))
        adaptation.ceilingIndex = 1
        assertEquals(600, adaptation.bitsPerSecond)
        assertEquals(37, adaptation.maxFrameQP)
    }

    @Test
    fun measuredStarvationPoliciesRemainDistinctAndUnknownUsesOriginalFloor() {
        val floor = RelayCameraStarvationPolicy(15.0, 0.72)
        val fraction = RelayCameraStarvationPolicy(0.0, 0.8)
        assertEquals(21.6, floor.threshold(30.0), 1e-9)
        assertEquals(24.0, fraction.threshold(30.0))
        assertEquals(15.0, floor.threshold(20.0))
        assertEquals(15.0, floor.threshold(0.0))
    }

    @Test
    fun parkedIdentityCannotClaimOtherPeerOrAtExactExpiryAndClearRetiresClaim() {
        val lease = RelayParkedControlLease()
        assertTrue(lease.park("old", 0))
        assertFalse(lease.claim("other", 1_000))
        assertTrue(lease.claim("old", 19_999))
        assertFalse(lease.claim("old", 19_999))
        assertTrue(lease.park("old", 0))
        assertFalse(lease.claim("old", 20_000))
        assertTrue(lease.park("old", 0))
        lease.clear()
        assertFalse(lease.claim("old", 1_000))
        assertFalse(lease.park(null, 0))
    }

    @Test
    fun watchEnvelopeKeepsExactTaggedJSONAndRefusesEmptyOrUnknownTag() {
        val json = "\"toggleRecord\"".toByteArray()
        val envelope = RelayEnvelopeFraming.encode(3, json)
        assertContentEquals(byteArrayOf(3) + json, envelope)
        assertEquals(3, RelayEnvelopeFraming.kind(envelope, setOf(1, 2, 3, 4)))
        assertContentEquals(json, RelayEnvelopeFraming.payload(envelope))
        assertFailsWith<RelayEnvelopeFraming.DecodeError.Empty> { RelayEnvelopeFraming.payload(byteArrayOf()) }
        assertFailsWith<RelayEnvelopeFraming.DecodeError.UnknownKind> {
            RelayEnvelopeFraming.kind(byteArrayOf(0x99.toByte()), setOf(1, 2, 3, 4))
        }
    }
}
