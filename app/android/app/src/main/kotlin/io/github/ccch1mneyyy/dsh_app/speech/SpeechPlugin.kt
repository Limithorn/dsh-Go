package io.github.ccch1mneyyy.dsh_app.speech

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.nativemedia.MicArbiter
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeakerGate
import io.github.ccch1mneyyy.dsh_app.nativemedia.Thresholds
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
 * ([MicArbiter]). Routing (方案 D): the whole call stays in MODE_IN_COMMUNICATION and only the
 * communication device switches between speaker and earpiece. This puts the playback track on the
 * telephony/vocoder path so the echo canceller gets its far-end reference and can cancel the
 * AI's own voice (which otherwise echoes into the mic and stops the reply as if the user spoke).
 * Only the vocoder path reaches the physical earpiece on vendor HALs (Pixel 4). Volume keys are
 * pinned to STREAM_VOICE_CALL in communication mode; whether they still drive this media track is
 * under A/B verification. The screen stays on meanwhile (a backgrounded app gets no microphone).
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

    // 实景测试状态。只活在一次测试里，和通话无关。
    /**
     * 通话采集的音源偏好，由 Dart 侧的 CallMicSource 送来。
     * auto / communication / recognition。
     */
    @Volatile private var callMicSource: String = "auto"

    /**
     * 自动判断是否该放弃通话那一路。
     *
     * 只在"通话那路明显听不见人"时换：实测 Sony 上 VC 是 −74.1 dBFS 而 VR 是
     * −20.8，差 53 dB。差 20 dB 以上就认为通那一路被降噪吃掉了。
     *
     * 量一次就够，不缓存：这不是性能敏感的路径，而且用户可能换机器。
     */
    private fun autoPickRecognition(): Boolean {
        val peaks = runCatching { VoiceprintRecorder.probeSources() }.getOrNull() ?: return false
        val vc = peaks["VOICE_COMMUNICATION"] ?: return false
        val vr = peaks["VOICE_RECOGNITION"] ?: return false
        // -999 / -998 是打不开的错误码，别拿它们比。
        if (vc <= -900 || vr <= -900) return false
        val useVr = vr - vc > 20.0
        Log.i("SpeechPlugin", "call mic auto: vc=${"%.1f".format(vc)} vr=${"%.1f".format(vr)} -> ${if (useVr) "recognition" else "communication"}")
        return useVr
    }

    private var startedScreenTest = false
    private var screenTestSaved = 0
    private val screenTestDir: File
        get() = File(context.getExternalFilesDir(null), "screen-test").apply { mkdirs() }
    private var mic = 0

    /** 录入声纹时占着的麦克风（0 = 没占）。 */
    private var micVoiceprint = 0
    private var previousMode: Int? = null
    /** 是否因切到听筒而进了通信模式（Android 12+）；退出/挂断时据此还原。 */
    private var communicationActive = false
    private var speaker = true
    /** 插话灵敏度档位偏移，按用户设置跨通话记住。 */
    private var bargeOffset: Float = 0f
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
            "callStart" -> {
                // 通话采集音源偏好，在开会话之前定下来。
                callMicSource = call.argument<String>("micSource") ?: "auto"
                result.success(
                    startCall(
                        call.argument<Boolean>("bargeIn") ?: true,
                        TurnPause.of(call.argument<String>("pause")),
                        call.argument<Double>("bargeOffset")?.toFloat() ?: 0f,
                    ),
                )
            }
            "callPause" -> {
                capture?.pause = TurnPause.of(call.argument<String>("pause"))
                result.success(null)
            }
            "callBargeOffset" -> {
                bargeOffset = (call.argument<Double>("offset") ?: 0.0).toFloat()
                capture?.bargeOffset = bargeOffset
                result.success(null)
            }
            "voiceprintConfigure" -> {
                Voiceprint.warmUp(context.assets)
                Voiceprint.dumpDir = File(context.getExternalFilesDir(null), "voiceprint-dumps").path
                val raw = call.argument<List<Map<String, Any?>>>("profiles").orEmpty()
                val list = raw.mapNotNull { entry ->
                    val id = entry["id"] as? String ?: return@mapNotNull null
                    // MethodChannel 过来的是 FloatArray；个别 ROM 会包成 DoubleArray，一并认。
                    val vec = when (val v = entry["vector"]) {
                        is FloatArray -> v
                        is DoubleArray -> FloatArray(v.size) { v[it].toFloat() }
                        is List<*> -> v.mapNotNull { (it as? Number)?.toFloat() }.toFloatArray()
                        else -> null
                    } ?: return@mapNotNull null
                    // 只用来数有几个人、以及界面上显示，比对时不参与。
                    SpeakerGate.Profile(id, vec, entry["source"] as? String ?: "call")
                }
                Log.i("Voiceprint", "configure: raw=${raw.size} kept=${list.size} enabled=${call.argument<Boolean>("enabled")}")
                Voiceprint.setConfig(
                    enabled = call.argument<Boolean>("enabled") == true,
                    // 唤醒是否也认声音。默认关：唤醒是常开的被动监听，
                    // 判定次数多、误判代价也大。
                    wake = call.argument<Boolean>("wake") == true,
                    allowOthers = call.argument<Boolean>("allowOthers") ?: true,
                    level = when (call.argument<String>("level")) {
                        "loose" -> Thresholds.Level.LOOSE
                        "strict" -> Thresholds.Level.STRICT
                        "veryStrict" -> Thresholds.Level.VERY_STRICT
                        else -> Thresholds.Level.NORMAL
                    },
                    list = list,
                    // 这台机器上的微调，由设置页给（可以是手动拖的，也可以是
                    // 「测一下」算出来的建议值）。
                    bias = (call.argument<Double>("bias") ?: 0.0).toFloat().coerceIn(-0.2f, 0.2f),
                    // 静默检测随机器调。不传就沿用当前值（null 表示"别动"）。
                    silence = call.argument<Map<String, Any?>>("silence")?.let { m ->
                        val d = io.github.ccch1mneyyy.dsh_app.nativemedia.KaldiFbank.Silence()
                        io.github.ccch1mneyyy.dsh_app.nativemedia.KaldiFbank.Silence(
                            percentile = (m["percentile"] as? Number)?.toDouble()?.coerceIn(0.02, 0.80) ?: d.percentile,
                            multiple = (m["multiple"] as? Number)?.toDouble()?.coerceIn(1.5, 30.0) ?: d.multiple,
                            absoluteFloor = (m["absoluteFloor"] as? Number)?.toDouble()?.coerceIn(0.0, 1e-2) ?: d.absoluteFloor,
                            voicedFraction = (m["voicedFraction"] as? Number)?.toDouble()?.coerceIn(0.05, 0.60) ?: d.voicedFraction,
                        )
                    },
                )
                // 门槛随人数重算：人来人往之后不能沿用旧值（5 人删到 1 人要回落）。
                capture?.currentGate()?.let { g -> (g as? SpeakerGate)?.configure(Voiceprint.cutoffs()) }
                result.success(Voiceprint.describe())
            }
            "voiceprintEnabled" -> {
                Voiceprint.enabled = call.argument<Boolean>("enabled") == true
                capture?.currentGate()?.let { g -> (g as? SpeakerGate)?.configure(Voiceprint.cutoffs()) }
                result.success(null)
            }
            "voiceprintAvailable" -> {
                // 模型 28MB，加载要几百毫秒到几秒；问到的时候往往还没好。
                // 等它就绪再回答，但不在主线程等。
                val done = result
                Thread({
                    val ok = Voiceprint.availableBlocking(context.assets)
                    main.post { done.success(ok) }
                }, "dsh-voiceprint-probe").apply { isDaemon = true }.start()
            }
            "voiceprintDescribe" -> {
                // 诊断页用：把原生此刻真正在用的门槛、静默参数、模型状态都报上去。
                // 和设置页那份比对，就知道"改了的设置有没有送到原生"。
                Voiceprint.warmUp(context.assets)
                result.success(Voiceprint.describe())
            }
            // 实景测试：TTS 正在说话时量"能不能被打断"。
            // 只负责采集和判定；说什么由 Dart 侧用 TTS 放。
            // ── AEC 诊断 ───────────────────────────────────────────────
            // 逐层报告：ROM 说支持吗 / 拿到对象了吗 / 真启用了吗 / 音源自不带。
            // 13 和 14 上断在不同层，光看一个"开/关"判断不出来。
            "aecReport" -> {
                val fromCapture = capture?.lastAec ?: SpeakerScreenTest.lastAec
                result.success(fromCapture?.let { AecSupport.run { it.toMap() } } ?: emptyMap<String, Any?>())
            }
            // 实测量一遍：同一段静默，三种配置各录一次，看 AEC 到底削掉多少。
            // 这一步要 3 秒左右，界面自己等。
            "aecProbe" -> {
                if (capture != null || SpeakerScreenTest.isRunning) {
                    result.success(mapOf("error" to "正在用麦克风，先停掉通话或测试"))
                    return
                }
                val m = AecSupport.probeMatrix(call.argument<Int>("ms") ?: 1200)
                result.success(
                    if (m == null) {
                        mapOf("error" to "测不了（可能并发调用）")
                    } else {
                        mapOf(
                            "vcNoAec" to m.vcNoAec,
                            "vcAec" to m.vcAec,
                            "vrNoAec" to m.vrNoAec,
                            "cut" to m.aecCut,
                            "sdk" to android.os.Build.VERSION.SDK_INT,
                            "sourceName" to AecSupport.sourceName(MediaRecorder.AudioSource.VOICE_COMMUNICATION),
                        )
                    },
                )
            }
            // 单个音源 + 开关 AEC 的量测，给"对比"按钮用。
            "aecLevel" -> {
                if (capture != null || SpeakerScreenTest.isRunning) {
                    result.success(-999.0)
                    return
                }
                result.success(
                    AecSupport.probeLevel(
                        when (call.argument<String>("source")) {
                            "recognition" -> MediaRecorder.AudioSource.VOICE_RECOGNITION
                            "mic" -> MediaRecorder.AudioSource.MIC
                            else -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
                        },
                        call.argument<Boolean>("withAec") == true,
                        call.argument<Int>("ms") ?: 1200,
                    ),
                )
            }
            "screenTestStart" -> {
                if (capture != null) {
                    // 通话中不抢麦克风。
                    result.success(false)
                    return
                }
                startedScreenTest = true
                val ok = SpeakerScreenTest.start { w ->
                    // 回调在采集线程上，转回主线程再往 Dart 送。
                    // 默认留最近 6 段：够看清"哪一段出了问题"，又不至于把存储占满。
                    if (screenTestSaved < SCREEN_TEST_KEEP) {
                        screenTestSaved++
                        runCatching {
                            SpeakerScreenTest.writeWav(
                                File(screenTestDir, "screen-${System.currentTimeMillis()}.wav"),
                                w.audio,
                            )
                        }
                    }
                    main.post {
                        methods.invokeMethod(
                            "screenTestWindow",
                            mapOf(
                                "score" to w.score,
                                "kind" to w.kind,
                                "rms" to w.rms,
                                "barged" to w.barged,
                                    "aec" to SpeakerScreenTest.echoCancelled,
                            ),
                        )
                    }
                }
                result.success(ok)
            }
            "screenTestStop" -> {
                SpeakerScreenTest.stop()
                startedScreenTest = false
                result.success(screenTestDir.listFiles()?.sortedByDescending { it.lastModified() }
                    ?.take(SCREEN_TEST_KEEP)?.map { it.absolutePath } ?: emptyList<String>())
            }
            "voiceprintEmbed" -> {
                val samples = call.argument<FloatArray>("samples")
                if (samples == null) {
                    result.success(null)
                    return
                }
                Voiceprint.warmUp(context.assets)
                // 录音页会连续调；放到后台线程算，别卡住 UI。
                Thread({
                    val v = Voiceprint.embedSamples(samples)
                    main.post { result.success(v) }
                }, "dsh-voiceprint-embed").apply { isDaemon = true }.start()
            }
            "voiceprintRecordStart" -> {
                // 通话中不抢麦克风：正打着电话就别录。
                if (capture != null) {
                    result.success(false)
                    return
                }
                micVoiceprint = MicArbiter.beginDictation()
                // 录哪个音源：call（默认，带 AEC，和通话同分布）/ wake / raw。
                // 同一句话在两种场景下电平差十几 dB，模板要分开录才认得准。
                val which = VoiceprintRecorder.Source.of(call.argument<String>("source"))
                result.success(VoiceprintRecorder.start(which))
            }
            "voiceprintRecordStop" -> {
                val samples = VoiceprintRecorder.stop()
                val token = micVoiceprint
                micVoiceprint = 0
                if (token != 0) MicArbiter.endDictation(token)
                result.success(
                    mapOf(
                        "samples" to samples,
                        "ms" to (samples.size * 1000L / VoiceprintRecorder.RATE),
                        "loudness" to VoiceprintRecorder.loudness(samples),
                        "noisiness" to VoiceprintRecorder.noisiness(samples),
                        // 底噪与"说话时比环境高多少"，界面靠这个判断够不够。
                        "floor" to VoiceprintRecorder.floor,
                        "snr" to (VoiceprintRecorder.loudness(samples) - VoiceprintRecorder.floor),
                    ),
                )
            }
            "voiceprintIsKnown" -> {
                // 唤醒用：这一段是不是录过的人。音频太短或功能没开都返回 true，
                // 宁可答应也不让开关变成"叫不应"。
                val samples = call.argument<FloatArray>("samples")
                if (samples == null || samples.isEmpty()) {
                    result.success(true)
                } else {
                    val done = result
                    Thread({
                        val ok = runCatching { Voiceprint.isKnownVoice(samples) }.getOrDefault(true)
                        main.post { done.success(ok) }
                    }, "dsh-voiceprint-known").apply { isDaemon = true }.start()
                }
            }
            "voiceprintLevel" -> result.success(
                mapOf(
                    "db" to VoiceprintRecorder.level,
                    "floor" to VoiceprintRecorder.floor,
                ),
            )
            "voiceprintProbe" -> {
                val done = result
                Thread({
                    val r = VoiceprintRecorder.probeSources()
                    main.post { done.success(r) }
                }, "dsh-voiceprint-probe-src").apply { isDaemon = true }.start()
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
                // 方案 D：全程通信模式，只切通信设备（speaker/earpiece），交给 route()。
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
        val s = PcmStream(
            id, rate, forCall, levels, main, streamListener,
            audio = context.getSystemService(android.media.AudioManager::class.java),
        )
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

    private fun startCall(bargeIn: Boolean, pause: TurnPause, offset: Float = 0f): String {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return "permission"
        }
        endCall()
        mic = MicArbiter.beginDictation()
        val marks = NativeTrial.marks(context.getSharedPreferences("speech_native", Context.MODE_PRIVATE))
        // 声纹：先让模型在后台转起来（不阻塞接通），gate 建好之后再包一层。
        // 模型没就绪、或这台机器加载不了，gateFor 返回 null，行为与原来逐帧一致。
        Voiceprint.warmUp(context.assets)
        Voiceprint.onVerdict = { v ->
            main.post {
                methods.invokeMethod(
                    "event",
                    mapOf(
                        "type" to "speechJudge",
                        "over" to v.overPlayback,
                        "verdict" to when (v.kind) {
                            SpeakerGate.Kind.YOU -> "you"
                            SpeakerGate.Kind.OTHER -> "other"
                            SpeakerGate.Kind.UNKNOWN -> "unknown"
                        },
                        "score" to v.score,
                        "matched" to v.matched,
                    ),
                )
            }
        }
        val c = CallCapture(main, captureListener) { echoCancelled ->
            val base = SpeechGates.create(context.assets, echoCancelled, marks)
            Voiceprint.gateFor(base) ?: base
        }
        c.bargeIn = bargeIn
        c.pause = pause
        // 通话采集走哪一路。auto 时按实测电平自己选，见 CallMicSource。
        c.preferredSource = when (callMicSource) {
            "recognition" -> MediaRecorder.AudioSource.VOICE_RECOGNITION
            "communication" -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
            else -> if (autoPickRecognition()) {
                MediaRecorder.AudioSource.VOICE_RECOGNITION
            } else {
                MediaRecorder.AudioSource.VOICE_COMMUNICATION
            }
        }
        bargeOffset = offset
        c.bargeOffset = offset
        val am = audio
        // 方案 D：通话全程进通信模式（含免提）。只有通信模式把播放轨 remap 到
        // STRATEGY_PHONE / vocoder 链路，AEC 才能从「通信下行」抽到参考、消掉 AI
        // 自己的声音——否则免提 MODE_NORMAL + USAGE_MEDIA 时 AEC 标志虽 true 却
        // 拿不到参考，残余回声被 gate 当成插话，造成「 AI 说着说着自己停」。
        // 代价：通信模式把音量键钉到 STREAM_VOICE_CALL；若这条媒体轨增益仍按
        // MUSIC，音量键会失效——需真机 A/B 验证，不成立则回退混合方案。
        if (am != null && previousMode == null) {
            previousMode = am.mode
            runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }
            communicationActive = true
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
     * 选听筒还是免提（方案 D：全程通信模式 + 通信设备二选一）。
     *
     * 通话从 startCall 起就进 MODE_IN_COMMUNICATION，免提/听筒只是把通信设备钉到
     * SPEAKER 或 EARPIECE。这样播放轨（USAGE_MEDIA）在通信模式下被 AOSP remap 到
     * STRATEGY_PHONE/vocoder 链路：AEC 从通信下行抽到参考、能消掉 AI 回声（根治自打断），
     * 且厂商 HAL（Pixel 4 实测）能把声音真正送到听筒单元。
     *
     * 悬念：通信模式把音量键钉到 STREAM_VOICE_CALL。若这条媒体轨的增益随之改按 VC，
     * 音量键反而恢复（正统解）；若仍按 MUSIC，则音量键失效——真机 A/B 验证决定去留。
     *
     * 旧设备（<S）没有 setCommunicationDevice，维持全程通信模式 + isSpeakerphoneOn。
     */
    @Suppress("DEPRECATION")
    private fun route() {
        val am = audio ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!communicationActive) {
                previousMode = am.mode
                runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }
                communicationActive = true
            }
            val want = if (speaker) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            val device = runCatching {
                am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type == want }
            }.getOrNull()
            if (device != null) runCatching { am.setCommunicationDevice(device) }
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
        /**
         * 一次实景测试最多留几段录音。
         *
         * 每段 1.5 秒、32KB。6 段够看清"哪一段出了问题"，又不至于占满存储；
         * 要更多就再测一次。
         */
        private const val SCREEN_TEST_KEEP = 6

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
