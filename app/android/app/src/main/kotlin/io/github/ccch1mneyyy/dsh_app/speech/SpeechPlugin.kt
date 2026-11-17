package io.github.ccch1mneyyy.dsh_app.speech

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.nativemedia.MicArbiter
import io.github.ccch1mneyyy.dsh_app.nativemedia.NativeTrial
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGates
import io.github.ccch1mneyyy.dsh_app.nativemedia.TurnPause

/**
 * Speech audio for 朗读 and 语音通话: MethodChannel `dsh/speech` (lib/speech/speech_audio.dart).
 *
 * Playback — one [PcmStream] at a time: `open` {id, rate, call, levels}, `write` {id, bytes} (answers
 * the bytes waiting to play, -1 when the stream is gone), `waiting` {id}, `end` {id}, `stop`. Opening a stream stops the one before. A `call` stream plays as voice
 * communication (so the echo canceller hears it); others as media, ducking other apps.
 *
 * Calls — `callStart` {bargeIn, pause} answers "ok", "permission" or "microphone"; `callStop`; `callMute`
 * {on}; `callBargeIn` {on}; `callPause` {pause: quick|normal|patient}; `callPlaying` {on} (another player of the app's voice, such as the phone's
 * own text-to-speech, started or stopped); `callSpeaker` {on}. A call holds the app's one microphone
 * ([MicArbiter]). Routing is hybrid: the loudspeaker (the main case) stays in MODE_NORMAL so the
 * volume keys really drive STREAM_MUSIC — which is what actually drives this PCM track's gain. The
 * earpiece needs MODE_IN_COMMUNICATION + setCommunicationDevice, because on vendor HALs (Pixel 4)
 * only the telephony/vocoder path reaches the physical earpiece; while there the volume keys are
 * pinned to STREAM_VOICE_CALL and won't change this media track — an accepted trade-off (earpiece
 * is held to the ear, so its preset level is usually enough). The screen stays on meanwhile (a
 * backgrounded app gets no microphone).
 *
 * Events come back as `event` calls with a `type`: `play` {what: start|done|stopped|error, id},
 * `playLevel` {id, value}, `speechStart` {over}, `utterance` {wav, ms}, `micLevel` {value},
 * `callError` {reason}. When the person speaks over a call stream with barge-in on, the stream is
 * stopped here before `speechStart` goes out, so the voice stops at once.
 */
class SpeechPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private val audio by lazy { context.getSystemService(AudioManager::class.java) }

    private var stream: PcmStream? = null
    private var focus: AudioFocusRequest? = null

    private var capture: CallCapture? = null
    private var mic = 0
    private var previousMode: Int? = null
    /** 是否因切到听筒而进了通信模式（Android 12+）；退出/挂断时据此还原。 */
    private var communicationActive = false
    private var speaker = true
    private var externalPlaying = false
    private var activity: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        stream?.stop()
        stream = null
        endCall()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        if (capture != null) keepScreenOn(true)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        keepScreenOn(false)
        activity = null
    }

    private fun keepScreenOn(on: Boolean) {
        val window = activity?.activity?.window ?: return
        runCatching {
            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> result.success(open(call))
            "write" -> {
                val id = call.argument<String>("id")
                val bytes = call.argument<ByteArray>("bytes")
                val s = stream
                result.success(if (s != null && s.id == id && bytes != null) s.write(bytes) else -1L)
            }
            "waiting" -> {
                val s = stream
                result.success(if (s != null && s.id == call.argument<String>("id")) s.waiting() else -1L)
            }
            "end" -> {
                val s = stream
                if (s != null && s.id == call.argument<String>("id")) s.end()
                result.success(null)
            }
            "stop" -> {
                stream?.stop()
                result.success(null)
            }
            "duck" -> {
                val s = stream
                if (s != null && s.id == call.argument<String>("id")) s.duck(call.argument<Boolean>("on") == true)
                result.success(null)
            }
            "callStart" -> result.success(
                startCall(call.argument<Boolean>("bargeIn") ?: true, TurnPause.of(call.argument<String>("pause"))),
            )
            "callPause" -> {
                capture?.pause = TurnPause.of(call.argument<String>("pause"))
                result.success(null)
            }
            "callStop" -> {
                endCall()
                result.success(null)
            }
            "callMute" -> {
                capture?.muted = call.argument<Boolean>("on") == true
                result.success(null)
            }
            "callBargeIn" -> {
                capture?.bargeIn = call.argument<Boolean>("on") != false
                result.success(null)
            }
            "callPlaying" -> {
                externalPlaying = call.argument<Boolean>("on") == true
                syncPlaying()
                result.success(null)
            }
            "callSpeaker" -> {
                speaker = call.argument<Boolean>("on") != false
                // 路由切换完全交给 route()：听筒进通信模式 + setCommunicationDevice(earpiece)，
                // 免提回 MODE_NORMAL。不要再碰音轨的 preferredDevice——它会和通信模式的
                // 设备选择打架，正是方案 X 里 patch 建到 earpiece、轨却留在 SPEAKER 的原因。
                if (capture != null) route()
                result.success(speaker)
            }
            else -> result.notImplemented()
        }
    }

    // ── Playback ──────────────────────────────────────────────────────────

    private fun open(call: MethodCall): Boolean {
        val id = call.argument<String>("id") ?: return false
        val rate = call.argument<Int>("rate") ?: 24000
        val forCall = call.argument<Boolean>("call") == true
        val levels = call.argument<Boolean>("levels") == true
        stream?.stop()
        // 路由由 route() 的通信模式切换负责，不在这条轨上做；建流只管把 PCM 按媒体
        // 用法播出来，增益归 STREAM_MUSIC。
        val s = PcmStream(id, rate, forCall, levels, main, streamListener)
        if (!s.open()) return false
        stream = s
        if (!forCall && !requestFocus()) {
            s.stop()
            return false
        }
        return true
    }

    private val streamListener = object : PcmStream.Listener {
        override fun onStart(stream: PcmStream) {
            send("play", "what" to "start", "id" to stream.id)
            syncPlaying()
        }

        override fun onLevel(stream: PcmStream, value: Double) = send("playLevel", "id" to stream.id, "value" to value)

        override fun onDone(stream: PcmStream) = ended(stream, "done")

        override fun onStopped(stream: PcmStream) = ended(stream, "stopped")

        override fun onError(stream: PcmStream, reason: String) = ended(stream, "error")
    }

    private fun ended(s: PcmStream, what: String) {
        if (stream === s) {
            stream = null
            abandonFocus()
        }
        send("play", "what" to what, "id" to s.id)
        syncPlaying()
    }

    private fun requestFocus(): Boolean {
        val am = audio ?: return true
        val request = focus ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setOnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    main.post { stream?.takeIf { !it.call }?.stop() }
                }
            }
            .build()
            .also { focus = it }
        return am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        val request = focus ?: return
        focus = null
        runCatching { audio?.abandonAudioFocusRequest(request) }
    }

    // ── Calls ─────────────────────────────────────────────────────────────

    private fun startCall(bargeIn: Boolean, pause: TurnPause): String {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return "permission"
        }
        endCall()
        mic = MicArbiter.beginDictation()
        val marks = NativeTrial.marks(context.getSharedPreferences("speech_native", Context.MODE_PRIVATE))
        val c = CallCapture(main, captureListener) { SpeechGates.create(context.assets, it, marks) }
        c.bargeIn = bargeIn
        c.pause = pause
        val am = audio
        // 混合方案（Android 12+）：默认免提，留在 MODE_NORMAL，音量键直调媒体流
        // （那条音轨的增益按 STREAM_MUSIC 算）。只有切到听筒时才由 route() 进通信
        // 模式 + setCommunicationDevice(earpiece)——厂商 HAL 只有这条 vocoder 链路
        // 才把声音真正送到听筒单元。旧设备（<S）维持全程通信模式，用 isSpeakerphoneOn。
        if (am != null && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            previousMode = am.mode
            runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }
        }
        route()
        if (!c.start()) {
            endCall()
            return "microphone"
        }
        capture = c
        keepScreenOn(true)
        syncPlaying()
        return "ok"
    }

    private val captureListener = object : CallCapture.Listener {
        override fun onSpeechStart(overPlayback: Boolean) {
            // Spoken over: the voice steps back at once, before Dart hears of it; Dart
            // decides from what was said whether it stops or comes back up.
            if (overPlayback) stream?.takeIf { it.call }?.duck(true)
            send("speechStart", "over" to overPlayback)
        }

        override fun onUtterance(wav: ByteArray, ms: Int) = send("utterance", "wav" to wav, "ms" to ms)

        override fun onLevel(value: Double) = send("micLevel", "value" to value)

        override fun onError(reason: String) = send("callError", "reason" to reason)
    }

    private fun syncPlaying() {
        val playing = externalPlaying || stream?.let { it.call && it.started } == true
        capture?.setPlaying(playing)
    }

    /**
     * 选听筒还是免提/耳机（混合方案）。
     *
     * 免提（主场景，Android 12+）：MODE_NORMAL + USAGE_MEDIA，音量键直调 STREAM_MUSIC
     * ——这是真正驱动这条音轨增益的流，所以按键有效。
     *
     * 听筒：进 MODE_IN_COMMUNICATION + setCommunicationDevice(earpiece)。普通 AudioTrack
     * 在通信模式下被 AOSP remap 到 STRATEGY_PHONE，跟着通信设备走；更关键的是只有
     * 这条 vocoder/HAL 链路能让厂商硬件（Pixel 4 实测）真正把声音送到听筒单元——
     * 方案 X 的 setPreferredDevice 只建了 patch，轨仍留在 SPEAKER 线程，耳朵听不到。
     * 代价：通信模式把音量键钉到 STREAM_VOICE_CALL，这条媒体轨不吃它，听筒下音量键
     * 失效。这是用户确认接受的取舍（贴耳听，预设音量一般够）。
     *
     * 旧设备（<S）没有 setCommunicationDevice，维持全程通信模式 + isSpeakerphoneOn。
     */
    @Suppress("DEPRECATION")
    private fun route() {
        val am = audio ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!speaker) {
                // 切到听筒：进通信模式并把通信设备钉在听筒。
                if (!communicationActive) {
                    previousMode = am.mode
                    runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }
                    communicationActive = true
                }
                val earpiece = runCatching {
                    am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                }.getOrNull()
                if (earpiece != null) runCatching { am.setCommunicationDevice(earpiece) }
            } else if (communicationActive) {
                // 切回免提：撤掉通信设备、退出通信模式，音量键重新归媒体流。
                runCatching { am.clearCommunicationDevice() }
                val mode = previousMode
                previousMode = null
                communicationActive = false
                if (mode != null) runCatching { am.mode = mode }
            }
        } else {
            val wired = runCatching {
                am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in HEADSETS }
            }.getOrDefault(false)
            runCatching { am.isSpeakerphoneOn = speaker && !wired }
        }
    }

    @Suppress("DEPRECATION")
    private fun endCall() {
        val c = capture
        capture = null
        c?.stop()
        if (c != null) keepScreenOn(false)
        stream?.takeIf { it.call }?.stop()
        if (mic != 0) {
            MicArbiter.endDictation(mic)
            mic = 0
        }
        val am = audio
        val mode = previousMode
        val wasCommunication = communicationActive
        previousMode = null
        communicationActive = false
        externalPlaying = false
        if (am != null && mode != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && wasCommunication) {
                runCatching { am.clearCommunicationDevice() }
            } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                runCatching { am.isSpeakerphoneOn = false }
            }
            runCatching { am.mode = mode }
        }
    }

    private fun send(type: String, vararg fields: Pair<String, Any?>) {
        val args = HashMap<String, Any?>()
        args["type"] = type
        for ((k, v) in fields) args[k] = v
        main.post { runCatching { methods.invokeMethod("event", args) } }
    }

    companion object {
        private const val CHANNEL = "dsh/speech"
        private val HEADSETS = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }
}
