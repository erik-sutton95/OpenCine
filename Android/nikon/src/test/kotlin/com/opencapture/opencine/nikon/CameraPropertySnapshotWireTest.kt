package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SupportStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraPropertySnapshotWireTest {
    @Test fun lastValidDescriptorIsIndependentAndDefaultsUnknown() {
        val prefix = "descriptor.vibrationReduction"
        val payload = listOf(
            "result\taccepted", "$prefix.outcome\tdescribed", "$prefix.support\tsupported",
            "$prefix.access\treadWrite", "$prefix.form\tenumeration", "$prefix.choices\tOFF",
            "$prefix.latestOutcome\tnotAttempted", "$prefix.lastValidOutcome\tdescribed",
            "$prefix.lastValidSupport\tsupported", "$prefix.lastValidAccess\treadOnly",
            "$prefix.lastValidForm\tenumeration", "$prefix.lastValidChoices\tSPORT",
        ).joinToString("\n")
        val facts = CameraPropertySnapshotWire.decode(payload).snapshot.controlCapabilities.vibrationReductionDescriptor
        assertEquals(listOf("OFF"), facts.observation.capability.offer)
        assertEquals(NikonDescriptorReadOutcome.NOT_ATTEMPTED, facts.latestAttempt.outcome)
        assertEquals(listOf("SPORT"), facts.lastValidObservation?.capability?.offer)
        assertEquals(com.opencapture.opencine.core.SettingAccess.READ_ONLY, facts.lastValidObservation?.capability?.access)
        assertNull(CameraPropertySnapshotWire.decode(validPayload()).snapshot.controlCapabilities.vibrationReductionDescriptor.lastValidObservation)
        for (invalid in listOf(
            payload.replace("lastValidOutcome\tdescribed", "lastValidOutcome\tfutureOutcome"),
            payload.replace("lastValidAccess\treadOnly", "lastValidAccess\tfutureAccess"),
        )) {
            assertNull(CameraPropertySnapshotWire.decode(invalid).snapshot.controlCapabilities.vibrationReductionDescriptor.lastValidObservation)
        }
    }

    @Test fun retainedDescriptorSurvivesTransientLatestAttemptWithoutInventingLatestMetadata() {
        val payload = validPayload() + "\n" + """
            descriptor.vibrationReduction.outcome	described
            descriptor.vibrationReduction.support	supported
            descriptor.vibrationReduction.access	readWrite
            descriptor.vibrationReduction.form	enumeration
            descriptor.vibrationReduction.choices	SPORT${'\u001F'}OFF
            descriptor.vibrationReduction.origin	descriptor
            descriptor.vibrationReduction.operation	getDevicePropDesc
            descriptor.vibrationReduction.response	8193
            descriptor.vibrationReduction.latestOutcome	transportFailed
            descriptor.vibrationReduction.latestOperation	getDevicePropDescEx
        """.trimIndent()
        val decoded = CameraPropertySnapshotWire.decode(payload)
        assertTrue(decoded.isValid)
        val evidence = decoded.snapshot.controlCapabilities.vibrationReductionDescriptor
        assertEquals(NikonDescriptorReadOutcome.DESCRIBED, evidence.observation.outcome)
        assertEquals(listOf("SPORT", "OFF"), evidence.observation.capability.offer)
        assertEquals(SettingAccess.READ_WRITE, evidence.observation.capability.access)
        assertEquals(NikonDescriptorOptionOrigin.DESCRIPTOR, evidence.optionOrigin)
        assertEquals("getDevicePropDesc", evidence.observation.operation)
        assertEquals(8193, evidence.observation.response)
        assertEquals(NikonDescriptorReadOutcome.TRANSPORT_FAILED, evidence.latestAttempt.outcome)
        assertEquals(SupportStatus.UNKNOWN, evidence.latestAttempt.capability.support)
        assertNull(evidence.latestAttempt.capability.offer)
        assertEquals(NikonDescriptorForm.UNKNOWN, evidence.latestAttempt.form)
        assertEquals("getDevicePropDescEx", evidence.latestAttempt.operation)
        assertNull(evidence.latestAttempt.response)
        val samePayload = payload.replace("latestOutcome\ttransportFailed", "latestOutcome\tdescribed")
        val same = CameraPropertySnapshotWire.decode(samePayload)
            .snapshot.controlCapabilities.vibrationReductionDescriptor
        assertEquals(NikonDescriptorReadOutcome.DESCRIBED, same.latestAttempt.outcome)
        assertEquals(SupportStatus.UNKNOWN, same.latestAttempt.capability.support)
        assertNull(same.latestAttempt.capability.offer)
        assertEquals(NikonDescriptorForm.UNKNOWN, same.latestAttempt.form)
        assertNull(same.latestAttempt.response)
        val newDomain = CameraPropertySnapshotWire.decode(samePayload + """
            descriptor.vibrationReduction.latestSupport	supported
            descriptor.vibrationReduction.latestAccess	readOnly
            descriptor.vibrationReduction.latestForm	enumeration
            descriptor.vibrationReduction.latestChoices	OFF
        """.trimIndent().let { "\n$it" }).snapshot.controlCapabilities.vibrationReductionDescriptor
        assertEquals(listOf("SPORT", "OFF"), newDomain.observation.capability.offer)
        assertEquals(SettingAccess.READ_WRITE, newDomain.observation.capability.access)
        assertEquals(listOf("OFF"), newDomain.latestAttempt.capability.offer)
        assertEquals(SettingAccess.READ_ONLY, newDomain.latestAttempt.capability.access)
        assertEquals(NikonDescriptorForm.ENUMERATION, newDomain.latestAttempt.form)
    }

    @Test fun descriptorChoicesRequireEnumerationAndKnownAccessWithoutChangingEffectiveOptions() {
        val base = validPayload() + "\noptions.vibrationReduction\tSPORT\u001FOFF\u001FON\n" + """
            descriptor.vibrationReduction.outcome	described
            descriptor.vibrationReduction.support	supported
            descriptor.vibrationReduction.access	readOnly
            descriptor.vibrationReduction.form	enumeration
        """.trimIndent()
        fun observation(payload: String) = CameraPropertySnapshotWire.decode(payload)
            .snapshot.controlCapabilities.vibrationReductionDescriptor.observation
        assertNull(observation(base).capability.offer)
        val empty = observation(base + "\ndescriptor.vibrationReduction.choices\t")
        assertEquals(emptyList(), empty.capability.offer)
        assertEquals(SupportStatus.SUPPORTED, empty.capability.support)
        assertEquals(SettingAccess.READ_ONLY, empty.capability.access)
        for (form in listOf("none", "range", "futureForm")) {
            assertNull(observation(base.replace("form\tenumeration", "form\t$form") +
                "\ndescriptor.vibrationReduction.choices\tOFF").capability.offer)
        }
        for (access in listOf(null, "futureAccess")) {
            val payload = base.lineSequence().filterNot { it.startsWith("descriptor.vibrationReduction.access\t") }
                .joinToString("\n") + (access?.let { "\ndescriptor.vibrationReduction.access\t$it" } ?: "")
            val unknown = observation(payload).capability
            assertEquals(SupportStatus.UNKNOWN, unknown.support)
            assertFalse(unknown.isOffered)
            assertFalse(unknown.isShown)
            assertNull(unknown.offer)
            assertEquals(listOf("SPORT", "OFF", "ON"), CameraPropertySnapshotWire.decode(payload)
                .snapshot.controlCapabilities.options(CameraControl.VIBRATION_REDUCTION))
        }
        val unsupported = observation(base.replace("support\tsupported", "support\tunsupported"))
        assertEquals(SupportStatus.UNSUPPORTED, unsupported.capability.support)
        assertFalse(unsupported.capability.isShown)
    }

    @Test fun descriptorOutcomeTagsAndResponseBoundariesRemainSemantic() {
        val outcomes = listOf(
            "unknown" to NikonDescriptorReadOutcome.UNKNOWN, "notAttempted" to NikonDescriptorReadOutcome.NOT_ATTEMPTED,
            "pending" to NikonDescriptorReadOutcome.PENDING, "described" to NikonDescriptorReadOutcome.DESCRIBED,
            "missing" to NikonDescriptorReadOutcome.MISSING, "unsupported" to NikonDescriptorReadOutcome.UNSUPPORTED,
            "rejected" to NikonDescriptorReadOutcome.REJECTED, "malformed" to NikonDescriptorReadOutcome.MALFORMED,
            "transportFailed" to NikonDescriptorReadOutcome.TRANSPORT_FAILED, "mediaBusy" to NikonDescriptorReadOutcome.MEDIA_BUSY,
            "futureOutcome" to NikonDescriptorReadOutcome.UNKNOWN,
        )
        for ((tag, expected) in outcomes) {
            val evidence = CameraPropertySnapshotWire.decode(validPayload() +
                "\ndescriptor.electronicVr.outcome\t$tag\ndescriptor.electronicVr.latestOutcome\t$tag")
                .snapshot.controlCapabilities.electronicVrDescriptor
            assertEquals(expected, evidence.observation.outcome)
            assertEquals(expected, evidence.latestAttempt.outcome)
        }
        for ((raw, expected) in listOf("0" to 0, "65535" to 65535, "-1" to null,
            "65536" to null, "4294967296" to null, "futureResponse" to null)) {
            val evidence = CameraPropertySnapshotWire.decode(validPayload() +
                "\ndescriptor.electronicVr.response\t$raw\ndescriptor.electronicVr.latestResponse\t$raw")
                .snapshot.controlCapabilities.electronicVrDescriptor
            assertEquals(expected, evidence.observation.response)
            assertEquals(expected, evidence.latestAttempt.response)
        }
    }

    @Test fun descriptorFactsPreserveEmptyReadOnlyAndUnknownCompatibility() {
        val old = CameraPropertySnapshotWire.decode(validPayload()).snapshot.controlCapabilities
        assertEquals(NikonDescriptorReadOutcome.UNKNOWN, old.vibrationReductionDescriptor.observation.outcome)
        val wire = """
            result	accepted
            descriptor.vibrationReduction.outcome	described
            descriptor.vibrationReduction.support	supported
            descriptor.vibrationReduction.access	readOnly
            descriptor.vibrationReduction.form	enumeration
            descriptor.vibrationReduction.choices${'\t'}
            descriptor.vibrationReduction.origin	unknown
            descriptor.vibrationReduction.latestOutcome	described
            descriptor.electronicVr.outcome	rejected
            descriptor.electronicVr.support	unknown
            descriptor.electronicVr.operation	getDevicePropDescEx
            descriptor.electronicVr.response	8194
            descriptor.electronicVr.origin	legacyFallback
            descriptor.electronicVr.latestOutcome	rejected
        """.trimIndent()
        val decoded = CameraPropertySnapshotWire.decode(wire)
        assertTrue(decoded.isValid)
        val vr = decoded.snapshot.controlCapabilities.vibrationReductionDescriptor
        assertEquals(NikonDescriptorReadOutcome.DESCRIBED, vr.observation.outcome)
        assertEquals(com.opencapture.opencine.core.SupportStatus.SUPPORTED, vr.observation.capability.support)
        assertEquals(com.opencapture.opencine.core.SettingAccess.READ_ONLY, vr.observation.capability.access)
        assertEquals(emptyList(), vr.observation.capability.offer)
        assertEquals(NikonDescriptorForm.ENUMERATION, vr.observation.form)
        val evr = decoded.snapshot.controlCapabilities.electronicVrDescriptor
        assertEquals(NikonDescriptorReadOutcome.REJECTED, evr.observation.outcome)
        assertEquals("getDevicePropDescEx", evr.observation.operation)
        assertEquals(8194, evr.observation.response)
        assertEquals(NikonDescriptorOptionOrigin.LEGACY_FALLBACK, evr.optionOrigin)
        val future = CameraPropertySnapshotWire.decode(wire.replace("described", "futureOutcome")
            .replace("supported", "futureSupport").replace("readOnly", "futureAccess")
            .replace("enumeration", "futureForm").replace("legacyFallback", "futureOrigin"))
        assertTrue(future.isValid)
        val unknown = future.snapshot.controlCapabilities.vibrationReductionDescriptor.observation
        assertEquals(NikonDescriptorReadOutcome.UNKNOWN, unknown.outcome)
        assertEquals(com.opencapture.opencine.core.SupportStatus.UNKNOWN, unknown.capability.support)
        assertNull(unknown.capability.offer)
        assertEquals(NikonDescriptorOptionOrigin.UNKNOWN,
            future.snapshot.controlCapabilities.electronicVrDescriptor.optionOrigin)
    }

    @Test fun recordingAxesPreserveOpaqueTokensAndNeverParseLabels() {
        val token = "future exact camera token"
        val decoded = CameraPropertySnapshotWire.decode(validPayload() +
            "\noptions.recordingFormat\t$token\u001Earea-a\u001E4K\u001E23.98p")
        assertTrue(decoded.isValid)
        assertEquals(listOf(NikonRecordingFormatPresentation(token, "area-a", "4K", "23.98p")),
            decoded.snapshot.controlCapabilities.recordingFormats)
        assertTrue(CameraPropertySnapshotWire.decode(validPayload()).snapshot.controlCapabilities.recordingFormats.isEmpty())
        val invalid = CameraPropertySnapshotWire.decode(validPayload() + "\noptions.recordingFormat\t4K · 25p")
        assertTrue(invalid.snapshot.controlCapabilities.recordingFormats.isEmpty())
    }

    @Test fun stillToneSemanticReadbackPreservesUnknown() {
        for (label in listOf("SDR", "HLG", "unknown", "1", "255", "")) {
            val decoded = CameraPropertySnapshotWire.decode(validPayload().replace("stillToneMode\tHLG", "stillToneMode\t$label"))
            assertTrue(decoded.isValid)
            assertEquals(label.takeIf { it == "SDR" || it == "HLG" }, decoded.snapshot.stillToneMode)
        }
    }

    @Test
    fun decodesOrderedStorageSlotsAndPreservesLegacyFirstCard() {
        val decoded = CameraPropertySnapshotWire.decode(validPayload())

        assertTrue(decoded.isValid)
        assertEquals(NativePropertyRefreshResult.ACCEPTED, decoded.result)
        assertEquals(954_000_000_000L, decoded.snapshot.storage?.totalCapacityBytes)
        assertEquals(242_000_000_000L, decoded.snapshot.storage?.freeSpaceBytes)
        assertEquals(
            listOf(65_537L, 131_073L),
            decoded.snapshot.storageSlots.map { it.storageId },
        )
        assertEquals(listOf(1, 2), decoded.snapshot.storageSlots.map { it.slotNumber })
        assertEquals(
            listOf(954_000_000_000L, 512_000_000_000L),
            decoded.snapshot.storageSlots.map { it.totalCapacityBytes },
        )
        assertEquals(
            listOf(242_000_000_000L, 111_000_000_000L),
            decoded.snapshot.storageSlots.map { it.freeSpaceBytes },
        )
        assertEquals("HLG", decoded.snapshot.stillToneMode)
    }

    @Test
    fun acceptsExplicitUnknownTotalWithoutInventingCapacity() {
        val decoded =
            CameraPropertySnapshotWire.decode(
                validPayload()
                    .replace("storageSlotCount\t2", "storageSlotCount\t1")
                    .lineSequence()
                    .filterNot { it.startsWith("storageSlot.1.") }
                    .map {
                        when {
                            it.startsWith("storageSlot.0.totalCapacityBytes") ->
                                "storageSlot.0.totalCapacityBytes\t0"
                            else -> it
                        }
                    }.joinToString("\n"),
            )

        assertTrue(decoded.isValid)
        assertEquals(0L, decoded.snapshot.storageSlots.single().totalCapacityBytes)
        assertEquals(242_000_000_000L, decoded.snapshot.storageSlots.single().freeSpaceBytes)
    }

    @Test
    fun missingSlotCountWithIndexedFieldsIsRejected() {
        assertRejected(validPayload().replace("storageSlotCount\t2\n", ""))
    }

    @Test
    fun partialOrUnexpectedIndexedRecordsAreRejected() {
        assertRejected(
            validPayload().lineSequence()
                .filterNot { it.startsWith("storageSlot.1.freeSpaceBytes") }
                .joinToString("\n"),
        )
        assertRejected(validPayload() + "\nstorageSlot.2.storageId\t196609")
    }

    @Test
    fun slotIdentityOverflowDuplicateAndOrderMismatchAreRejected() {
        assertRejected(
            validPayload().replace(
                "storageSlot.0.storageId\t65537",
                "storageSlot.0.storageId\t4294967296",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.0.storageId\t65537",
                "storageSlot.0.storageId\t4294967295",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.storageId\t131073",
                "storageSlot.1.storageId\t65537",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.slotNumber\t2",
                "storageSlot.1.slotNumber\t1",
            ),
        )
    }

    @Test
    fun physicalSlotNumbersMayGapButMustIncrease() {
        // A lone card in body slot 2 (or slots 1+3) keeps its physical number.
        val gapped =
            CameraPropertySnapshotWire.decode(
                validPayload().replace(
                    "storageSlot.1.slotNumber\t2",
                    "storageSlot.1.slotNumber\t3",
                ),
            )
        assertTrue(gapped.isValid)
        assertEquals(listOf(1, 3), gapped.snapshot.storageSlots.map { it.slotNumber })
    }

    @Test
    fun capacityOverflowNegativeAndInconsistencyAreRejected() {
        assertRejected(
            validPayload().replace(
                "storageSlot.1.totalCapacityBytes\t512000000000",
                "storageSlot.1.totalCapacityBytes\t9223372036854775808",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.freeSpaceBytes\t111000000000",
                "storageSlot.1.freeSpaceBytes\t-1",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.freeSpaceBytes\t111000000000",
                "storageSlot.1.freeSpaceBytes\t600000000000",
            ),
        )
    }

    @Test
    fun legacyStoragePairIsAlsoAtomicAndConsistent() {
        assertRejected(validPayload().replace("storageFreeSpaceBytes\t242000000000\n", ""))
        assertRejected(
            validPayload().replace(
                "storageFreeSpaceBytes\t242000000000",
                "storageFreeSpaceBytes\t1000000000000",
            ),
        )

        val noStorage = CameraPropertySnapshotWire.decode("result\taccepted\nstorageSlotCount\t0")
        assertTrue(noStorage.isValid)
        assertNull(noStorage.snapshot.storage)
        assertTrue(noStorage.snapshot.storageSlots.isEmpty())
    }

    @Test
    fun decodesTheProfileAndExposureIndicatorFields() {
        val decoded =
            CameraPropertySnapshotWire.decode(
                validPayload() +
                    "\npictureControl\tStandard" +
                    "\nevIndicatorSixths\t-4" +
                    "\nevIndicatorLit\ttrue",
            )
        assertTrue(decoded.isValid)
        assertEquals("Standard", decoded.snapshot.pictureControl)
        assertEquals(-4, decoded.snapshot.evIndicatorSixths)
        assertEquals(true, decoded.snapshot.evIndicatorLit)

        // Absent fields stay null; the meter hides rather than inventing 0 EV.
        val bare = CameraPropertySnapshotWire.decode(validPayload())
        assertNull(bare.snapshot.pictureControl)
        assertNull(bare.snapshot.evIndicatorSixths)
        assertNull(bare.snapshot.evIndicatorLit)
        assertFalse(bare.snapshot.autoExposurePoll)
    }

    @Test
    fun decodesTheAutoExposurePollGate() {
        val on =
            CameraPropertySnapshotWire.decode(validPayload() + "\nautoExposurePoll\ttrue")
        assertTrue(on.snapshot.autoExposurePoll)

        val off =
            CameraPropertySnapshotWire.decode(validPayload() + "\nautoExposurePoll\tfalse")
        assertFalse(off.snapshot.autoExposurePoll)
    }

    private fun assertRejected(payload: String) {
        val decoded = CameraPropertySnapshotWire.decode(payload)
        assertFalse(decoded.isValid)
        assertEquals(NativePropertyRefreshResult.TRANSPORT_FAILED, decoded.result)
        assertTrue(decoded.snapshot.storageSlots.isEmpty())
    }

    @Test
    fun keepsTheMovieAndStillsWhiteBalanceApart() {
        val decoded =
            CameraPropertySnapshotWire.decode(
                validPayload() + "\nwhiteBalanceMode\tSunny\nstillWhiteBalanceMode\tAuto1",
            )

        assertTrue(decoded.isValid)
        // Two different camera settings that decode through the same table: the cinema readout
        // must not repaint when a stills WB event lands mid-take.
        assertEquals("Sunny", decoded.snapshot.activeWhiteBalanceMode(photography = false))
        assertEquals("Auto1", decoded.snapshot.activeWhiteBalanceMode(photography = true))
    }

    @Test
    fun aBodyThatOnlyReportsOneWhiteBalanceSideStillReadsOut() {
        val movieOnly =
            CameraPropertySnapshotWire.decode(validPayload() + "\nwhiteBalanceMode\tSunny").snapshot
        assertEquals("Sunny", movieOnly.activeWhiteBalanceMode(photography = true))

        val stillsOnly =
            CameraPropertySnapshotWire.decode(
                validPayload() + "\nstillWhiteBalanceMode\tAuto1",
            ).snapshot
        assertEquals("Auto1", stillsOnly.activeWhiteBalanceMode(photography = false))

        assertNull(CameraPropertySnapshotWire.decode(validPayload()).snapshot
            .activeWhiteBalanceMode(photography = false))
    }

    private fun validPayload(): String =
        listOf(
            "result\taccepted",
            "stillToneMode\tHLG",
            "storageTotalCapacityBytes\t954000000000",
            "storageFreeSpaceBytes\t242000000000",
            "storageSlotCount\t2",
            "storageSlot.0.storageId\t65537",
            "storageSlot.0.slotNumber\t1",
            "storageSlot.0.totalCapacityBytes\t954000000000",
            "storageSlot.0.freeSpaceBytes\t242000000000",
            "storageSlot.1.storageId\t131073",
            "storageSlot.1.slotNumber\t2",
            "storageSlot.1.totalCapacityBytes\t512000000000",
            "storageSlot.1.freeSpaceBytes\t111000000000",
        ).joinToString("\n")
}
