package com.opencapture.opencine.frameio

import com.opencapture.opencine.appkit.MonitorDeliveryAdmission
import com.opencapture.opencine.appkit.MonitorDeliveryBatchOutcome
import com.opencapture.opencine.appkit.MonitorDeliveryCoordinator
import com.opencapture.opencine.appkit.MonitorDeliveryDestination
import com.opencapture.opencine.appkit.MonitorDeliveryExportConfiguration
import com.opencapture.opencine.appkit.MonitorDeliveryInternetService
import com.opencapture.opencine.appkit.MonitorDeliveryOriginalService
import com.opencapture.opencine.appkit.MonitorDeliveryPostExportAction
import com.opencapture.opencine.appkit.MonitorDeliveryPreparedRequest
import com.opencapture.opencine.appkit.MonitorDeliveryProject
import com.opencapture.opencine.appkit.MonitorDeliveryRemoteRun
import com.opencapture.opencine.appkit.MonitorDeliverySource
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest

private typealias FrameioRequest =
    MonitorDeliveryPreparedRequest<Unit, Unit, FrameioProject, FrameioCapturedProjectListing, FrameioInternetLease>

/** Host coverage for the one Android Frame.io owner over SIMULATED ports (A4-09). */
class FrameioDeliveryControllerTest {
    private data class Clip(val identity: String?, val file: File)

    @Test
    fun `unconfigured build never starts authorization`() {
        val core = FakeCore()
        val controller = controller(configuration = { null }, core = core)

        assertEquals(FrameioConnectionState.UNCONFIGURED, controller.connectionState)
        assertNull(controller.beginSignIn())
        assertEquals(0, core.authorizationStarts)
        assertContains(controller.errorMessage.orEmpty(), "isn't configured")
    }

    @Test
    fun `camera access point binding blocks authorization without releasing it`() {
        val core = FakeCore()
        val controller = controller(core = core, reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT))

        assertNull(controller.beginSignIn())
        assertEquals(0, core.authorizationStarts)
        assertContains(controller.errorMessage.orEmpty(), "without your approval")
    }

    @Test
    fun `verified redirect exchanges only persisted PKCE state`() = runTest {
        val secrets = MemorySecretStore()
        val core = FakeCore()
        val http = FakeHttp()
        val controller = controller(core = core, http = http, secrets = secrets)
        val revision = controller.accountRevision

        assertEquals("https://auth.example.invalid/authorize", controller.beginSignIn())
        assertEquals(FrameioConnectionState.AUTHORIZING, controller.connectionState)
        assertNotNull(secrets.state.pendingAuthorization)

        controller.completeRedirect("opencine-unit://oauth/callback?code=unit-code&state=unit-state")

        assertEquals(FrameioConnectionState.CONNECTED, controller.connectionState)
        assertEquals("unit-access", secrets.state.token?.accessToken)
        assertNull(secrets.state.pendingAuthorization)
        assertEquals(1, core.redirectParses)
        assertEquals(listOf("exchange"), core.tokenKinds)
        assertEquals(1, http.executeCalls)
        assertTrue(controller.accountRevision != revision)
    }

    @Test
    fun `unverified redirect clears pending state without sending a token request`() = runTest {
        val secrets = MemorySecretStore()
        val core = FakeCore()
        val http = FakeHttp()
        val controller = controller(core = core, http = http, secrets = secrets)

        controller.beginSignIn()
        controller.completeRedirect("opencine-unit://other/callback?code=unit-code&state=unit-state")

        assertEquals(FrameioConnectionState.ERROR, controller.connectionState)
        assertNull(secrets.state.pendingAuthorization)
        assertEquals(1, core.redirectParses)
        assertEquals(0, core.tokenRequests)
        assertEquals(0, http.executeCalls)
    }

    @Test
    fun `upload sends only an approved complete file and polls Frameio status`() = runTest {
        withReadyRoot { root ->
            val source = root.clip("C0001.MOV")
            val core = FakeCore()
            val http = FakeHttp()
            val controller = connectedController(root, core = core, http = http)

            controller.loadProjects()
            val selected = assertNotNull(controller.selectedDestination)
            assertEquals("project", selected.projectID)

            controller.upload(source, "C0001.MOV", selected, MonitorDeliveryAdmission { true }, null) {}

            assertEquals(1, http.uploadCalls)
            assertContains(core.apiOperations, FrameioCoreOperation.CREATE_FILE)
            assertContains(core.apiOperations, FrameioCoreOperation.UPLOAD_STATUS)
            assertEquals(listOf<String?>("folder"), core.createdFolders)
        }
    }

    @Test
    fun `upload rejects a path outside the approved roots before any Frameio request`() = runTest {
        withReadyRoot { root ->
            val readyRoot = Files.createDirectories(root.resolve("ready"))
            val outside = root.clip("outside.mov")
            val http = FakeHttp()
            val controller = connectedController(readyRoot, http = http)

            val failure = assertFailsWith<FrameioDeliveryException> {
                controller.upload(outside, "C0002.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, null) {}
            }

            assertContains(failure.message.orEmpty(), "Only complete approved")
            assertEquals(0, http.executeCalls)
            assertEquals(0, http.uploadCalls)
        }
    }

    @Test
    fun `upload refuses an unsafe display name before any Frameio request`() = runTest {
        withReadyRoot { root ->
            val source = root.clip("C0002.MOV")
            val http = FakeHttp()
            val controller = connectedController(root, http = http)

            assertFailsWith<FrameioDeliveryException> {
                controller.upload(source, "../C0002.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, null) {}
            }
            assertEquals(0, http.executeCalls)
        }
    }

    @Test
    fun `upload rechecks reachability before a signed upload part`() = runTest {
        withReadyRoot { root ->
            val source = root.clip("C0003.MOV")
            val http = FakeHttp()
            // Construction, then Create File, then the first part.
            val reachability = SequencedReachability(listOf(
                FrameioNetworkState.ONLINE, FrameioNetworkState.ONLINE, FrameioNetworkState.CAMERA_ACCESS_POINT))
            val controller = connectedController(root, http = http, reachability = reachability)

            assertFailsWith<FrameioDeliveryException> {
                controller.upload(source, "C0003.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, null) {}
            }

            assertEquals(1, http.executeCalls)
            assertEquals(0, http.uploadCalls)
            assertContains(controller.errorMessage.orEmpty(), "without your approval")
        }
    }

    @Test
    fun `upload progress returns from HTTP IO to the UI dispatcher`() = runTest {
        withReadyRoot { root ->
            val source = root.clip("C0004.MOV")
            val http = FakeHttp(progressFromIO = true)
            val uiDispatcher = RecordingUIDispatcher()
            try {
                val controller = controller(root, http = http, uiDispatcher = uiDispatcher,
                    secrets = MemorySecretStore(FrameioSecretState(FRESH_TOKEN, null)),
                    destinations = MemoryDestinationStore(SAVED_DESTINATION))
                val threads = mutableListOf<String>()

                controller.upload(source, "C0004.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, null) {
                    threads += Thread.currentThread().name
                }

                val ioThread = assertNotNull(http.progressCallbackThreadName)
                assertTrue(threads.isNotEmpty())
                assertTrue(threads.all { it == "frameio-delivery-ui" })
                assertTrue(ioThread != "frameio-delivery-ui")
            } finally {
                uiDispatcher.close()
            }
        }
    }

    @Test
    fun `upload stops between steps when its admission is withdrawn`() = runTest {
        withReadyRoot { root ->
            val source = root.clip("C0004.MOV")
            val http = FakeHttp()
            val controller = connectedController(root, http = http)
            var current = true

            assertFailsWith<CancellationException> {
                controller.upload(source, "C0004.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { current }, null) {
                    current = false
                }
            }

            assertEquals(0, http.uploadCalls)
        }
    }

    @Test
    fun `upload never leaves a camera access point without explicit hop consent`() = runTest {
        withReadyRoot { root ->
            val source = root.clip("C0005.MOV")
            val http = FakeHttp()
            val hop = FakeCameraHop()
            val controller = connectedController(root, http = http,
                reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT))
            controller.attachCameraHop(hop)

            assertFailsWith<FrameioDeliveryException> {
                controller.upload(source, "C0005.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, null) {}
            }

            assertEquals(0, hop.leaveCalls)
            assertEquals(0, http.uploadCalls)
            assertContains(controller.errorMessage.orEmpty(), "without your approval")
        }
    }

    @Test
    fun `consented hop uploads then reports the rejoin in the run outcome`() = runTest {
        withReadyRoot { root ->
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val evidence = FrameioCameraRejoinEvidence("Camera", "SIMULATED", 123_000L)
            val hop = FakeCameraHop(
                onLeave = { reachability.value = FrameioNetworkState.ONLINE },
                onRejoin = { reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT; evidence },
            )
            val controller = connectedController(root, reachability = reachability)
            controller.attachCameraHop(hop)
            val leases = mutableListOf<FrameioInternetLease>()
            val service = controller.remoteService(current = { true }, onLease = { leases += it })

            assertTrue(service.observe().onCameraNetwork == true)
            assertTrue(service.internet.needsHop())
            val lease = assertNotNull(service.internet.begin())
            assertEquals(listOf(lease), leases)
            assertTrue(service.internet.wait(lease))
            assertIs<FrameioInternetHopState.Online>(controller.internetHopState)

            val outcome = deliver(controller, listOf(Clip("clip-6", root.clip("C0006.MOV").toFile())), request(lease = lease))

            assertEquals(MonitorDeliveryBatchOutcome.Uploaded("1 uploaded; camera rejoined"), outcome)
            assertEquals(evidence, assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState).evidence)
            assertEquals(1, hop.leaveCalls)
            assertEquals(1, hop.rejoinCalls)
            assertFalse(controller.isInternetHopActive)
        }
    }

    @Test
    fun `upload success never hides a camera rejoin that could not be verified`() = runTest {
        withReadyRoot { root ->
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val hop = FakeCameraHop(onLeave = { reachability.value = FrameioNetworkState.ONLINE }, onRejoin = { null })
            val controller = connectedController(root, reachability = reachability)
            controller.attachCameraHop(hop)
            val lease = assertNotNull(controller.claimInternetHop { true })
            assertTrue(controller.waitInternetHop(lease))

            val outcome = deliver(controller, listOf(Clip("clip-7", root.clip("C0007.MOV").toFile())), request(lease = lease))

            val uploaded = assertIs<MonitorDeliveryBatchOutcome.Uploaded<File>>(outcome)
            assertTrue(uploaded.summary.startsWith("1 uploaded; camera rejoin not verified: "))
            assertContains(uploaded.summary, "$UNIT_PRODUCT could not verify a new camera session")
            assertIs<FrameioInternetHopState.Failed>(controller.internetHopState)
            assertContains(controller.errorMessage.orEmpty(), "could not verify")
        }
    }

    @Test
    fun `run without a route lease adds no route note`() = runTest {
        withReadyRoot { root ->
            val controller = connectedController(root)

            val outcome = deliver(controller, listOf(Clip("clip", root.clip("C0007.MOV").toFile())), request())

            assertEquals(MonitorDeliveryBatchOutcome.Uploaded("1 uploaded"), outcome)
        }
    }

    @Test
    fun `a failed run and its route note read as one sentence`() = runTest {
        withReadyRoot { root ->
            val run = MonitorDeliveryRemoteRun<Clip>("Uploading", upload = { _, _, _ ->
                throw FrameioDeliveryException("SIMULATED upload refused.")
            }, routeNote = { "camera rejoined" })

            val outcome = deliver(listOf(Clip("clip", root.clip("C0008.MOV").toFile())), run)

            assertEquals("SIMULATED upload refused; camera rejoined.",
                assertIs<MonitorDeliveryBatchOutcome.Failed<File>>(outcome).message)
        }
    }

    @Test
    fun `concurrent rejoin callers share one camera attempt and result`() = runTest {
        withReadyRoot { root ->
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val rejoinStarted = CompletableDeferred<Unit>()
            val allowRejoin = CompletableDeferred<Unit>()
            val evidence = FrameioCameraRejoinEvidence("Camera", "SIMULATED", 123_500L)
            val hop = FakeCameraHop(
                onLeave = { reachability.value = FrameioNetworkState.ONLINE },
                onRejoin = {
                    rejoinStarted.complete(Unit)
                    allowRejoin.await()
                    reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT
                    evidence
                },
            )
            val controller = connectedController(root, reachability = reachability)
            controller.attachCameraHop(hop)

            assertTrue(controller.beginInternetHop())
            val first = async { controller.endInternetHop() }
            rejoinStarted.await()
            val second = async { controller.endInternetHop() }
            assertTrue(controller.isInternetHopActive)
            allowRejoin.complete(Unit)

            assertTrue(first.await())
            assertTrue(second.await())
            assertEquals(1, hop.rejoinCalls)
            assertEquals(evidence, assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState).evidence)
            assertFalse(controller.isInternetHopActive)
        }
    }

    @Test
    fun `concurrent failed rejoin callers share one attempt and failed result`() = runTest {
        withReadyRoot { root ->
            val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
            val rejoinStarted = CompletableDeferred<Unit>()
            val allowRejoin = CompletableDeferred<Unit>()
            val hop = FakeCameraHop(
                onLeave = { reachability.value = FrameioNetworkState.ONLINE },
                onRejoin = {
                    rejoinStarted.complete(Unit)
                    allowRejoin.await()
                    null
                },
            )
            val controller = connectedController(root, reachability = reachability)
            controller.attachCameraHop(hop)

            assertTrue(controller.beginInternetHop())
            val first = async { controller.endInternetHop() }
            rejoinStarted.await()
            val second = async { controller.endInternetHop() }
            allowRejoin.complete(Unit)

            assertFalse(first.await())
            assertFalse(second.await())
            assertEquals(1, hop.rejoinCalls)
            assertIs<FrameioInternetHopState.Failed>(controller.internetHopState)
            assertFalse(controller.isInternetHopActive)
        }
    }

    @Test
    fun `internet timeout rejoins the camera and keeps the timeout truthful`() = runTest {
        val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
        val evidence = FrameioCameraRejoinEvidence("Camera", "SIMULATED", 124_000L)
        val hop = FakeCameraHop(
            onLeave = { reachability.value = FrameioNetworkState.OFFLINE },
            onRejoin = { reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT; evidence },
        )
        val controller = controller(reachability = reachability, internetWaitAttempts = 2)
        controller.attachCameraHop(hop)

        assertFalse(controller.beginInternetHop())

        assertEquals(1, hop.leaveCalls)
        assertEquals(1, hop.rejoinCalls)
        assertFalse(controller.isInternetHopActive)
        assertEquals(evidence, assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState).evidence)
        assertContains(controller.errorMessage.orEmpty(), "validated internet route")
    }

    @Test
    fun `cancelled internet wait still rejoins the camera`() = runTest {
        val reachability = MutableReachability(FrameioNetworkState.CAMERA_ACCESS_POINT)
        val hop = FakeCameraHop(
            onLeave = { reachability.value = FrameioNetworkState.OFFLINE },
            onRejoin = {
                reachability.value = FrameioNetworkState.CAMERA_ACCESS_POINT
                FrameioCameraRejoinEvidence("Camera", "SIMULATED", 125_000L)
            },
        )
        val controller = controller(reachability = reachability, internetWaitPoll = { throw CancellationException("unit cancel") })
        controller.attachCameraHop(hop)

        assertFailsWith<CancellationException> { controller.beginInternetHop() }

        assertEquals(1, hop.leaveCalls)
        assertEquals(1, hop.rejoinCalls)
        assertFalse(controller.isInternetHopActive)
        assertIs<FrameioInternetHopState.Rejoined>(controller.internetHopState)
    }

    @Test
    fun `popup route begin is null only while another hop holds the route`() {
        val controller = controller(reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT))
        val hop = FakeCameraHop()
        controller.attachCameraHop(hop)

        assertNotNull(controller.remoteService(current = { true }).internet.begin())
        assertNull(controller.remoteService(current = { true }).internet.begin())
        assertEquals(0, hop.leaveCalls)

        val fixture = controller(reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT))
        fixture.attachCameraHop(FakeCameraHop(availability = FrameioHopAvailability.FIXTURE_UNAVAILABLE))
        val refused = assertFailsWith<FrameioDeliveryException> { fixture.remoteService(current = { true }).internet.begin() }
        assertContains(refused.message.orEmpty(), "demo fixtures")
    }

    @Test
    fun `fixture hop is unavailable and never releases a network`() = runTest {
        val controller = controller(reachability = FixedReachability(FrameioNetworkState.CAMERA_ACCESS_POINT))
        val hop = FakeCameraHop(availability = FrameioHopAvailability.FIXTURE_UNAVAILABLE)
        controller.attachCameraHop(hop)

        assertFalse(controller.beginInternetHop())
        assertEquals(0, hop.leaveCalls)
        assertContains(controller.errorMessage.orEmpty(), "demo fixtures")
    }

    @Test
    fun `baked output uploads from a second approved root and a sidecar failure stays nonfatal`() = runTest {
        withReadyRoot { root ->
            val exportRoot = Files.createDirectories(root.resolve("exports"))
            val baked = exportRoot.clip("prepared.mp4", size = 6)
            val core = FakeCore(partSizes = listOf(6))
            val metadata = RecordingMetadataWriter(failure = java.io.IOException("unit metadata failure"))
            val controller = connectedController(root, core = core, approvedUploadRoots = listOf(root, exportRoot),
                metadataSidecarWriter = metadata)
            val facts = FrameioSidecarFacts("camera", "20260715T120000", "C0008.MOV", "MONO")
            val progress = mutableListOf<Double>()

            controller.upload(baked, "C0008.mp4", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, facts) { progress += it }

            assertEquals(1.0, progress.last())
            assertEquals(listOf("C0008.mp4"), core.createdNames)
            assertEquals(listOf(6L), core.createdSizes)
            assertEquals(listOf(RecordingMetadataWriter.Call(facts, "C0008.mp4", 6, SAVED_DESTINATION)), metadata.calls)
        }
    }

    @Test
    fun `sidecar is written only after Frameio confirms and only when facts are given`() = runTest {
        withReadyRoot { root ->
            val metadata = RecordingMetadataWriter()
            val facts = FrameioSidecarFacts("camera", "", "C0009.MOV", null)
            val unconfirmed = connectedController(root, core = FakeCore(uploadComplete = { false }), metadataSidecarWriter = metadata)
            assertFailsWith<FrameioDeliveryException> {
                unconfirmed.upload(root.clip("C0009.MOV"), "C0009.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, facts) {}
            }
            assertTrue(metadata.calls.isEmpty())

            val confirmed = connectedController(root, metadataSidecarWriter = metadata)
            confirmed.upload(root.clip("C0010.MOV"), "C0010.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, null) {}
            assertTrue(metadata.calls.isEmpty())
            confirmed.upload(root.clip("C0011.MOV"), "C0011.MOV", SAVED_DESTINATION, MonitorDeliveryAdmission { true }, facts) {}
            assertEquals(1, metadata.calls.size)
        }
    }

    @Test
    fun `remote run keeps the saved destination it captured when the operator later picks another project`() = runTest {
        withReadyRoot { root ->
            val other = FrameioProject("other", "Other", "other-folder")
            val core = FakeCore(projects = listOf(FrameioProject("project", "Dailies", "folder"), other))
            val controller = connectedController(root, core = core)
            controller.loadProjects()
            val run = assertNotNull(controller.remoteRun<Clip>(request(), identity = { it.identity }, sidecar = { null }))

            assertTrue(controller.selectProject(other))
            assertEquals("other", controller.selectedDestination?.projectID)
            val outcome = deliver(listOf(Clip("a", root.clip("A.MOV").toFile()), Clip("b", root.clip("B.MOV").toFile())), run)

            assertEquals(MonitorDeliveryBatchOutcome.Uploaded("2 uploaded"), outcome)
            assertEquals(listOf<String?>("folder", "folder"), core.createdFolders)
        }
    }

    @Test
    fun `remote run uploads to the project the popup accepted, not the saved one`() = runTest {
        withReadyRoot { root ->
            val dailies = FrameioProject("project", "Dailies", "folder")
            val other = FrameioProject("other", "Other", "other-folder")
            val core = FakeCore(projects = listOf(dailies, other))
            val controller = connectedController(root, core = core)
            val listing = controller.loadProjectsCaptured { true }
            val run = assertNotNull(controller.remoteRun<Clip>(request(project = other, context = listing),
                identity = { it.identity }, sidecar = { null }))

            assertTrue(controller.selectProjectCaptured(dailies, listing) { true })
            deliver(listOf(Clip("a", root.clip("A.MOV").toFile())), run)

            assertEquals(listOf<String?>("other-folder"), core.createdFolders)
        }
    }

    @Test
    fun `remote run refuses without a destination or with a replaced account`() = runTest {
        withReadyRoot { root ->
            val signedIn = controller(root, secrets = MemorySecretStore(FrameioSecretState(FRESH_TOKEN, null)))
            assertNull(signedIn.remoteRun<Clip>(request(), identity = { it.identity }, sidecar = { null }))

            val controller = connectedController(root)
            val listing = controller.loadProjectsCaptured { true }
            val project = listing.listing.projects.first()
            controller.disconnect()
            assertNull(controller.remoteRun<Clip>(request(project = project, context = listing),
                identity = { it.identity }, sidecar = { null }))
        }
    }

    @Test
    fun `remote run built for one account never uploads after a disconnect`() = runTest {
        withReadyRoot { root ->
            val core = FakeCore()
            val http = FakeHttp()
            val controller = connectedController(root, core = core, http = http)
            val run = assertNotNull(controller.remoteRun<Clip>(request(), identity = { it.identity }, sidecar = { null }))

            controller.disconnect()
            val outcome = deliver(listOf(Clip("a", root.clip("A.MOV").toFile())), run)

            assertEquals(MonitorDeliveryBatchOutcome.Failed("Cancelled."), outcome)
            assertEquals(0, http.executeCalls)
            assertEquals(0, http.uploadCalls)
        }
    }

    @Test
    fun `remote run passes each record's sidecar facts and display name`() = runTest {
        withReadyRoot { root ->
            val core = FakeCore()
            val metadata = RecordingMetadataWriter()
            val controller = connectedController(root, core = core, metadataSidecarWriter = metadata)
            val run = assertNotNull(controller.remoteRun<Clip>(request(), identity = { it.identity },
                sidecar = { FrameioSidecarFacts("camera", "", it.file.name, null) }, displayName = { "Delivered-${it.name}" }))

            deliver(listOf(Clip("a", root.clip("A.MOV").toFile())), run)

            assertEquals(listOf("Delivered-A.MOV"), core.createdNames)
            assertEquals("A.MOV", metadata.calls.single().facts.originalFilename)
            assertEquals("Delivered-A.MOV", metadata.calls.single().deliveryFilename)
        }
    }

    @Test
    fun `confirmed upload persists and is skipped unless reupload is explicit`() = runTest {
        withReadyRoot { root ->
            val history = MemoryUploadHistory()
            val http = FakeHttp()
            val controller = connectedController(root, http = http, uploadHistory = history)
            val clips = listOf(Clip("clip-11", root.clip("C0011.MOV").toFile()))

            assertEquals(MonitorDeliveryBatchOutcome.Uploaded("1 uploaded"), deliver(controller, clips, request()))
            assertTrue(history.contains("clip-11"))
            assertEquals(1, http.uploadCalls)

            assertEquals(MonitorDeliveryBatchOutcome.Uploaded("1 skipped"), deliver(controller, clips, request()))
            assertEquals(1, http.uploadCalls)

            assertEquals(MonitorDeliveryBatchOutcome.Uploaded("1 uploaded"),
                deliver(controller, clips, request(forceReupload = true)))
            assertEquals(2, http.uploadCalls)
        }
    }

    @Test
    fun `mixed batch reports uploaded skipped and failed clips exactly`() = runTest {
        withReadyRoot { root ->
            val history = MemoryUploadHistory(setOf("already-uploaded"))
            val http = FakeHttp(failUploadCalls = setOf(2))
            val controller = connectedController(root, http = http, uploadHistory = history)
            val clips = listOf("already-uploaded", "new-success", "new-failure").mapIndexed { index, identity ->
                Clip(identity, root.clip("BATCH$index.MOV").toFile())
            }

            val outcome = deliver(controller, clips, request())

            assertEquals(MonitorDeliveryBatchOutcome.Failed("1 uploaded, 1 skipped, 1 failed"), outcome)
            assertTrue(history.contains("new-success"))
            assertFalse(history.contains("new-failure"))
        }
    }

    @Test
    fun `private history failures never duplicate or reclassify a confirmed upload`() = runTest {
        withReadyRoot { root ->
            val clips = listOf(Clip("history-clip", root.clip("HISTORY.MOV").toFile()))

            val readHttp = FakeHttp()
            val unreadable = connectedController(root, http = readHttp, uploadHistory = ThrowingUploadHistory(failRead = true))
            val refused = assertIs<MonitorDeliveryBatchOutcome.Failed<File>>(deliver(unreadable, clips, request()))
            assertContains(refused.message, "$UNIT_PRODUCT couldn't read the private Frame.io upload history.")
            assertEquals(0, readHttp.uploadCalls)

            val writeHttp = FakeHttp()
            val unrecorded = connectedController(root, http = writeHttp, uploadHistory = ThrowingUploadHistory(failWrite = true))
            assertEquals(MonitorDeliveryBatchOutcome.Uploaded("1 uploaded"), deliver(unrecorded, clips, request()))
            assertEquals(1, writeHttp.uploadCalls)
        }
    }

    @Test
    fun `upload history never consults or records a blank identity`() {
        val history = MemoryUploadHistory(setOf(""))
        val controller = controller(uploadHistory = history)
        val records = controller.uploadHistory<String?> { it }

        assertFalse(records.wasUploaded(""))
        assertFalse(records.wasUploaded(null))
        records.recordUploaded(" ")
        assertEquals(0, history.reads)
        assertFalse(history.contains(" "))
        records.recordUploaded("clip")
        assertTrue(records.wasUploaded("clip"))
    }

    @Test
    fun `late project result after a disconnect neither publishes nor queries another account`() = runTest {
        withReadyRoot { root ->
            lateinit var controller: FrameioDeliveryController
            val http = FakeHttp(onExecute = { controller.disconnect() })
            controller = connectedController(root, http = http)

            assertFailsWith<CancellationException> { controller.loadProjectsCaptured { true } }

            assertEquals(1, http.executeCalls)
            assertNull(controller.projectListing)
            assertNull(controller.selectedDestination)
            assertEquals(FrameioConnectionState.SIGNED_OUT, controller.connectionState)
        }
    }

    @Test
    fun `captured project facts work and refuse a reentrant account replacement`() = runTest {
        withReadyRoot { root ->
            val controller = connectedController(root)
            val listing = controller.loadProjectsCaptured { true }
            val created = controller.createProjectCaptured("SIMULATED project", listing) { true }

            assertTrue(controller.selectProjectCaptured(created, listing) { true })
            assertEquals("created", controller.selectedDestination?.projectID)
            assertFalse(controller.selectProjectCaptured(listing.listing.projects.first(), listing) {
                controller.disconnect(); true
            })
            assertNull(controller.selectedDestination)
            assertFailsWith<CancellationException> { controller.createProjectCaptured("old", listing) { true } }
        }
    }

    @Test
    fun `remote service lists at most eight uploadable projects and persists the choice`() = runTest {
        withReadyRoot { root ->
            val projects = listOf(FrameioProject("no-folder", "No folder", null)) +
                (1..10).map { FrameioProject("p$it", "Project $it", "folder-$it") }
            val core = FakeCore(projects = projects)
            val controller = connectedController(root, core = core)
            val service = controller.remoteService(current = { true })

            assertEquals("Frame.io", service.presentation.displayName)
            assertEquals("Uploading to Frame.io", service.presentation.progressCaption)
            assertTrue(service.skipsUploaded)
            val facts = service.observe()
            assertEquals(true, facts.configured)
            assertEquals(true, facts.connected)
            assertEquals(false, facts.onCameraNetwork)
            assertEquals("project", facts.savedProjectID)
            assertFalse(service.internet.needsHop())

            val listing = service.load()
            assertEquals((1..8).map { "p$it" }, listing.projects.map { it.id })
            assertTrue(listing.projects.all { it.uploadable == true })
            service.persist(listing.projects[2], listing.context)
            assertEquals("folder-3", controller.selectedDestination?.folderID)

            val created = service.create("New", listing.context)
            assertEquals(MonitorDeliveryProject("created", "Created", true, FrameioProject("created", "Created", "created-folder")), created)
        }
    }

    private fun request(
        project: FrameioProject? = null,
        context: FrameioCapturedProjectListing? = null,
        lease: FrameioInternetLease? = null,
        forceReupload: Boolean = false,
    ): FrameioRequest =
        MonitorDeliveryPreparedRequest(
            MonitorDeliveryDestination.REMOTE_UPLOAD,
            MonitorDeliveryExportConfiguration(Unit, Unit, forceReupload = forceReupload),
            MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            lease,
            project?.let { MonitorDeliveryProject(it.id, it.name, !it.rootFolderID.isNullOrBlank(), it) },
            context,
        )

    private suspend fun deliver(
        controller: FrameioDeliveryController,
        clips: List<Clip>,
        request: FrameioRequest,
    ): MonitorDeliveryBatchOutcome<File> =
        deliver(clips, assertNotNull(controller.remoteRun<Clip>(request, identity = { it.identity }, sidecar = { null })),
            // The popup's route travels with the request, as the shared selection passes it.
            request.internetLease?.let { controller.remoteService(current = { true }).internet }, request.internetLease)

    /** The shared app-scoped run every app composes, over cached SIMULATED originals. */
    private suspend fun deliver(
        clips: List<Clip>,
        run: MonitorDeliveryRemoteRun<Clip>,
        internet: MonitorDeliveryInternetService<FrameioInternetLease>? = null,
        lease: FrameioInternetLease? = null,
    ): MonitorDeliveryBatchOutcome<File> =
        MonitorDeliveryCoordinator(CoroutineScope(Dispatchers.Unconfined)).run(
            records = clips,
            destination = MonitorDeliveryDestination.REMOTE_UPLOAD,
            action = MonitorDeliveryPostExportAction.SYSTEM_SHARE,
            admission = MonitorDeliveryAdmission { true },
            source = MonitorDeliverySource<Clip, Unit, Unit>(
                MonitorDeliveryOriginalService({ true }, {}, { null }),
                prepare = { clip, _, _ -> clip.file },
                filename = { it.file.name },
            ),
            configuration = null,
            remote = run,
            photos = null,
            internet = internet,
            lease = lease,
        ) {}
}
