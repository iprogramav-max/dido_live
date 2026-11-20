package com.didolive.dido_live

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRouting
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private open class AudioRouteException(
        message: String,
        val actualRoute: Map<String, Any>? = null,
    ) : IllegalStateException(message)

    private class OutputRouteException(
        message: String,
        actualRoute: Map<String, Any>? = null,
    ) : AudioRouteException(message, actualRoute)

    companion object {
        private const val CHANNEL = "dido_live/walkie"
        private const val EVENTS = "dido_live/walkie_events"
        private const val BUSY_CHANNEL = "dido_live_busy"
        private const val SAMPLE_RATE = 16000
        private const val MAX_RECORD_MS = 30000L
        private const val CALIBRATION_RECORD_MS = 2500L
    }

    private lateinit var audioManager: AudioManager
    private lateinit var audioRoutingHandler: Handler
    private var eventSink: EventChannel.EventSink? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var recognitionIntent: Intent? = null
    private var recognizerActive = false
    private var modeActive = false
    private var captureActive = AtomicBoolean(false)
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var recordingBuffer: ByteArrayOutputStream? = null
    private var captureOutputId: Int? = null
    private var captureInputInfo: Map<String, Any>? = null
    private var captureRequestedOutputInfo: Map<String, Any>? = null
    @Volatile private var calibrationActive = false
    @Volatile private var calibrationRecord: AudioRecord? = null
    private val calibrationResults = mutableMapOf<String, Boolean>()
    @Volatile private var playbackActive = false
    @Volatile private var playbackTrack: AudioTrack? = null
    @Volatile private var activityPaused = false
    private val handler = Handler(Looper.getMainLooper())
    private val activeTones = mutableSetOf<ToneGenerator>()
    private val captureTimeout = Runnable { finishCapture(play = true, timedOut = true) }
    private var lastCommandAt = 0L

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            if (action == BluetoothDevice.ACTION_ACL_CONNECTED ||
                action == BluetoothDevice.ACTION_ACL_DISCONNECTED
            ) {
                Handler(Looper.getMainLooper()).post {
                    val probe = try {
                        probeRoutes()
                    } catch (_: SecurityException) {
                        eventSink?.success(
                            mapOf(
                                "type" to "error",
                                "message" to "Concede el permiso Bluetooth para comprobar las rutas.",
                            ),
                        )
                        return@post
                    }
                    if ((modeActive && !hasSelectedRoutes(probe)) ||
                                (calibrationActive && !hasBluetoothRoutes(probe))
                    ) {
                                val wasCalibrating = calibrationActive
                        stopWalkie()
                        eventSink?.success(
                            mapOf(
                                        "type" to if (wasCalibrating) "route_failure" else "disconnected",
                                        "calibration" to wasCalibrating,
                                "probe" to probe,
                                        "message" to "Se perdió el micrófono o la salida Bluetooth. La operación se detuvo.",
                            )
                        )
                    } else {
                        eventSink?.success(mapOf("type" to "bluetooth_changed", "probe" to probe))
                    }
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        val routingThread = HandlerThread("dido-audio-routing").apply { start() }
        audioRoutingHandler = Handler(routingThread.looper)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "probe" -> result.success(probeRoutes())
                    "calibrateSide" -> {
                        val outputId = call.argument<Int>("outputId")
                        val inputId = call.argument<Int>("inputId")
                        val side = call.argument<String>("side")
                        if (outputId == null || inputId == null ||
                            side !in setOf("L", "R") ||
                            !canCalibrateOutput(outputId, inputId)
                        ) {
                            result.error(
                                "CALIBRATION_ROUTE_NOT_READY",
                                "Se requiere un micrófono Bluetooth y una salida Bluetooth activa.",
                                probeRoutes(),
                            )
                        } else if (calibrationActive || playbackActive || modeActive) {
                            result.error(
                                "AUDIO_BUSY",
                                "Detén el audio actual antes de iniciar la calibración.",
                                null,
                            )
                        } else {
                            calibrationActive = true
                            thread(name = "dido-walkie-calibration", isDaemon = true) {
                                runCalibration(outputId, inputId, side!!)
                            }
                            result.success(true)
                        }
                    }
                    "setCalibrationResult" -> {
                        val outputId = call.argument<Int>("outputId")
                        val side = call.argument<String>("side")
                        val outcome = call.argument<String>("outcome")
                        val output = outputId?.let(::findBluetoothOutput)
                        if (output == null || side !in setOf("L", "R") ||
                            outcome !in setOf("isolated", "shared", "wrong_channel", "silent")
                        ) {
                            result.error(
                                "INVALID_CALIBRATION_RESULT",
                                "No se pudo asociar la confirmación a una salida Bluetooth activa.",
                                null,
                            )
                        } else {
                            val key = calibrationKey(output, side!!)
                            synchronized(calibrationResults) {
                                calibrationResults[key] = outcome == "isolated"
                                if (outcome == "shared") {
                                    calibrationResults.remove(calibrationKey(output, if (side == "L") "R" else "L"))
                                }
                            }
                            result.success(true)
                        }
                    }
                    "start" -> {
                        val probe = probeRoutes()
                        val leftId = call.argument<Int>("leftOutputId")
                        val rightId = call.argument<Int>("rightOutputId")
                        val inputId = call.argument<Int>("inputId")
                        if (leftId == null || rightId == null ||
                            inputId == null ||
                            !hasSelectedRoutes(probe, leftId, rightId) ||
                            !canCalibrateOutput(leftId, inputId) ||
                            !hasPassedCalibration(leftId, "L") ||
                            !hasPassedCalibration(rightId, "R")
                        ) {
                            result.error(
                                "LOCAL_ROUTE_NOT_READY",
                                "Completa y aprueba las pruebas auditivas L y R para las salidas seleccionadas.",
                                probe,
                            )
                        } else {
                            try {
                                startWalkie(leftId, rightId, inputId)
                                result.success(probe)
                            } catch (error: Exception) {
                                stopWalkie()
                                val code = if (error is AudioRouteException) {
                                    "LOCAL_ROUTE_NOT_READY"
                                } else {
                                    "LOCAL_WALKIE_FAILED"
                                }
                                result.error(code, error.message, probe)
                            }
                        }
                    }
                    "stop" -> {
                        stopWalkie()
                        result.success(true)
                    }
                    "releaseAudioResources" -> {
                        stopWalkie()
                        resetAudioRouting()
                        result.success(true)
                    }
                    "showBusyNotification" -> {
                        val sender = call.argument<String>("sender") ?: "Alguien"
                        showBusyNotification(sender)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(bluetoothReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(bluetoothReceiver, filter)
        }
    }

    override fun onPause() {
        activityPaused = true
        stopWalkie()
        resetAudioRouting()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        activityPaused = false
    }

    override fun onDestroy() {
        stopWalkie()
        try {
            unregisterReceiver(bluetoothReceiver)
        } catch (_: IllegalArgumentException) {
        }
        if (::audioRoutingHandler.isInitialized) {
            audioRoutingHandler.looper.quitSafely()
        }
        super.onDestroy()
    }

    @SuppressLint("MissingPermission")
    private fun probeRoutes(): Map<String, Any> {
        val inputs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
                .filter { isBluetooth(it) }
                .map { deviceInfo(it) }
        } else emptyList()
        val detectedOutputs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .filter { isBluetooth(it) }
                .map { deviceInfo(it) }
        } else emptyList()
        val outputs = detectedOutputs.distinctBy { it["id"] }
        val activeOutputId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.communicationDevice?.takeIf(::isBluetooth)?.id
        } else {
            null
        }
        val missing = mutableListOf<String>()
        if (inputs.isEmpty()) missing += "Micrófono Bluetooth de entrada"
        if (outputs.isEmpty()) missing += "Salida Bluetooth"
        val ready = LocalWalkieAudio.canCalibrate(inputs.size, outputs.size)
        val details = (inputs + detectedOutputs).joinToString(", ") {
            "${it["name"]} (${it["type"]}, id ${it["id"]})"
        }
        return mapOf(
            "ready" to ready,
            "reason" to if (ready) {
                "Calibración disponible. Ejecuta las pruebas de escucha L y R antes de activar el envío."
            } else {
                "No se puede calibrar: ${missing.joinToString(", ")}. Bluetooth detectado: ${details.ifBlank { "ninguno" }}."
            },
            "inputs" to inputs,
            "outputs" to outputs,
            "activeOutputId" to (activeOutputId ?: 0),
            "detectedOutputs" to detectedOutputs,
            "missing" to missing,
        )
    }

    @SuppressLint("MissingPermission")
    private fun deviceInfo(device: AudioDeviceInfo): Map<String, Any> = mapOf(
        "id" to device.id,
        "name" to device.productName.toString(),
        "type" to device.type,
        "function" to deviceFunction(device.type),
        "address" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) device.address else "",
        "channels" to device.channelCounts.toList(),
    )

    private fun deviceFunction(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Manos libres / llamada"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Audio multimedia"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "Auricular Bluetooth LE"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "Salida Bluetooth LE"
        else -> "Audio Bluetooth"
    }

    private fun isBluetooth(device: AudioDeviceInfo): Boolean =
        device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
            device.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
            device.type == AudioDeviceInfo.TYPE_BLE_SPEAKER ||
            device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP

    private fun hasBluetoothRoutes(probe: Map<String, Any>): Boolean {
        val outputs = probe["outputs"] as? List<*> ?: return false
        return outputs.isNotEmpty() && (probe["inputs"] as? List<*>)?.isNotEmpty() == true
    }

    private fun hasSelectedRoutes(
        probe: Map<String, Any>,
        leftOutputId: Int? = leftOutputIdForRightSpeaker,
        rightOutputId: Int? = rightOutputIdForLeftSpeaker,
    ): Boolean {
        if (!hasBluetoothRoutes(probe)) return false
        return leftOutputId?.let(::findBluetoothOutput) != null &&
            rightOutputId?.let(::findBluetoothOutput) != null
    }

    @SuppressLint("MissingPermission")
    private fun findBluetoothOutput(id: Int): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { it.id == id && isBluetooth(it) }
    }

    @SuppressLint("MissingPermission")
    private fun findBluetoothInput(id: Int): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.id == id && isBluetooth(it) }
    }

    @SuppressLint("MissingPermission")
    private fun canCalibrateOutput(outputId: Int, inputId: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return findBluetoothInput(inputId) != null && findBluetoothOutput(outputId) != null
    }

    private fun calibrationKey(device: AudioDeviceInfo, side: String): String =
        "${device.address}:${device.id}:$side"

    private fun hasPassedCalibration(outputId: Int, side: String): Boolean {
        val output = findBluetoothOutput(outputId) ?: return false
        return synchronized(calibrationResults) {
            calibrationResults[calibrationKey(output, side)] == true
        }
    }

    @SuppressLint("MissingPermission")
    private fun runCalibration(outputId: Int, inputId: Int, side: String) {
        val previousMode = audioManager.mode
        var record: AudioRecord? = null
        var capturedInput: Map<String, Any>? = null
        var requestedOutput: Map<String, Any>? = null
        try {
            val input = findBluetoothInput(inputId)
                ?: throw AudioRouteException("No se encontró el micrófono Bluetooth.")
            val output = findBluetoothOutput(outputId)
                ?: throw OutputRouteException("La salida Bluetooth seleccionada ya no está disponible.")
            requestedOutput = deviceInfo(output)
            val minBytes = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBytes <= 0) {
                throw AudioRouteException("Android no admite captura PCM a 16 kHz.")
            }
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            audioManager.isSpeakerphoneOn = false
            record = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(minBytes, 4096))
                .build()
            calibrationRecord = record
            if (record.state != AudioRecord.STATE_INITIALIZED ||
                !record.setPreferredDevice(input)
            ) {
                throw AudioRouteException("No se pudo seleccionar la entrada del micrófono Bluetooth.")
            }
            record.startRecording()
            if (!confirmInputRoute(record, input)) {
                throw AudioRouteException(
                    "Android no confirmó la entrada del micrófono Bluetooth.",
                    record.routedDevice?.let(::deviceInfo),
                )
            }
            capturedInput = record.routedDevice?.let(::deviceInfo)
            handler.post {
                eventSink?.success(
                    mapOf(
                        "type" to "calibration_recording",
                        "side" to side,
                        "durationMs" to CALIBRATION_RECORD_MS,
                        "effectiveInput" to capturedInput,
                        "requestedOutput" to requestedOutput,
                    ),
                )
            }

            val buffer = ByteArray(2048)
            val recording = ByteArrayOutputStream()
            val requiredBytes = (SAMPLE_RATE * 2L * CALIBRATION_RECORD_MS / 1000).toInt()
            while (recording.size() < requiredBytes && calibrationActive) {
                val read = record.read(
                    buffer,
                    0,
                    minOf(buffer.size, requiredBytes - recording.size()),
                )
                if (read <= 0) {
                    throw AudioRouteException("La captura Bluetooth se interrumpió durante la prueba.")
                }
                recording.write(buffer, 0, read)
            }
            if (!calibrationActive) return
            record.stop()
            record.release()
            record = null
            calibrationRecord = null
            Thread.sleep(300)
            if (!calibrationActive) return

            val pcm = recording.toByteArray()
            if (pcm.isEmpty()) throw AudioRouteException("No se capturó audio para calibrar.")
            playbackActive = true
            val effectiveOutput = playPcmStereo(pcm, output.id, side)
            handler.post {
                eventSink?.success(
                    mapOf(
                        "type" to "calibration_playback_done",
                        "side" to side,
                        "outputId" to output.id,
                        "effectiveInput" to capturedInput,
                        "requestedOutput" to requestedOutput,
                        "effectiveOutput" to effectiveOutput,
                    ),
                )
            }
        } catch (error: Exception) {
            handler.post {
                eventSink?.success(
                    mapOf(
                        "type" to if (error is AudioRouteException) "route_failure" else "error",
                        "message" to "Falló la calibración ${side}: ${error.message}",
                        "calibration" to true,
                        "effectiveInput" to capturedInput,
                        "requestedOutput" to requestedOutput,
                        "actualOutput" to (error as? AudioRouteException)?.actualRoute,
                    ),
                )
            }
        } finally {
            try {
                record?.stop()
            } catch (_: Exception) {
            }
            record?.release()
            if (calibrationRecord === record) calibrationRecord = null
            playbackActive = false
            calibrationActive = false
            audioManager.mode = if (activityPaused) {
                AudioManager.MODE_NORMAL
            } else {
                previousMode
            }
            resetAudioRouting()
            handler.post {
                eventSink?.success(mapOf("type" to "calibration_finished"))
            }
        }
    }

    private fun startWalkie(leftOutputId: Int, rightOutputId: Int, inputId: Int) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            throw IllegalStateException("Android no tiene un servicio de reconocimiento de voz disponible.")
        }
        modeActive = true
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = false
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
            setRecognitionListener(createRecognitionListener())
        }
        recognitionIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "es-MX")
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "es-MX")
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
        }
        lastCommandAt = 0L
        recognitionErrorReported = false
        leftOutputIdForRightSpeaker = leftOutputId
        rightOutputIdForLeftSpeaker = rightOutputId
        selectedBluetoothInputId = inputId
        startRecognition()
        eventSink?.success(mapOf("type" to "listening"))
    }

    private var leftOutputIdForRightSpeaker: Int? = null
    private var rightOutputIdForLeftSpeaker: Int? = null
    private var selectedBluetoothInputId: Int? = null
    private var recognitionErrorReported = false

    private fun createRecognitionListener() = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onError(error: Int) {
            recognizerActive = false
            if (!recognitionErrorReported &&
                (error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ||
                    error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ||
                    error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS)
            ) {
                recognitionErrorReported = true
                eventSink?.success(
                    mapOf(
                        "type" to "error",
                        "message" to "El reconocimiento offline en español no está disponible o no tiene permiso (código $error).",
                    ),
                )
            }
            if (modeActive) handler.postDelayed({ startRecognition() }, 350)
        }
        override fun onResults(results: Bundle?) {
            recognizerActive = false
            handleRecognized(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION))
            if (modeActive) handler.postDelayed({ startRecognition() }, 250)
        }
        override fun onPartialResults(partialResults: Bundle?) {
            handleRecognized(
                partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION),
            )
        }
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun startRecognition() {
        if (!modeActive || recognizerActive || playbackActive) return
        val recognizer = speechRecognizer ?: return
        val intent = recognitionIntent ?: return
        try {
            recognizerActive = true
            recognizer.startListening(intent)
        } catch (error: Exception) {
            recognizerActive = false
            eventSink?.success(
                mapOf("type" to "error", "message" to "No se pudo iniciar el reconocimiento: ${error.message}"),
            )
            handler.postDelayed({ startRecognition() }, 1000)
        }
    }

    private fun handleRecognized(results: List<String>?) {
        if (!modeActive || results.isNullOrEmpty()) return
        val command = when (LocalWalkieAudio.recognizeCommand(results.joinToString(" "))) {
            WalkieCommand.LEFT_SPEAKS -> "left_speaks"
            WalkieCommand.RIGHT_SPEAKS -> "right_speaks"
            WalkieCommand.CHANGE -> "change"
            WalkieCommand.CANCEL -> "cancel"
            null -> return
        }
        val now = System.currentTimeMillis()
        if (now - lastCommandAt < 1200) return
        lastCommandAt = now
        when (command) {
            "left_speaks" -> {
                val destinationId = rightOutputIdForLeftSpeaker ?: return
                if (!captureActive.get()) {
                    val delayMs = emitAccepted(command, "R")
                    handler.postDelayed(
                        { if (modeActive && !captureActive.get()) beginCapture(destinationId) },
                        delayMs,
                    )
                }
            }
            "right_speaks" -> {
                val destinationId = leftOutputIdForRightSpeaker ?: return
                if (!captureActive.get()) {
                    val delayMs = emitAccepted(command, "L")
                    handler.postDelayed(
                        { if (modeActive && !captureActive.get()) beginCapture(destinationId) },
                        delayMs,
                    )
                }
            }
            "change" -> if (captureActive.get()) {
                emitAccepted(command, "")
                finishCapture(play = true, timedOut = false, trimTrailingMs = 700)
            }
            "cancel" -> if (captureActive.get()) {
                emitAccepted(command, "")
                finishCapture(play = false, timedOut = false)
            }
        }
    }

    private fun emitAccepted(command: String, destination: String): Long {
        val beepCount = when (command) {
            "left_speaks" -> 1
            "right_speaks" -> 2
            "change" -> 3
            else -> 4
        }
        val beepDelay = playBips(beepCount)
        eventSink?.success(
            mapOf("type" to "command", "command" to command, "destination" to destination),
        )
        return beepDelay
    }

    private fun playBips(count: Int): Long {
        val tone = ToneGenerator(AudioManager.STREAM_MUSIC, 65)
        activeTones += tone
        repeat(count) { index ->
            handler.postDelayed(
                { tone.startTone(ToneGenerator.TONE_PROP_BEEP, 100) },
                index * 180L,
            )
        }
        val duration = count * 180L + 100L
        handler.postDelayed(
            {
                tone.release()
                activeTones.remove(tone)
            },
            duration,
        )
        return duration
    }

    private fun beginCapture(outputId: Int) {
        val input = selectedBluetoothInputId?.let(::findBluetoothInput)
        if (input == null) {
            eventSink?.success(mapOf("type" to "error", "message" to "El micrófono Bluetooth ya no está disponible."))
            startRecognition()
            return
        }
        val minBytes = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBytes <= 0) {
            eventSink?.success(mapOf("type" to "error", "message" to "Android no admite captura PCM a 16 kHz."))
            startRecognition()
            return
        }
        val record = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBytes, 4096))
            .build()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !record.setPreferredDevice(input)) {
            record.release()
            stopWalkie()
            eventSink?.success(
                mapOf(
                    "type" to "route_failure",
                    "message" to "Android rechazó la ruta del micrófono Bluetooth.",
                ),
            )
            startRecognition()
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            eventSink?.success(mapOf("type" to "error", "message" to "No se pudo inicializar la grabación."))
            startRecognition()
            return
        }
        captureOutputId = outputId
        captureRequestedOutputInfo = findBluetoothOutput(outputId)?.let(::deviceInfo)
        audioRecord = record
        recordingBuffer = ByteArrayOutputStream()
        captureActive.set(true)
        try {
            record.startRecording()
        } catch (error: Exception) {
            captureActive.set(false)
            record.release()
            audioRecord = null
            eventSink?.success(mapOf("type" to "error", "message" to "Falló la captura: ${error.message}"))
            startRecognition()
            return
        }
        if (!confirmInputRoute(record, input)) {
            captureActive.set(false)
            try {
                record.stop()
            } catch (_: Exception) {
            }
            record.release()
            audioRecord = null
            stopWalkie()
            eventSink?.success(
                mapOf(
                    "type" to "route_failure",
                    "message" to "Android no confirmó la entrada del micrófono Bluetooth.",
                ),
            )
            return
        }
        captureInputInfo = record.routedDevice?.let(::deviceInfo)
        captureActive.set(true)
        recordingThread = thread(name = "dido-local-record", isDaemon = true) {
            val buffer = ByteArray(2048)
            val recording = recordingBuffer!!
            while (captureActive.get()) {
                val count = record.read(buffer, 0, buffer.size)
                if (count > 0) {
                    synchronized(recording) {
                        recording.write(buffer, 0, count)
                    }
                } else if (count < 0) {
                    handler.post {
                        eventSink?.success(mapOf("type" to "error", "message" to "La entrada Bluetooth dejó de capturar audio."))
                        finishCapture(play = false, timedOut = false)
                    }
                    break
                }
            }
        }
        handler.removeCallbacks(captureTimeout)
        handler.postDelayed(captureTimeout, MAX_RECORD_MS)
        eventSink?.success(mapOf("type" to "recording", "destination" to if (outputId == leftOutputIdForRightSpeaker) "L" else "R"))
    }

    private fun confirmInputRoute(record: AudioRecord, input: AudioDeviceInfo): Boolean {
        val routeChanged = CountDownLatch(1)
        val listener = AudioRouting.OnRoutingChangedListener { router ->
            if (router.routedDevice?.id == input.id) routeChanged.countDown()
        }
        record.addOnRoutingChangedListener(listener, audioRoutingHandler)
        return try {
            if (record.routedDevice?.id != input.id) {
                routeChanged.await(1500, TimeUnit.MILLISECONDS)
            }
            record.routedDevice?.id == input.id
        } finally {
            record.removeOnRoutingChangedListener(listener)
        }
    }

    private fun finishCapture(
        play: Boolean,
        timedOut: Boolean,
        trimTrailingMs: Long = 0,
    ) {
        if (!captureActive.getAndSet(false)) return
        handler.removeCallbacks(captureTimeout)
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        recordingThread?.join(500)
        audioRecord?.release()
        audioRecord = null
        recordingThread = null
        val recordedBytes = recordingBuffer?.toByteArray() ?: ByteArray(0)
        val trimBytes = (SAMPLE_RATE * 2L * trimTrailingMs / 1000)
            .coerceAtMost(recordedBytes.size.toLong())
            .toInt()
        val bytes = recordedBytes.copyOf(recordedBytes.size - trimBytes)
        recordingBuffer = null
        val outputId = captureOutputId
        captureOutputId = null
        val effectiveInput = captureInputInfo
        val requestedOutput = captureRequestedOutputInfo
        captureInputInfo = null
        captureRequestedOutputInfo = null
        eventSink?.success(
            mapOf(
                "type" to if (play) "message_ready" else "recording_cancelled",
                "timedOut" to timedOut,
                "durationMs" to bytes.size * 1000L / (SAMPLE_RATE * 2),
                "effectiveInput" to effectiveInput,
                "requestedOutput" to requestedOutput,
            ),
        )
        if (play && bytes.isNotEmpty() && outputId != null) {
            pauseRecognition()
            playbackActive = true
            thread(name = "dido-local-playback", isDaemon = true) {
                try {
                    val effectiveOutput = playPcmStereo(
                        bytes,
                        outputId,
                        if (outputId == leftOutputIdForRightSpeaker) "L" else "R",
                    )
                    handler.post {
                        playbackActive = false
                        eventSink?.success(
                            mapOf(
                                "type" to "playback_done",
                                "timedOut" to timedOut,
                                "effectiveInput" to effectiveInput,
                                "requestedOutput" to requestedOutput,
                                "effectiveOutput" to effectiveOutput,
                            ),
                        )
                        startRecognition()
                    }
                } catch (error: Exception) {
                    handler.post {
                        playbackActive = false
                        val routeFailed = error is AudioRouteException
                        if (routeFailed) stopWalkie()
                        eventSink?.success(
                            mapOf(
                                "type" to if (routeFailed) "route_failure" else "error",
                                "message" to "Falló la reproducción: ${error.message}",
                                "effectiveInput" to effectiveInput,
                                "requestedOutput" to requestedOutput,
                                "actualOutput" to (error as? AudioRouteException)?.actualRoute,
                            ),
                        )
                        if (!routeFailed) startRecognition()
                    }
                }
            }
        } else {
            startRecognition()
        }
    }

    private fun pauseRecognition() {
        try {
            speechRecognizer?.cancel()
        } catch (_: Exception) {
        }
        recognizerActive = false
    }

    private fun playPcmStereo(
        monoPcm: ByteArray,
        outputId: Int,
        side: String,
    ): Map<String, Any> {
        val device = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.id == outputId && isBluetooth(it) }
        } else null) ?: throw IllegalStateException("La salida Bluetooth seleccionada ya no está disponible.")
        val stereo = LocalWalkieAudio.panMonoPcm(monoPcm, side)
        val minBytes = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBytes <= 0) throw IllegalStateException("Android no admite reproducción PCM estéreo.")
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBytes, stereo.size))
            .build()
        playbackTrack = track
        val routeConfirmed = CountDownLatch(1)
        val routeListener = AudioRouting.OnRoutingChangedListener { router ->
            if (router.routedDevice?.id == outputId) routeConfirmed.countDown()
        }
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                !track.setPreferredDevice(device)
            ) {
                throw OutputRouteException("Android rechazó la salida Bluetooth asignada a $side.")
            }
            track.addOnRoutingChangedListener(routeListener, audioRoutingHandler)
            track.play()
            if (track.routedDevice?.id != outputId &&
                !routeConfirmed.await(1500, TimeUnit.MILLISECONDS)
            ) {
                throw OutputRouteException("Android no confirmó la ruta física asignada a $side.")
            }
            if (track.routedDevice?.id != outputId) {
                throw OutputRouteException(
                    "Android dirigió el audio a una salida distinta de $side.",
                    track.routedDevice?.let(::deviceInfo),
                )
            }
            var offset = 0
            while (offset < stereo.size) {
                if (track.routedDevice?.id != outputId) {
                    throw OutputRouteException(
                        "La reproducción salió de la ruta Bluetooth seleccionada.",
                        track.routedDevice?.let(::deviceInfo),
                    )
                }
                val count = track.write(stereo, offset, stereo.size - offset)
                if (count <= 0) throw IllegalStateException("La salida Bluetooth dejó de reproducir audio.")
                offset += count
            }
            val frameCount = stereo.size / 4
            val drainDeadline = System.currentTimeMillis() + 5000
            while (track.playbackHeadPosition < frameCount &&
                System.currentTimeMillis() < drainDeadline
            ) {
                if (track.routedDevice?.id != outputId) {
                    throw OutputRouteException(
                        "La salida Bluetooth cambió durante la reproducción.",
                        track.routedDevice?.let(::deviceInfo),
                    )
                }
                Thread.sleep(10)
            }
            if (track.playbackHeadPosition < frameCount) {
                throw IllegalStateException("La salida Bluetooth no terminó de reproducir el audio.")
            }
            val effective = track.routedDevice
                ?: throw OutputRouteException("Android no informó la salida efectiva.")
            if (effective.id != outputId) {
                throw OutputRouteException(
                    "Android cambió la salida durante la reproducción.",
                    deviceInfo(effective),
                )
            }
            track.stop()
            return deviceInfo(effective)
        } finally {
            track.removeOnRoutingChangedListener(routeListener)
            playbackTrack = null
            track.release()
        }
    }

    private fun stopWalkie() {
        modeActive = false
        playbackActive = false
        calibrationActive = false
        try {
            calibrationRecord?.stop()
        } catch (_: Exception) {
        }
        handler.removeCallbacksAndMessages(null)
        activeTones.toList().forEach {
            it.stopTone()
            it.release()
        }
        activeTones.clear()
        try {
            playbackTrack?.stop()
        } catch (_: Exception) {
        }
        captureActive.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        audioRecord?.release()
        audioRecord = null
        recordingThread = null
        recordingBuffer = null
        captureOutputId = null
        captureInputInfo = null
        captureRequestedOutputInfo = null
        pauseRecognition()
        speechRecognizer?.destroy()
        speechRecognizer = null
        recognitionIntent = null
        leftOutputIdForRightSpeaker = null
        rightOutputIdForLeftSpeaker = null
        selectedBluetoothInputId = null
        resetAudioRouting()
    }

    private fun resetAudioRouting() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        }
        audioManager.mode = AudioManager.MODE_NORMAL
        audioManager.isSpeakerphoneOn = false
    }

    private fun showBusyNotification(sender: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    BUSY_CHANNEL,
                    "Intentos de voz",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Avisos de PTT recibido mientras Walkie Talkie local está activo"
                },
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, BUSY_CHANNEL)
        } else {
            android.app.Notification.Builder(this)
        }
        manager.notify(
            42031,
            builder.setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("Intento de voz")
                .setContentText("$sender intentó hablarte mientras estabas en Walkie Talkie.")
                .setAutoCancel(true)
                .build(),
        )
    }
}
