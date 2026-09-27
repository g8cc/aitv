package com.kidtv.aitv

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService

/**
 * Raw PCM capture with explicit input-device selection.
 *
 * The `record` plugin cannot choose which microphone an Android TV uses, and on
 * many sets the default device is silent while a USB or remote mic is present.
 * This channel enumerates input devices and streams 16-bit PCM from the chosen
 * one so the app can test and lock in a working microphone.
 */
class AudioInputPlugin : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL = "com.kidtv.aitv/audio"
        private const val EVENT_CHANNEL = "com.kidtv.aitv/audio/pcm"
        private const val FRAME_MS = 100

        /** Ordered by preference for speech recognition; not every TV supports all. */
        private val SOURCES = listOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION to "voice_recognition",
            MediaRecorder.AudioSource.UNPROCESSED to "unprocessed",
            MediaRecorder.AudioSource.MIC to "mic",
            MediaRecorder.AudioSource.DEFAULT to "default",
        )
    }

    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var record: AudioRecord? = null
    private var executor: ExecutorService? = null
    private var eventSink: EventChannel.EventSink? = null
    private val captureGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /** Stop flag owned by the running capture loop. A quick stop->start must
     *  not revive the old loop: it checks this flag, not shared state, so two
     *  AudioRecord pumps can never feed the sink at once. */
    @Volatile private var loopStop: java.util.concurrent.atomic.AtomicBoolean? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        stopCapture()
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopCapture()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInputDevices" -> result.success(describeInputDevices())
            "start" -> startCapture(call, result)
            "stop" -> {
                stopCapture()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun audioManager(): AudioManager? =
        appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private fun inputDevices(): List<AudioDeviceInfo> =
        audioManager()?.getDevices(AudioManager.GET_DEVICES_INPUTS)?.toList() ?: emptyList()

    private fun describeInputDevices(): List<Map<String, Any?>> =
        inputDevices().mapIndexed { index, device ->
            mapOf(
                "index" to index,
                "productName" to device.productName.toString(),
                "type" to device.type,
                "address" to device.address,
                "sampleRates" to device.sampleRates.toList(),
                "channelCounts" to device.channelCounts.toList(),
            )
        }

    /** Name wins over index so that a partially changed device list still resolves. */
    private fun resolveDevice(devices: List<AudioDeviceInfo>, name: String?, index: Int): AudioDeviceInfo? {
        if (!name.isNullOrEmpty()) {
            devices.firstOrNull { it.productName.toString() == name }?.let { return it }
        }
        return if (index in devices.indices) devices[index] else null
    }

    private fun startCapture(call: MethodCall, result: MethodChannel.Result) {
        if (record != null || executor != null) {
            stopCapture()
        }
        val context = appContext
        if (context == null) {
            result.error("no_context", "插件未注册", null)
            return
        }
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission", "缺少录音权限", null)
            return
        }
        val sampleRate = call.argument<Int>("sampleRate") ?: 16000
        val index = call.argument<Int>("index") ?: -1
        val name = call.argument<String>("productName")
        val devices = inputDevices()
        val device = resolveDevice(devices, name, index)
        if (index >= 0 && device == null) {
            result.error("no_device", "找不到输入设备 #$index（$name），当前共 ${devices.size} 个", null)
            return
        }

        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
        if (minBuffer <= 0) {
            result.error("unsupported", "${sampleRate}Hz 单声道 PCM16 不受支持", null)
            return
        }
        val bufferSize = minBuffer * 4

        for ((source, sourceName) in SOURCES) {
            val rec = tryBuild(source, sampleRate, channelConfig, encoding, bufferSize, device)
                ?: continue
            record = rec
            startPump(rec, result, sampleRate, sourceName)
            return
        }
        result.error("start_failed", "所有音频源都无法采集，请尝试其它输入设备", null)
    }

    private fun tryBuild(
        source: Int,
        sampleRate: Int,
        channelConfig: Int,
        encoding: Int,
        bufferSize: Int,
        device: AudioDeviceInfo?,
    ): AudioRecord? {
        val rec = try {
            AudioRecord(source, sampleRate, channelConfig, encoding, bufferSize)
        } catch (e: IllegalArgumentException) {
            return null
        } catch (e: SecurityException) {
            return null
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return null
        }
        if (device != null && !rec.setPreferredDevice(device)) {
            rec.release()
            return null
        }
        try {
            rec.startRecording()
        } catch (e: IllegalStateException) {
            rec.release()
            return null
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            try {
                rec.stop()
            } catch (_: IllegalStateException) {
            }
            rec.release()
            return null
        }
        return rec
    }

    private fun startPump(
        rec: AudioRecord,
        result: MethodChannel.Result,
        sampleRate: Int,
        sourceName: String,
    ) {
        val generation = captureGeneration.get()
        val stopFlag = java.util.concurrent.atomic.AtomicBoolean(true)
        loopStop = stopFlag
        val pool = Executors.newSingleThreadExecutor()
        executor = pool
        val chunkBytes = sampleRate * 2 / 1000 * FRAME_MS
        val buffer = ByteArray(chunkBytes)
        pool.execute {
            try {
                while (stopFlag.get()) {
                    val read = try {
                        rec.read(buffer, 0, buffer.size)
                    } catch (e: Exception) {
                        break
                    }
                    if (read <= 0) break
                    val copy = buffer.copyOf(read)
                    mainHandler.post {
                        if (captureGeneration.get() == generation) {
                            eventSink?.success(copy)
                        }
                    }
                }
            } finally {
                // Stopping from another thread while read() is in flight is not
                // safe, so the recorder is closed here.
                if (record === rec) record = null
                if (loopStop === stopFlag) loopStop = null
                release(rec)
            }
        }
        result.success(
            mapOf(
                "sampleRate" to sampleRate,
                "audioSource" to sourceName,
                "productName" to (rec.preferredDevice?.productName?.toString() ?: "系统默认"),
            )
        )
    }

    private fun stopCapture() {
        captureGeneration.incrementAndGet()
        loopStop?.set(false)
        loopStop = null
        val activeRecord = record
        record = null
        if (activeRecord != null) {
            try {
                activeRecord.stop()
            } catch (_: IllegalStateException) {
            }
        }
        val pool = executor
        executor = null
        pool?.shutdownNow()
    }

    private fun release(rec: AudioRecord) {
        try {
            if (rec.recordingState == AudioRecord.RECORDSTATE_RECORDING) rec.stop()
        } catch (_: IllegalStateException) {
        }
        rec.release()
    }
}
