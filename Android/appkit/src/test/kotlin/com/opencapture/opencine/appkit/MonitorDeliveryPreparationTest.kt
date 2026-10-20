package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/** SIMULATED project replies and captured leases, with mirrored manual Swift scenarios. */
class MonitorDeliveryPreparationTest {
    private class Gate<T> {
        private val waiting = ArrayDeque<CompletableDeferred<T>>()
        val count get() = waiting.size
        suspend fun value(): T = withContext(NonCancellable) {
            val reply = CompletableDeferred<T>(); waiting.addLast(reply); reply.await()
        }
        fun release(value: T) { waiting.removeFirst().complete(value) }
    }
    private class Fixture {
        val loads = Gate<MonitorDeliveryProjectListing<String, String>>()
        val creates = Gate<MonitorDeliveryProject<String>>()
        val waits = Gate<Boolean>(); val clock = Gate<Unit>()
        var owned: Int? = null; var revision = 0
        val restored = mutableListOf<Int>(); val persisted = mutableListOf<String>()
        var network: Boolean? = false; var configured: Boolean? = true; var connected: Boolean? = true
        var savedID: String? = null; var sourceHook: (() -> Boolean)? = null
        var persistHook: (() -> Unit)? = null; var restoreHook: (() -> Unit)? = null
        var lut: Boolean? = true; var convert: Boolean? = true; var skips = true
        var files = listOf(MonitorDeliveryFileFacts("SIMULATED.mov", null)); var bakeLUT = false
        val nativeWaits = mutableListOf<Int>()
        fun model(scope: CoroutineScope, preferred: MonitorDeliveryDestination? = MonitorDeliveryDestination.REMOTE_UPLOAD,
            export: Boolean = true, missingConfiguration: Boolean = false) = MonitorDeliveryPreparationModel<Int, Int, String, String, Int>(scope,
            observeSelection = { MonitorDeliverySelectionFacts(files, 1, null) },
            configuration = if (export && !missingConfiguration) MonitorDeliveryExportConfiguration(1, 1, bakeLUT = bakeLUT) else null,
            exportOptions = if (export) MonitorDeliveryExportOptions(listOf(MonitorDeliveryChoice("1", "SIMULATED curve", 1)),
                listOf(MonitorDeliveryChoice("1", "SIMULATED format", 1)), { lut }, { convert }, { null },
                "SIMULATED", "SIMULATED", { "SIMULATED.mov" }) else null,
            remote = MonitorDeliveryRemoteService(presentation = MonitorDeliveryRemotePresentation("SIMULATED upload", "SIMULATED uploading"),
                observe = { MonitorDeliveryRemoteFacts(configured, connected, network, savedID, null) },
                load = { loads.value() }, create = { _, _ -> creates.value() },
                persist = { project, _ -> persisted += project.id; persistHook?.invoke() },
                internet = MonitorDeliveryInternetService({ network == true }, { revision++; owned = revision; revision },
                    { owned == it }, { nativeWaits += it; waits.value() },
                    { if (owned == it) { restored += it; owned = null; restoreHook?.invoke() } }),
                transfer = { if (owned != it) null else { revision++; owned = revision; revision } }, skipsUploaded = skips),
            preferredDestination = preferred, sourceCurrent = { sourceHook?.invoke() ?: true },
            sleep = { assertEquals(1.seconds, it); clock.value() })
        fun finish(model: MonitorDeliveryPreparationModel<Int, Int, String, String, Int>) {
            model.close(); while (clock.count > 0) clock.release(Unit)
        }
    }
    private fun listing(name: String) = MonitorDeliveryProjectListing("SIMULATED account",
        listOf(MonitorDeliveryProject(name, name, true, name)))

    @Test fun optionalRemoteServiceCarriesOnlyItsDeclaredPresentation() = runTest {
        val fixture = Fixture(); val model = fixture.model(this)
        assertEquals("SIMULATED upload", model.remotePresentation?.displayName)
        assertEquals("SIMULATED uploading", model.remotePresentation?.progressCaption)
        fixture.finish(model)
    }
    @Test fun stillsOnlySelectionOffersNoClipExport() = runTest {
        // ZIB-469: a still travels as its original, so no Bake LUT, curve or container is offered for it.
        val fixture = Fixture(); fixture.bakeLUT = true
        fixture.files = listOf(MonitorDeliveryFileFacts("DSC_0001.JPG", null, isStill = true))
        val model = fixture.model(backgroundScope, MonitorDeliveryDestination.NATIVE_SHARE)
        model.start(); runCurrent()
        assertNull(model.clipExportOptions)
        assertFalse(model.state.value.configuration!!.bakeLUT)
        model.setBakeLUT(true); assertFalse(model.state.value.configuration!!.bakeLUT)
        assertTrue(model.canContinue)
        fixture.files = listOf(MonitorDeliveryFileFacts("DSC_0001.JPG", null, isStill = true), MonitorDeliveryFileFacts("DSC_0002.MOV", null, isStill = false))
        val mixed = fixture.model(backgroundScope, MonitorDeliveryDestination.NATIVE_SHARE)
        mixed.start(); runCurrent()
        assertNotNull(mixed.clipExportOptions); assertTrue(mixed.state.value.configuration!!.bakeLUT)
        fixture.finish(mixed); fixture.finish(model); runCurrent()
    }
    @Test fun unknownExportFactsCannotEnableInventedOptions() = runTest {
        val fixture = Fixture(); fixture.lut = null; fixture.convert = null
        val model = fixture.model(backgroundScope, MonitorDeliveryDestination.NATIVE_SHARE)
        model.start(); runCurrent()
        assertNull(model.state.value.selection.files.first().sizeBytes); assertNull(model.state.value.selection.connected)
        model.setBakeLUT(true); model.setConvertLog(true)
        assertFalse(model.state.value.configuration!!.bakeLUT); assertFalse(model.state.value.configuration!!.convertLog)
        assertTrue(model.canContinue)
        val missing = fixture.model(backgroundScope, MonitorDeliveryDestination.NATIVE_SHARE, missingConfiguration = true)
        missing.start(); runCurrent(); assertFalse(missing.canContinue)
        fixture.finish(missing); fixture.finish(model); runCurrent()
    }
    @Test fun optionalNativeOriginalServiceNeedsNoExportOrUploadSettings() = runTest {
        val fixture = Fixture(); fixture.configured = null; fixture.connected = null
        val model = fixture.model(backgroundScope, MonitorDeliveryDestination.NATIVE_SHARE, export = false)
        model.start(); runCurrent()
        assertNull(model.state.value.configuration); assertNull(model.exportOptions); assertTrue(model.canContinue)
        assertFalse(model.destinationEnabled(MonitorDeliveryDestination.REMOTE_UPLOAD))
        val request = model.takeRequest()
        assertEquals(MonitorDeliveryDestination.NATIVE_SHARE, request!!.destination)
        assertNull(request.configuration); assertNull(request.internetLease)
        fixture.finish(model); runCurrent()
    }
    @Test fun replacementRejectsUncancellableProjectListing() = runTest {
        val fixture = Fixture(); val model = fixture.model(backgroundScope)
        model.start(); runCurrent(); assertEquals(1, fixture.loads.count)
        model.loadProjects(); runCurrent(); assertEquals(2, fixture.loads.count)
        fixture.loads.release(listing("old")); runCurrent()
        assertNull(model.state.value.listing); assertTrue(model.state.value.projectsLoading); assertTrue(fixture.persisted.isEmpty())
        fixture.loads.release(listing("current")); runCurrent()
        assertEquals("current", model.state.value.listing!!.projects.first().id)
        assertEquals("current", model.state.value.selectedProjectID); assertEquals(listOf("current"), fixture.persisted)
        fixture.finish(model); runCurrent()
    }
    @Test fun sourcePredicateReplacementRejectsFalseAndTrueListingReplies() = runTest {
        for (reply in listOf(false, true)) {
            val fixture = Fixture(); val model = fixture.model(backgroundScope)
            model.start(); runCurrent(); assertEquals(1, fixture.loads.count)
            var replace = true
            fixture.sourceHook = {
                if (replace) { replace = false; model.loadProjects(); reply } else true
            }
            fixture.loads.release(listing("old")); runCurrent(); assertEquals(1, fixture.loads.count)
            assertNull(model.state.value.listing); assertTrue(model.state.value.projectsLoading); assertTrue(fixture.persisted.isEmpty())
            fixture.loads.release(listing("current")); runCurrent()
            assertEquals(listOf("current"), fixture.persisted); assertEquals("current", model.state.value.selectedProjectID)
            fixture.finish(model); runCurrent()
        }
    }
    @Test fun persistenceCallbackReplacementKeepsSuccessorRequest() = runTest {
        val fixture = Fixture(); val model = fixture.model(backgroundScope)
        model.start(); runCurrent(); assertEquals(1, fixture.loads.count)
        fixture.persistHook = { fixture.persistHook = null; model.loadProjects() }
        fixture.loads.release(listing("old")); runCurrent(); assertEquals(1, fixture.loads.count)
        assertNull(model.state.value.listing); assertTrue(model.state.value.projectsLoading)
        assertEquals(listOf("old"), fixture.persisted)
        fixture.loads.release(listing("current")); runCurrent()
        assertEquals(listOf("old", "current"), fixture.persisted); assertEquals("current", model.state.value.selectedProjectID)
        fixture.finish(model); runCurrent()
    }
    @Test fun closeRetiresLateProjectCreation() = runTest {
        val fixture = Fixture(); val model = fixture.model(backgroundScope)
        model.start(); runCurrent(); fixture.loads.release(listing("known")); runCurrent()
        model.createProject("  SIMULATED new  "); runCurrent(); assertEquals(1, fixture.creates.count)
        fixture.finish(model); fixture.creates.release(MonitorDeliveryProject("late", "late", true, "late")); runCurrent()
        assertEquals(listOf("known"), model.state.value.listing!!.projects.map { it.id })
        assertEquals(listOf("known"), fixture.persisted); assertEquals("known", model.state.value.selectedProjectID); assertFalse(model.canContinue)
    }
    @Test fun preparedRemoteRequestCarriesTheSelectedProjectAndListingContext() = runTest {
        val fixture = Fixture(); val model = fixture.model(backgroundScope)
        model.start(); runCurrent()
        fixture.loads.release(MonitorDeliveryProjectListing("SIMULATED account", listOf(
            MonitorDeliveryProject("first", "First", true, "first payload"),
            MonitorDeliveryProject("second", "Second", true, "second payload")))); runCurrent()
        model.selectProject("second")
        val request = model.takeRequest()
        assertEquals(MonitorDeliveryDestination.REMOTE_UPLOAD, request!!.destination)
        assertEquals("second payload", request.project?.payload)
        assertEquals("SIMULATED account", request.projectContext)
        fixture.finish(model); runCurrent()
        val native = fixture.model(backgroundScope, MonitorDeliveryDestination.NATIVE_SHARE)
        native.start(); runCurrent()
        val share = native.takeRequest()
        assertNull(share!!.project); assertNull(share.projectContext)
        fixture.finish(native); runCurrent()
    }
    @Test fun reuploadIsOfferedOnlyForARemoteThatSkipsUploadedRecords() = runTest {
        val fixture = Fixture(); val model = fixture.model(backgroundScope)
        assertTrue(model.offersReupload)
        model.start(); runCurrent(); model.selectDestination(MonitorDeliveryDestination.NATIVE_SHARE); assertFalse(model.offersReupload)
        fixture.finish(model)
        fixture.skips = false; val plain = fixture.model(backgroundScope)
        assertFalse(plain.offersReupload)
        fixture.finish(plain); runCurrent()
    }
    @Test fun acceptedDeliveryTransfersLeaseBeforePopupClose() = runTest {
        val fixture = Fixture(); fixture.network = true; fixture.savedID = "saved"
        val model = fixture.model(backgroundScope)
        model.start(); model.hopToInternet(); runCurrent(); assertEquals(1, fixture.waits.count)
        assertTrue(model.state.value.hopping); assertFalse(model.canContinue); assertEquals(1, fixture.owned)
        fixture.network = false; fixture.waits.release(true); runCurrent()
        assertFalse(model.state.value.hopping); assertEquals(1, fixture.loads.count)
        val request = model.takeRequest()
        assertEquals(2, request!!.internetLease); assertEquals(2, fixture.owned); assertTrue(fixture.restored.isEmpty())
        fixture.loads.release(listing("late")); runCurrent(); fixture.finish(model); runCurrent()
        assertEquals(2, fixture.owned); assertTrue(fixture.restored.isEmpty()); assertTrue(fixture.persisted.isEmpty())
    }
    @Test fun cancelledPopupRestoresOnlyItsOwnLeaseDespiteReentry() = runTest {
        val fixture = Fixture(); fixture.network = true
        val model = fixture.model(backgroundScope)
        model.start(); model.hopToInternet(); runCurrent(); assertEquals(1, fixture.waits.count)
        fixture.restoreHook = { fixture.revision++; fixture.owned = fixture.revision }
        fixture.finish(model); runCurrent()
        assertEquals(listOf(1), fixture.restored); assertEquals(2, fixture.owned)
        fixture.waits.release(true); runCurrent(); model.close()
        assertEquals(listOf(1), fixture.restored); assertEquals(2, fixture.owned); assertEquals(0, fixture.loads.count)
    }
}
