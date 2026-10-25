package com.opencapture.opencine.insta360.luna

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.net.Network
import android.os.ParcelUuid
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.media.CameraMediaService
import com.opencapture.opencine.media.MediaBrowseBinding
import com.opencapture.opencine.media.MediaServiceException
import com.opencapture.opencine.media.MediaServiceFailure
import com.opencapture.opencine.platform.CameraApJoinPolicy
import com.opencapture.opencine.platform.CameraApJoiner
import com.opencapture.opencine.platform.WifiLowLatencyLock
import com.opencapture.opencine.platform.withCredentialIO
import com.opencapture.opencine.insta360.shell.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID

/**
 * Luna transport, status and controls. No Compose or packet logs. Camera Wi-Fi credentials are kept
 * only through the host's [savedWifi] / [saveWifi] (Keystore-sealed on the app side), called off Main
 * through the shared credential IO helper, one transaction at a time.
 * [clientIdentityPreferences] names the SharedPreferences file holding the camera authorization
 * identity; the default keeps OpenInstaCine's saved approvals, another app passes its own.
 */
@SuppressLint("MissingPermission")
class LunaBackend(
    context: Context,
    private val savedWifi: (cameraId: String) -> Pair<String, String>? = { null },
    private val saveWifi: (cameraId: String, ssid: String, password: String) -> Unit = { _, _, _ -> },
    clientIdentityPreferences: String = DEFAULT_CLIENT_IDENTITY_PREFERENCES,
    /** Drops the camera's saved Wi-Fi from the host's store (forget); the approval identity stays. */
    private val forgetWifi: (cameraId: String) -> Unit = {},
    private val mediaTransfer: LunaMediaTransferPort? = null,
) : CameraBackend, CameraControls, CameraMediaStore, CoreSessionSource, LunaConnectPort, LunaMediaCatalogRecordSource {
    companion object {
        /** OpenInstaCine's persisted name. Changing it orphans every saved camera approval. */
        const val DEFAULT_CLIENT_IDENTITY_PREFERENCES = "openinstacine.client-identity"
    }
    private val context = context.applicationContext
    private val bluetooth = context.getSystemService(BluetoothManager::class.java)
    /** The shared camera-AP join: the Luna AP hands out 192.168.42.x; a lost AP ends the session at once. */
    private val joiner = CameraApJoiner(
        context,
        CameraApJoinPolicy(
            isCameraClientAddress = { it.startsWith("192.168.42.") },
            reassociationGraceMillis = 0,
            log = { _, _, message -> android.util.Log.i("LunaBackend", message) },
        ),
    ).also { it.onPathLost = { tcp?.fail(IllegalStateException("Camera Wi-Fi disconnected")) } }
    private val wifiLock = WifiLowLatencyLock(context)
    /** Serializes the host's blocking credential reads and writes (Keystore). */
    private val credentialTransaction = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    /** The host's Wi-Fi store is Keystore-sealed and blocks in Keystore2 backoff (the Pocket ANR,
     * OPENPOCKETCINE-ANDROID-13): never on Main, one transaction at a time. */
    private val preferences = context.getSharedPreferences(clientIdentityPreferences, Context.MODE_PRIVATE)
    private val clientIdentity: String = preferences.getString("authorization-id", null) ?: UUID.randomUUID().toString().uppercase().also { preferences.edit().putString("authorization-id", it).apply() }
    override val capabilities = setOf(
        CameraCapability.LIVE_VIDEO, CameraCapability.GIMBAL, CameraCapability.ZOOM,
        CameraCapability.FOCUS, CameraCapability.TRACKING, CameraCapability.CAMERA_SETTINGS,
        CameraCapability.RECORD, CameraCapability.CAMERA_MEDIA,
    )
    private val _phase = MutableStateFlow(ConnectionPhase.IDLE)
    override val phase = _phase.asStateFlow()
    private val _found = MutableStateFlow<List<CameraIdentity>>(emptyList())
    override val found = _found.asStateFlow()
    private val _connected = MutableStateFlow<CameraIdentity?>(null)
    override val connected = _connected.asStateFlow()
    private val _snapshot = MutableStateFlow(CameraSnapshot())
    override val snapshot = _snapshot.asStateFlow()
    private val _failure = MutableStateFlow<String?>(null)
    override val failure = _failure.asStateFlow()
    /** [failure] typed: reason, phase, the same copy and the recovery actions. */
    private val _failureDetail = MutableStateFlow<ConnectionFailure?>(null)
    override val failureDetail = _failureDetail.asStateFlow()
    override val attempt: Job? get() = connectJob
    private val _radioOn = MutableStateFlow(bluetooth?.adapter?.isEnabled == true)
    override val radioOn = _radioOn.asStateFlow()
    private val _scanBlocked = MutableStateFlow(false)
    override val scanBlocked = _scanBlocked.asStateFlow()
    private val _joinedSSID = MutableStateFlow<String?>(null)
    override val joinedSSID = _joinedSSID.asStateFlow()
    private val video = MutableSharedFlow<EncodedVideoFrame>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val frames: Flow<EncodedVideoFrame> = video.asSharedFlow()
    private val trackFlow = MutableSharedFlow<CameraTrackFrame>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val trackFrames: Flow<CameraTrackFrame> = trackFlow.asSharedFlow()
    private val noticeFlow = MutableSharedFlow<CameraNotice>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val notices: Flow<CameraNotice> = noticeFlow.asSharedFlow()
    /** Receive thread only. The camera repeats the frame with every video frame; only changes go out. */
    private var lastTrack: LunaTrackFrame? = null
    private var connectJob: Job? = null
    private var scanActive = false
    @Volatile private var socket: Socket? = null
    @Volatile private var tcp: LunaChannel? = null
    private var gatt: LunaGatt? = null
    // Status, merged across partial reads like the iOS session. Main thread only.
    private var settings: LunaPhotographySettings? = null
    private var device: LunaDeviceStatus? = null
    private var capture: LunaCaptureStatus? = null
    /** Active shooting mode (video until the camera says otherwise); its settings bank is [functionMode]. */
    private var mode = LunaShootingMode.VIDEO
    private val functionMode get() = mode.functionMode
    private var settingsRefresh: Job? = null
    private val _readout = MutableStateFlow(CameraReadout())
    override val readout = _readout.asStateFlow()
    /** OpenCineCore session for the current camera: recording, ISO, shutter and WB go through it. */
    private var session: LunaCameraSession? = null
    @Volatile private var mediaConnectionGeneration = 0L
    override val frameConnectionGeneration: Long get() = mediaConnectionGeneration
    private var connectedMedia: LunaMediaService? = null
    /** Native host preparation must validate this captured session/epoch before acting. */
    var prepareMediaLiveReturn: (suspend (MediaBrowseBinding) -> Unit)? = null
    private val mediaSourceState: LunaMediaSourceState?
        get() {
            val currentSession = session ?: return null
            val snapshot = currentSession.snapshots.value
            if (tcp == null || _phase.value != ConnectionPhase.LIVE ||
                snapshot.connection != ConnectionState.Ready || snapshot.authority != ControlAuthority.Owner) return null
            return LunaMediaSourceState(currentSession.id, snapshot.epoch, mediaConnectionGeneration)
        }
    private val mediaPort = object : LunaMediaSourcePort {
        override val mediaSourceState: LunaMediaSourceState? get() = this@LunaBackend.mediaSourceState
        override val mediaTransfer: LunaMediaTransferPort? get() = this@LunaBackend.mediaTransfer
        override val mediaThumbnailsAvailable: Boolean get() = true
        override suspend fun mediaRequest(request: LunaControl.Request, source: LunaMediaSourceState): ByteArray =
            requestMedia(request, source)
        override suspend fun encodeMediaThumbnail(response: ByteArray): ByteArray =
            this@LunaBackend.encodeMediaThumbnail(response)
        override suspend fun prepareMediaReturn(binding: MediaBrowseBinding) {
            prepareMediaLiveReturn?.invoke(binding)
        }
        override fun mediaBrowseChanged(active: Boolean, binding: MediaBrowseBinding, source: LunaMediaSourceState) {
            if (mediaSourceState != source) return
            if (active) { mediaPausedBinding = binding; livePaused = true }
            else if (mediaPausedBinding == binding) {
                mediaPausedBinding = null
                // Preserve the donor's restart grace; this timer is not a new source frame report.
                lastVideoAt.set(android.os.SystemClock.elapsedRealtime()); livePaused = false
            }
        }
    }
    private val lastVideoAt = java.util.concurrent.atomic.AtomicLong()
    /** Live video is stopped on purpose while the album is open; the watchdog must not fire. */
    @Volatile private var livePaused = false
    private var mediaPausedBinding: MediaBrowseBinding? = null
    private val scanner = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val record = result.scanRecord ?: return
            if (record.serviceUuids?.contains(ParcelUuid(LunaGatt.SERVICE)) != true) return
            val name = record.deviceName ?: result.device.name ?: "Luna Ultra"
            val identity = CameraIdentity(result.device.address, name, "Insta360 Luna Ultra")
            _found.update { cameras -> (cameras.filterNot { it.id == identity.id } + identity).sortedBy { it.advertisedName } }
        }
        override fun onScanFailed(code: Int) { scanActive = false; _scanBlocked.value = true; fail(LunaFailures.scanFailed(code)); setPhase(ConnectionPhase.FAILED) }
    }
    override fun startScan() {
        if (connectJob?.isActive == true) return
        _radioOn.value = bluetooth?.adapter?.isEnabled == true
        if (!_radioOn.value) { _scanBlocked.value = true; setPhase(ConnectionPhase.IDLE); return }
        _failure.value = null; _failureDetail.value = null
        stopScan()
        // Null while the radio is turning off (SDK 37 annotates it; 36 left it a platform type).
        val leScanner = bluetooth.adapter.bluetoothLeScanner
        if (leScanner == null) { _radioOn.value = false; _scanBlocked.value = true; setPhase(ConnectionPhase.IDLE); return }
        try {
            leScanner.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(LunaGatt.SERVICE)).build()), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanner)
            scanActive = true; _scanBlocked.value = false; setPhase(ConnectionPhase.SCANNING)
        } catch (_: SecurityException) { _scanBlocked.value = true; fail(LunaFailures.discoveryDenied); setPhase(ConnectionPhase.FAILED) }
    }
    private fun fail(failure: ConnectionFailure) { _failure.value = failure.message; _failureDetail.value = failure }
    override fun stopScan() { if (scanActive) runCatching { bluetooth?.adapter?.bluetoothLeScanner?.stopScan(scanner) }; scanActive = false }
    override fun hasSeen(id: String): Boolean = _found.value.any { it.id == id }
    override suspend fun hasSavedWiFi(id: String): Boolean =
        withCredentialIO({ true }, transaction = credentialTransaction) { savedWifi(id) != null }
    override fun connect(id: String) {
        connectedMedia?.retire()
        mediaConnectionGeneration += 1
        val frameGeneration = mediaConnectionGeneration
        val previous = connectJob
        previous?.cancel()
        socket?.close()
        stopScan()
        connectJob = scope.launch {
            previous?.join()
            _failure.value = null; _failureDetail.value = null
            _connected.value = _found.value.firstOrNull { it.id == id } ?: CameraIdentity(id, "Luna Ultra", "Insta360 Luna Ultra")
            try { runCamera(id, frameGeneration) }
            catch (error: Exception) {
                // A withTimeout inside (GATT, greeting) is a CancellationException too; only a real cancel propagates.
                if (error is CancellationException && !isActive) throw error
                fail(LunaFailures.connect(_phase.value, advertising = _found.value.any { it.id == id }))
                setPhase(ConnectionPhase.FAILED)
            } finally { cleanup() }
        }
    }
    private suspend fun runCamera(id: String, frameGeneration: Long): Unit = coroutineScope {
        val identity = clientIdentity.toByteArray()
        // Initiator 1 follows the hardware-verified bootstrap; IDs are this installation's own.
        val authBody = LunaWire.blob(1, identity) + LunaWire.integer(2, 1) + LunaWire.blob(3, identity)
        // iOS `connect`: Bluetooth first whenever the camera advertises (it wakes the camera AP, which the
        // Luna turns off when idle); saved Wi-Fi is the fallback for a camera this run has not seen.
        val current = { frameGeneration == mediaConnectionGeneration }
        val saved = withCredentialIO(current, transaction = credentialTransaction) { savedWifi(id) }
        val network = saved?.takeIf { _found.value.none { it.id == id } }?.let { (ssid, password) ->
            setPhase(ConnectionPhase.JOINING_WIFI)
            try { joinRetrying(ssid, password, budgetMs = 20_000).also { _joinedSSID.value = ssid } }
            catch (error: Exception) {
                if (error is CancellationException && !isActive) throw error
                android.util.Log.i("LunaBackend", "luna: saved Wi-Fi join failed, falling back to Bluetooth")
                null
            }
        } ?: bootstrapOverBluetooth(id, authBody, current)
        // The join bound the process: media HTTP (192.168.42.1:80) goes through the shared OkHttp
        // client, as for DJI. Live view pulls frame by frame, so the radio must not doze.
        wifiLock.acquire()
        setPhase(ConnectionPhase.OPENING_DATALINK)
        val cameraSocket = withContext(Dispatchers.IO) {
            network.socketFactory.createSocket().also { socket = it; it.tcpNoDelay = true; it.soTimeout = 10_000; it.connect(InetSocketAddress("192.168.42.1", 6666), 8_000) }
        }
        runLive(cameraSocket, authBody, frameGeneration)
    }

    /** BLE approval and the encrypted Wi-Fi credential read, then the camera AP join (credentials saved). */
    private suspend fun bootstrapOverBluetooth(id: String, authBody: ByteArray, current: () -> Boolean): Network {
        setPhase(ConnectionPhase.CONNECTING_GATT)
        val ble = LunaGatt(context); gatt = ble
        ble.connect(checkNotNull(bluetooth?.adapter).getRemoteDevice(id))
        val link = ble.channel
        val initial = LunaWire.bytes(link.request(8, LunaWire.options(48, 30)), 2)
        check(LunaWire.text(initial, 48) == "Insta360 Luna Ultra") { "Unexpected camera model" }
        _snapshot.value = CameraSnapshot(firmware = LunaWire.text(initial, 30))
        setPhase(ConnectionPhase.PAIRING)
        val schemes = LunaWire.schemes(link.request(240))
        check(3L in schemes) { "AES-GCM is not supported" }
        val pair = LunaWire.keyPair()
        link.key = LunaWire.exchange(pair, link.request(241, LunaWire.integer(1, 3) + LunaWire.blob(2, LunaWire.publicBytes(pair))))
        val verified = LunaWire.bytes(link.request(8, LunaWire.options(48, 30), encrypted = true), 2)
        check(LunaWire.text(verified, 48) == "Insta360 Luna Ultra")
        when (LunaWire.number(link.request(39, authBody), 1)) {
            0L -> Unit
            1L -> {
                setPhase(ConnectionPhase.AWAITING_APPROVAL)
                link.request(86, LunaWire.integer(1, 1))
                withTimeout(120_000) {
                    while (true) {
                        val approval = link.approvals.receive()
                        if (LunaWire.number(approval.body, 2) !in 0L..1L) continue
                        check(LunaWire.number(approval.body, 1) == 0L) { "Camera did not approve this client" }; break
                    }
                }
            }
            else -> error("Unknown camera authorization result")
        }
        setPhase(ConnectionPhase.READING_WIFI_CREDS)
        val wifi = LunaWire.bytes(LunaWire.bytes(link.request(8, LunaWire.options(36, 37, 43), encrypted = true), 2), 36)
        val ssid = LunaWire.text(wifi, 1); val password = LunaWire.text(wifi, 2)
        check(ssid.isNotBlank() && password.length in 8..63)
        ble.close(); gatt = null
        withCredentialIO(current, transaction = credentialTransaction) { saveWifi(id, ssid, password) }
        setPhase(ConnectionPhase.JOINING_WIFI)
        // iOS joins for up to 120 s after the BLE handoff: the AP can take most of a minute to come up.
        return joinRetrying(ssid, password, budgetMs = 120_000).also { _joinedSSID.value = ssid }
    }

    private suspend fun runLive(cameraSocket: Socket, authBody: ByteArray, frameGeneration: Long): Unit = coroutineScope {
        lastVideoAt.set(android.os.SystemClock.elapsedRealtime())
        val channel = LunaChannel(
            send = { bytes -> withContext(Dispatchers.IO) { cameraSocket.getOutputStream().write(bytes); cameraSocket.getOutputStream().flush() } },
            video = { bytes, tick ->
                lastVideoAt.set(android.os.SystemClock.elapsedRealtime())
                video.tryEmit(EncodedVideoFrame(bytes, tick, frameGeneration))
            },
            notify = { message -> val note = LunaNotification.parse(message.code, message.body); scope.launch { handle(note) } },
            track = { frame -> if (frame != lastTrack) { lastTrack = frame; frame.shared?.let(trackFlow::tryEmit) } },
            imu = { samples ->
                val now = android.os.SystemClock.elapsedRealtime()
                synchronized(headPitch) { headPitch.ingest(samples, commanding = now - gimbalCommandAt < 500) }
                imuAt = now
            },
        )
        lastTrack = null
        tcp = channel
        val receiver = launch(Dispatchers.IO) {
            try {
                val buffer = ByteArray(65536)
                while (isActive) {
                    val count = cameraSocket.getInputStream().read(buffer)
                    check(count >= 0) { "Camera closed TCP" }
                    if (count > 0) channel.receive(buffer.copyOf(count))
                }
            } catch (error: Exception) { channel.fail(error) }
        }
        var heartbeat: Job? = null
        var watchdog: Job? = null
        var poll: Job? = null
        try {
            channel.raw(LunaWire.prefix)
            withTimeout(8_000) { channel.greeting.await() }
            heartbeat = launch { try { while (isActive) { channel.heartbeat(); delay(2_000) } } catch (error: Exception) { channel.fail(error) } }
            val tcpInfo = LunaWire.bytes(channel.request(8, LunaWire.options(48, 30)), 2)
            check(LunaWire.text(tcpInfo, 48) == "Insta360 Luna Ultra")
            check(LunaWire.number(channel.request(39, authBody), 1) == 0L) { "TCP identity was not authorized" }
            channel.request(15)
            setPhase(ConnectionPhase.LIVE)
            // Mount the inherited decoder/render host before asking for the first keyframe.
            delay(350)
            // Shooting view first: without it the gimbal stays asleep pointing down.
            val wake = LunaControl.accessCameraFileState(LunaControl.SHOOTING_VIEW_ACCESS_STATE)
            runCatching { channel.request(wake.code, wake.body) }
            channel.request(1, LunaWire.liveBody)
            lastVideoAt.set(android.os.SystemClock.elapsedRealtime())
            launch { syncClock() }
            // Keyframes, bounded single-flight live restarts, then session recovery (`LunaFeedStall`).
            watchdog = launch {
                val stall = LunaFeedStall()
                while (isActive) {
                    delay(1_000)
                    val now = android.os.SystemClock.elapsedRealtime()
                    val silence = if (livePaused) 0.0 else (now - lastVideoAt.get()) / 1_000.0
                    when (stall.tick(silence, now / 1_000.0)) {
                        LunaFeedStall.Action.NONE -> {}
                        LunaFeedStall.Action.REQUEST_KEYFRAME ->
                            launch { runCatching { channel.request(LunaControl.keyframe.code, LunaControl.keyframe.body) } }
                        LunaFeedStall.Action.RESTART_LIVE -> launch {
                            runCatching { channel.request(LunaControl.stopLive.code, LunaControl.stopLive.body) }
                            runCatching { channel.request(wake.code, wake.body) }
                            runCatching { channel.request(LunaControl.startLive.code, LunaControl.startLive.body) }
                            stall.restartFinished()
                        }
                        LunaFeedStall.Action.ESCALATE -> {
                            channel.fail(IllegalStateException("No live video received"))
                            break
                        }
                    }
                }
            }
            // Same cadence as iOS: capture state every second (REC timer), battery and storage every 5 s.
            poll = launch {
                refreshStatus()
                var tick = 0
                while (isActive) {
                    delay(1_000)
                    tick += 1
                    refreshCapture()
                    if (tick % 5 == 0) {
                        refreshDevice(LunaControl.statusRequest)
                        refreshRemainingTime()
                    }
                }
            }
            throw channel.failure.await()
        } finally {
            withContext(NonCancellable) { withTimeoutOrNull(1_500) { runCatching { channel.request(2) } } }
            poll?.cancel(); watchdog?.cancel(); heartbeat?.cancel(); cameraSocket.close(); receiver.cancel(); channel.close(); tcp = null
            settingsRefresh?.cancel(); livePaused = false; mediaPausedBinding = null
            settings = null; device = null; capture = null; mode = LunaShootingMode.VIDEO; publish()
        }
    }
    /**
     * iOS `joinRetrying`: 35 s attempts until [budgetMs] runs out, 3 s apart, alternating two join
     * configurations (plain, then a directed hidden-SSID probe for an AP that is not beaconing yet), and
     * done as soon as the phone is on 192.168.42.x (auto-join, or the operator joined in Settings).
     */
    private suspend fun joinRetrying(ssid: String, password: String, budgetMs: Long): Network {
        val deadline = android.os.SystemClock.elapsedRealtime() + budgetMs
        var attempt = 0
        while (true) {
            attempt += 1
            if (joiner.adoptJoinedNetwork() || joinNetwork(ssid, password, hidden = attempt % 2 == 0) || joiner.adoptJoinedNetwork()) {
                joiner.network()?.let { return it }
            }
            android.util.Log.i("LunaBackend", "luna: Wi-Fi join attempt $attempt failed")
            check(android.os.SystemClock.elapsedRealtime() < deadline) { "Camera Wi-Fi did not come up" }
            delay(3_000)
        }
    }
    /** One specifier request, released when it does not connect within 35 s (no scan wait: iOS asks at once). */
    private suspend fun joinNetwork(ssid: String, password: String, hidden: Boolean): Boolean =
        withTimeoutOrNull(36_000) {
            joiner.join(ssid, password, timeoutMillis = 35_000, hidden = hidden, preScanMillis = 0)
        } == true
    private fun cleanup() {
        gatt?.close(); gatt = null
        runCatching { socket?.close() }; socket = null
        joiner.release()
        wifiLock.release()
        _joinedSSID.value = null
    }
    override fun disconnect() {
        connectedMedia?.retire(); mediaConnectionGeneration += 1
        stopScan(); connectJob?.cancel(); runCatching { socket?.close() }
        setPhase(ConnectionPhase.IDLE); _failure.value = null; _failureDetail.value = null
    }
    override suspend fun forget(id: String) {
        withCredentialIO({ true }, transaction = credentialTransaction) { forgetWifi(id) }
    }
    override fun close() { disconnect(); cleanup(); scope.cancel() }
    override fun sceneActive(active: Boolean) {
        // A foreground reconnect belongs to CamerasModel: the app asks it on resume so the card
        // and wizard show the attempt. A backend dial here connected outside every attempt, with
        // no progress and no monitor opened (IA-320).
    }

    // Status. Same reads as iOS `LunaCameraBackend.refreshStatus` and its notification handling.
    private suspend fun call(request: LunaControl.Request): ByteArray? {
        val channel = tcp ?: return null
        return runCatching { channel.request(request.code, request.body) }.getOrNull()
    }
    /**
     * iOS `syncCameraClock`: the Luna's timecode is time of day from its own clock. Set it like the
     * official app on connect (options 12/13/175), then to the millisecond with cmd 214, twice,
     * each stamped at send (a GET round trip on the camera AP is about 4 ms).
     */
    private suspend fun syncClock() {
        val zone = java.util.TimeZone.getDefault()
        val now = System.currentTimeMillis()
        call(LunaControl.setClock(now / 1000, zone.getOffset(now) / 1000, zone.id)) ?: return
        for (count in 0..1) call(LunaControl.syncTimeAccurate(System.currentTimeMillis(), count))
        android.util.Log.i("LunaBackend", "luna: camera clock synced")
    }
    private fun publish() { _readout.value = LunaReadout.readout(settings, device, capture) }
    private fun applyDevice(status: LunaDeviceStatus) {
        device = device?.merge(status) ?: status
        status.shootingMode?.let { mode = it }
        session?.ingest(status)
        publish()
    }
    private fun applySettings(update: LunaPhotographySettings) {
        // A reply for another bank (a mode change in flight) is not this mode's settings.
        if (update.functionMode != null && update.functionMode != functionMode) return
        settings = settings?.merge(update) ?: update
        session?.ingest(update)
        publish()
    }
    private fun applyCapture(status: LunaCaptureStatus) { capture = status; session?.ingest(status); publish() }
    private suspend fun refreshCapture() {
        call(LunaControl.captureStatus)?.let { runCatching { LunaCaptureStatus.fromResponse(it) }.getOrNull() }?.let(::applyCapture)
    }
    /** Every phase change also tells the session; LIVE is a new control epoch. */
    private fun setPhase(phase: ConnectionPhase) {
        _phase.value = phase
        session?.linkChanged(phase)
    }

    override fun openSession(): LunaCameraSession {
        connectedMedia?.retire(); connectedMedia = null
        val previous = session
        val next = LunaCameraSession(
            send = { request -> (tcp ?: throw IllegalStateException("The camera connection is not open.")).request(request.code, request.body) },
            functionMode = { functionMode },
            readSettings = ::refreshSettings,
            readCapture = ::refreshCapture,
            scope = scope,
            backendCapabilities = { capabilities },
            noteGimbalCommand = { gimbalCommandAt = android.os.SystemClock.elapsedRealtime() },
        )
        next.configureLens(zoomRange)
        session = next
        previous?.closeNow(com.opencapture.opencine.core.SessionCloseReason.REPLACED)
        if (_phase.value == ConnectionPhase.LIVE) next.linkChanged(ConnectionPhase.LIVE)
        return next
    }

    override fun mediaService(session: CameraSessionID): CameraMediaService? {
        if (this.session?.id != session) return null
        connectedMedia?.takeIf { it.sessionID == session }?.let { return it }
        return LunaMediaService(session, mediaPort, scope).also { connectedMedia = it }
    }

    public override fun mediaCatalogRecord(asset: com.opencapture.opencine.media.MediaAssetID,
        binding: MediaBrowseBinding): LunaMediaCatalogRecord? = connectedMedia?.catalogRecord(asset, binding)

    private suspend fun requestMedia(request: LunaControl.Request, source: LunaMediaSourceState): ByteArray {
        if (mediaSourceState != source) throw MediaServiceException(MediaServiceFailure.RETIRED)
        val currentSession = session ?: throw MediaServiceException(MediaServiceFailure.RETIRED)
        val reply = currentSession.mediaRequest(request, source.epoch)
        if (mediaSourceState != source) throw MediaServiceException(MediaServiceFailure.RETIRED)
        return reply
    }

    private suspend fun refreshDevice(request: LunaControl.Request) {
        call(request)?.let { runCatching { LunaDeviceStatus.parse(it) }.getOrNull() }?.let(::applyDevice)
    }
    private suspend fun refreshSettings() {
        call(LunaControl.getPhotographyOptions(LunaControl.settingTypes, functionMode))
            ?.let { runCatching { LunaPhotographySettings.parse(it) }.getOrNull() }?.let(::applySettings)
    }
    /** Option 99 for the active mode: remaining record time per card, as the official app polls it. */
    private suspend fun refreshRemainingTime() {
        call(LunaControl.remainingTimeRequest(functionMode))
            ?.let { runCatching { LunaPhotographySettings.parse(it) }.getOrNull() }?.let(::applySettings)
    }
    /** One full read: device status, the active mode (so the right settings bank), settings, capture state. */
    private suspend fun refreshStatus() {
        refreshDevice(LunaControl.statusRequest)
        refreshDevice(LunaControl.shootingModeRequest)
        refreshSettings()
        refreshRemainingTime()
        refreshCapture()
    }
    private suspend fun handle(note: LunaNotification) {
        when (note) {
            is LunaNotification.Capture -> applyCapture(note.status)
            // iOS `applyTrackingState`: 1 / 2 locked, anything else ended (the camera cancelled it).
            is LunaNotification.Tracking -> noticeFlow.tryEmit(CameraNotice.Tracking(note.state == 1L || note.state == 2L))
            // Capture ended on the camera: re-read the capture state now so REC clears without waiting for the poll.
            is LunaNotification.CaptureStopped -> {
                noticeFlow.tryEmit(CameraNotice.CaptureStopped(note.errorCode))
                refreshCapture()
            }
            is LunaNotification.PhotographyChanged -> applySettings(note.settings)
            // The notice carries a partial view; re-read the whole status.
            is LunaNotification.SubMode, is LunaNotification.Storage, is LunaNotification.Battery -> {
                refreshDevice(LunaControl.statusRequest)
                refreshDevice(LunaControl.shootingModeRequest)
                refreshSettings()
            }
            else -> Unit
        }
    }
    override fun requestSettingsRefresh() {
        settingsRefresh?.cancel()
        settingsRefresh = scope.launch { delay(400); refreshSettings() }
    }

    // Controls. Same requests as the iOS session; each needs the live TCP control channel.
    override val zoomRange: ClosedFloatingPointRange<Double> = 1.0..LunaControl.MAXIMUM_ZOOM
    private suspend fun send(build: () -> LunaControl.Request): Boolean {
        val channel = tcp ?: return false
        if (_phase.value != ConnectionPhase.LIVE) return false
        val request = runCatching(build).getOrElse { return false }
        return runCatching { channel.request(request.code, request.body) }.isSuccess
    }
    private suspend fun commonSetting(value: com.opencapture.opencine.core.SettingValue): Boolean {
        val common = session ?: return false
        val receipt = common.submit(
            com.opencapture.opencine.core.CameraCommand(
                com.opencapture.opencine.core.CameraCommandIntent.Set(value),
                com.opencapture.opencine.core.CommandPreconditions(common.snapshots.value),
            ),
        )
        return when (receipt.stage) {
            com.opencapture.opencine.core.CommandStage.Accepted,
            com.opencapture.opencine.core.CommandStage.AwaitingObservation,
            com.opencapture.opencine.core.CommandStage.Confirmed -> true
            else -> false
        }
    }
    override suspend fun setZoom(factor: Double) =
        commonSetting(com.opencapture.opencine.core.SettingValue.Zoom(factor.coerceIn(zoomRange)))
    override suspend fun gimbalStick(pan: Double, tilt: Double): Boolean {
        if (pan != 0.0 || tilt != 0.0) gimbalCommandAt = android.os.SystemClock.elapsedRealtime()
        return send { LunaControl.gimbalStick(pan, tilt) }
    }
    // iOS: GET_ANGLE with a 1 s timeout, SET_ANGLE fire and forget within 2 s.
    override suspend fun gimbalAngle(): CameraGimbalAngle? {
        val channel = tcp?.takeIf { _phase.value == ConnectionPhase.LIVE } ?: return null
        val request = LunaControl.gimbalGetAngle
        val reply = withTimeoutOrNull(1_000) { runCatching { channel.request(request.code, request.body) }.getOrNull() } ?: return null
        return runCatching { LunaControl.gimbalAngle(reply) }.getOrNull()?.let { CameraGimbalAngle(it.pitch.toDouble(), it.yaw.toDouble()) }
    }
    override suspend fun gimbalSetAngle(pitch: Double, yaw: Double): Boolean {
        gimbalCommandAt = android.os.SystemClock.elapsedRealtime()
        return withTimeoutOrNull(2_000) { send { LunaControl.gimbalSetAngle(pitch.toFloat(), yaw.toFloat()) } } ?: false
    }
    private val headPitch = LunaHeadPitch()
    @Volatile private var imuAt = 0L
    @Volatile private var gimbalCommandAt = 0L
    override val gimbalHeadPitch: Double?
        get() = synchronized(headPitch) {
            headPitch.pitchDeg.takeIf { headPitch.sampleCount > 0 && android.os.SystemClock.elapsedRealtime() - imuAt <= 300 }
        }
    override suspend fun gimbalRecenter() = send { LunaControl.gimbal(2) }
    override suspend fun gimbalFlip() = send { LunaControl.gimbal(3) }
    /** Official ROI centred on the tap, kept inside the frame. */
    override suspend fun tapFocus(x: Double, y: Double) = send {
        val w = LunaControl.FOCUS_WIDTH
        val h = LunaControl.FOCUS_HEIGHT
        LunaControl.tapFocus((x - w / 2).coerceIn(0.0, 1 - w), (y - h / 2).coerceIn(0.0, 1 - h), w, h, functionMode)
    }
    override suspend fun startTracking(x: Double, y: Double, width: Double, height: Double) =
        send { LunaControl.openTracking(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0), width.coerceIn(0.0, 1.0), height.coerceIn(0.0, 1.0)) }
    override suspend fun stopTracking() = send { LunaControl.cancelTracking }
    override suspend fun takePhoto() = send { LunaControl.takePicture() }
    override suspend fun setExposureBias(thirds: Int) = send { LunaControl.exposureBias(thirds / 3.0, functionMode) }
    override suspend fun setColorProfile(profile: CameraColorProfile) = with(LunaReadout) { send { LunaControl.colorMode(colors.key(profile), functionMode) } }
    override suspend fun setRecordFormat(id: Long) = send { LunaControl.recordResolution(id, functionMode) }
    override suspend fun setShootingMode(mode: CameraShootingMode): Boolean {
        val luna = with(LunaReadout) { shootingModes.key(mode) }
        this.mode = luna
        val ok = send { luna.request() }
        if (ok) scope.launch { refreshStatus() }
        return ok
    }
    override suspend fun setGimbalMode(mode: CameraGimbalMode) = with(LunaReadout) { send { LunaControl.gimbalMode(gimbalModes.key(mode), functionMode) } }
    override suspend fun setGimbalSpeed(speed: CameraGimbalSpeed) = with(LunaReadout) { send { LunaControl.gimbalFollowSpeed(gimbalSpeeds.key(speed), functionMode) } }
    override suspend fun setFocusMode(mode: CameraFocusMode): Boolean = when (mode) {
        CameraFocusMode.SINGLE -> commonSetting(com.opencapture.opencine.core.SettingValue.FocusMode(com.opencapture.opencine.core.FocusMode.SINGLE))
        CameraFocusMode.CONTINUOUS -> commonSetting(com.opencapture.opencine.core.SettingValue.FocusMode(com.opencapture.opencine.core.FocusMode.CONTINUOUS))
        CameraFocusMode.PRODUCT_SHOWCASE -> send { LunaControl.afMode(6, functionMode) }
    }
    override suspend fun setFaceMetering(on: Boolean) = send { LunaControl.faceMetering(on, functionMode) }

    // Media: cmd 13/38 list, cmd 11 thumbnail, cmd 12 delete; files over HTTP on 192.168.42.1.
    private suspend fun media(request: LunaControl.Request): ByteArray {
        val channel = checkNotNull(tcp) { "Connect the camera to browse clips." }
        check(_phase.value == ConnectionPhase.LIVE) { "Connect the camera to browse clips." }
        return channel.request(request.code, request.body)
    }
    override suspend fun listMedia(): List<CameraMediaItem> {
        runCatching { media(LunaControl.accessCameraFileState(LunaControl.ALBUM_ACCESS_STATE)) }
        val uris = LunaMediaFile.list(media(LunaControl.fileList())).first
        val infos = runCatching { LunaMediaFile.infoList(media(LunaControl.fileInfoList())) }.getOrDefault(emptyList()).associateBy { it.uri }
        return uris.map { infos[it] ?: LunaMediaFile(it) }.filterNot { it.isProxy }.map(LunaReadout::mediaItem)
    }
    override suspend fun thumbnailJpeg(path: String): ByteArray {
        return encodeMediaThumbnail(media(LunaControl.fileExtra(path, extraType = 2)))
    }
    private suspend fun encodeMediaThumbnail(response: ByteArray): ByteArray {
        val thumbnail = LunaThumbnail.parse(response)
        return withContext(Dispatchers.Default) {
            val bitmap = android.graphics.Bitmap.createBitmap(thumbnail.argb(), thumbnail.width, thumbnail.height, android.graphics.Bitmap.Config.ARGB_8888)
            java.io.ByteArrayOutputStream().also { bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, it); bitmap.recycle() }.toByteArray()
        }
    }
    override suspend fun deleteMedia(path: String) { media(LunaControl.deleteFiles(path)) }
    override suspend fun pauseLive() { livePaused = true; runCatching { media(LunaControl.stopLive) } }
    override suspend fun resumeLive() {
        runCatching { media(LunaControl.stopLive) }
        lastVideoAt.set(android.os.SystemClock.elapsedRealtime())
        livePaused = false
        runCatching { media(LunaControl.accessCameraFileState(LunaControl.SHOOTING_VIEW_ACCESS_STATE)) }
        runCatching { media(LunaControl.startLive) }
    }
}
