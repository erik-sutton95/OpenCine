package com.opencapture.opencine.appkitnative

import android.Manifest
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.opencine.appkit.MonitorVoiceTool
import com.opencapture.opencine.appkit.MonitorVoicePreferences
import com.opencapture.opencine.appkit.VoiceCommand
import com.opencapture.opencine.appkit.VoiceControlTarget
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The current foreground, on-device listening session. Only complete results can act. */
private class VoiceRecognition(private val context: Context, private val scope: CoroutineScope) {
    private var service: SpeechRecognizer? = null
    private var audio: MonitorVoiceAudio? = null
    private var alive: AtomicBoolean? = null
    private var action: Job? = null
    var armed by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)
        private set

    fun start(
        canListen: () -> Boolean,
        accepts: (VoiceCommand) -> Boolean,
        run: suspend (VoiceCommand, () -> Boolean) -> String,
    ) {
        if (armed || Build.VERSION.SDK_INT < 31 || !canListen()) return
        val recognizer = runCatching { SpeechRecognizer.createOnDeviceSpeechRecognizer(context) }
            .getOrElse { message = "Offline speech recognition is unavailable."; return }
        val current = AtomicBoolean(true)
        service = recognizer
        alive = current
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching {
                val input = MonitorVoiceAudio()
                audio = input
                input.configure(intent)
                input.start {
                    scope.launch {
                        if (current.get()) stop("The microphone is unavailable.")
                    }
                }
            }.onFailure {
                stop("The microphone is unavailable.")
                return
            }
        }
        armed = true
        message = "Listening for Camera commands"
        var speechBegan = false
        var receivedTerminalResult = false
        var lastCommand: VoiceCommand? = null
        var lastCommandAt = 0L

        fun complete(results: Bundle?, terminal: Boolean) {
            if (!current.get() || receivedTerminalResult) return
            if (!canListen()) {
                stop()
                return
            }
            receivedTerminalResult = terminal
            val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            val command = if (!terminal || speechBegan) text?.let { VoiceCommand.parse(it) } else null
            val now = SystemClock.elapsedRealtime()
            if (command == null || !accepts(command) || action?.isActive == true ||
                (command == lastCommand && now - lastCommandAt < 750)
            ) {
                if (terminal) stop("Voice listening ended. Tap Voice to resume.")
                return
            }
            lastCommand = command
            lastCommandAt = now
            action = scope.launch {
                val result = run(command) { current.get() && accepts(command) }
                if (current.get()) {
                    if (terminal) stop(result) else message = result
                }
            }
        }

        try {
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onSegmentResults(segmentResults: Bundle) = complete(segmentResults, terminal = false)
                override fun onResults(results: Bundle?) = complete(results, terminal = true)
                override fun onEndOfSegmentedSession() {
                    if (current.get()) stop("Voice listening ended. Tap Voice to resume.")
                }

                override fun onError(error: Int) {
                    if (!current.get()) return
                    val note = when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                            "Voice listening ended. Tap Voice to resume."
                        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The microphone is busy."
                        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Install English offline speech in Android settings."
                        else -> "Offline speech recognition ended."
                    }
                    stop(note)
                }

                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() { speechBegan = true }
                override fun onEndOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            recognizer.startListening(intent)
        } catch (_: RuntimeException) {
            stop("Offline speech recognition is unavailable.")
        }
    }

    fun stop(note: String? = null) {
        alive?.set(false)
        alive = null
        action?.cancel()
        action = null
        audio?.close()
        audio = null
        service?.cancel()
        service?.destroy()
        service = null
        armed = false
        message = note
    }

    fun permissionDenied() { message = "Allow microphone access to use voice control." }

    fun clearMessage(shown: String) { if (message == shown) message = null }
}

@Composable
public fun rememberMonitorVoiceTool(
    target: VoiceControlTarget?,
    stream: LiveStreamCoordinator?,
    preferences: MonitorVoicePreferences,
    settingsOpen: Boolean,
    canListen: () -> Boolean,
    execute: suspend (VoiceCommand, () -> Boolean, VoiceControlTarget) -> String,
): MonitorVoiceTool? {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val available = remember(context) {
        Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
    }
    if (!available) return null
    val recognition = remember(context, scope) { VoiceRecognition(context, scope) }
    val run by rememberUpdatedState(execute)
    val availableInMonitor by rememberUpdatedState(canListen)
    val voicePreferences by rememberUpdatedState(preferences)
    val selectedTarget by rememberUpdatedState(target)
    var permissionTarget by remember { mutableStateOf<VoiceControlTarget?>(null) }
    var settingsResumeTarget by remember { mutableStateOf<VoiceControlTarget?>(null) }
    fun sameSource(expected: VoiceControlTarget): Boolean = selectedTarget?.let {
        it.session == expected.session && it.epoch == expected.epoch && it.mode == expected.mode
    } == true
    fun arm(expected: VoiceControlTarget) {
        recognition.start(
            canListen = {
                sameSource(expected) && availableInMonitor() &&
                    context.getSystemService(KeyguardManager::class.java)?.isDeviceLocked != true
            },
            accepts = { voicePreferences.allows(it) },
        ) { command, current -> run(command, current, expected) }
    }
    val pauseForSettings = {
        if (recognition.armed) settingsResumeTarget = selectedTarget
        permissionTarget = null
        recognition.stop()
    }
    fun disarm() {
        settingsResumeTarget = null
        recognition.stop()
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val expected = permissionTarget
        permissionTarget = null
        if (granted && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            expected?.let { arm(it) }
        } else if (!granted) {
            recognition.permissionDenied()
        }
    }
    LaunchedEffect(target?.session, target?.epoch, target?.mode) {
        settingsResumeTarget = settingsResumeTarget?.takeIf(::sameSource)
        recognition.stop()
    }
    LaunchedEffect(settingsOpen) {
        if (settingsOpen) {
            pauseForSettings()
        } else {
            val expected = settingsResumeTarget
            settingsResumeTarget = null
            expected?.let { arm(it) }
        }
    }
    LaunchedEffect(recognition.message) {
        val message = recognition.message ?: return@LaunchedEffect
        delay(2_000)
        recognition.clearMessage(message)
    }
    DisposableEffect(lifecycle, stream) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE) disarm()
        }
        val screenLock = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                permissionTarget = null
                disarm()
            }
        }
        ContextCompat.registerReceiver(context, screenLock, IntentFilter(Intent.ACTION_SCREEN_OFF),
            ContextCompat.RECEIVER_NOT_EXPORTED)
        lifecycle.addObserver(observer)
        stream?.beforeMicrophoneCapture = {
            permissionTarget = null
            disarm()
        }
        onDispose {
            lifecycle.removeObserver(observer)
            context.unregisterReceiver(screenLock)
            stream?.beforeMicrophoneCapture = null
            disarm()
        }
    }
    if (target == null || settingsOpen) return null
    return MonitorVoiceTool(recognition.armed, recognition.message, toggle = {
        if (recognition.armed) disarm()
        else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) arm(target)
        else {
            permissionTarget = target
            permission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }, pauseForSettings = pauseForSettings)
}
