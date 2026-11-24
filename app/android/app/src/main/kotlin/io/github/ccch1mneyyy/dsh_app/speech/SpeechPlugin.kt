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
 * Calls — `callStart` {bargeIn, pause, micSource} answers "ok", "permission" or "microphone"; `callStop`; `callMute`
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
 * Mic source — 通话和实景测试共用 [MicSource]：`micSource` / `source`（auto|communication|
 * recognition|mic，缺省 auto）是唯一入口，auto 时按实测峰值决定，判据见 [MicSource.SWAP_DB]。
 * `screenTestWindow` 每条都带 `source`（本轮实际打开的音源）；诊断用的
 * `micSourceReport` 报两条路径各自的选择与依据，`micSourceProbe` 手动再量一次。
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
     *
     * 实景测试不再有自己的音源开关：两个入口（callStart 的 micSource、
     * screenTestStart 的 source）是同一个设置的两个出口，都交给 [MicSource]。
     */
    @Volatile private var callMicSource: String = "auto"

    @Volatile private var startedScreenTest = false
    /**
     * 每次 screenTestStart / screenTestStop 都加一。
     *
     * 音源要在工作线程上量（auto 约 4.5 秒），量完才起采集。这中间用户可能已经
     * 按了停止：靠这个序号确认"这一轮还是不是当前那一轮"，不是就别再开麦克风。
     */
    @Volatile private var screenTestGeneration = 0
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
                        call.argument<Double>("offset")?.toFloat() ?: 0f,
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
            "voiceprintAccept" -> {
                // 门槛滑条：拖到哪算哪，直接给绝对值。
                //
                // 传 null 表示「回到档位」——清掉覆盖值，让 level + bias 重新
                // 决定门槛。设置页切回四档胶囊时这么调。
                val v = call.argument<Double>("accept")
                Voiceprint.acceptOverride = if (v == null) Float.NaN else v.toFloat()
                // 立刻重算并推给正在跑的闸，不用等下一通电话。
                capture?.currentGate()?.let { g -> (g as? SpeakerGate)?.configure(Voiceprint.cutoffs()) }
                result.success(Voiceprint.acceptOverride.takeIf { !it.isNaN() }?.toDouble())
            }
            "voiceprintGain" -> {
                // 只设值，不量。量要走一次真实录音，见 voiceprintGainMeasure。
                Voiceprint.fixedGain = (call.argument<Double>("gain") ?: 1.0)
                    .toFloat().coerceIn(1.0f, 32.0f)
                result.success(Voiceprint.fixedGain)
            }
            "voiceprintGainMeasure" -> {
                // 录一小段，按「正常说话该有多响」反推倍数。
                //
                // 为什么不就地归一化而是算一个固定倍数：归一化按段内最大值缩放，
                // AI 说话时段内最大的是回声，一归一化就把回声拉到满格、底噪也
                // 一起抬上去。固定倍数只整体抬一截，段内比例不变。
                //
                // 取 90 分位而不是最大值：最大值可能是磕碰、咳嗽造成的孤立尖峰，
                // 拿它算会把倍数压得过低。90 分位更接近「说话时的正常响度」。
                val done = result
                val ms = (call.argument<Int>("ms") ?: 3000).coerceIn(1000, 10000)
                Thread({
                    val samples = runCatching { VoiceprintRecorder.start(VoiceprintRecorder.Source.CALL) }
                        .getOrDefault(false)
                    if (!samples) {
                        main.post { done.success(null) }
                        return@Thread
                    }
                    Thread.sleep(ms.toLong())
                    // 注意：这里拿到的音频已经是乘过当前 fixedGain 的，所以要
                    // 先用当前增益还原，再算新倍数——否则连量两次会越量越大。
                    main.post {
                        val audio = runCatching { VoiceprintRecorder.stop() }.getOrDefault(FloatArray(0))
                        done.success(measureGain(audio, Voiceprint.fixedGain))
                    }
                }, "dsh-gain-measure").apply { isDaemon = true }.start()
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
            // 音源诊断：通话和实景测试各自最近一次选了哪一路，依据是量到的什么。
            //
            // 这一条是新增的（旧版 Dart 不会调，协议不算改）：诊断页要回答的是
            // "两条路径收的是不是同一路声音"，光看设置里的档位答不了——auto 会
            // 自己换路，而换路的依据是实测电平。
            "micSourceReport" -> result.success(
                MicSource.report() + mapOf<String, Any?>(
                    "requested" to callMicSource,
                    // 通话此刻真正打开的音源（没在通话就是 null），和设置对照用。
                    "callOpened" to capture?.openedSource?.takeIf { it != 0 }
                        ?.let { AecSupport.sourceName(it) },
                    "screenOpened" to SpeakerScreenTest.source.takeIf { SpeakerScreenTest.isRunning }
                        ?.let { AecSupport.sourceName(it) },
                    "busy" to (capture != null || SpeakerScreenTest.isRunning || startedScreenTest || micVoiceprint != 0),
                ),
            )
            // 手动量一遍音源（诊断页的按钮）。会真的开三条音源各录 1.5 秒，
            // 所以放工作线程，并且麦克风被占着时直接拒绝。
            "micSourceProbe" -> {
                if (capture != null || SpeakerScreenTest.isRunning || startedScreenTest || micVoiceprint != 0) {
                    result.success(mapOf("error" to "正在用麦克风，先停掉通话或测试"))
                    return
                }
                val done = result
                Thread({
                    val pick = MicSource.probe()
                    main.post { done.success(MicSource.toMap(pick) ?: emptyMap<String, Any?>()) }
                }, "dsh-mic-source-probe").apply { isDaemon = true }.start()
            }
            // AEC 量测：必须边放边测。
            //
            // 之前这里是"静默录三次"，完全测不出 AEC——AEC 拿正在播放的音频
            // 当参考信号去减，不放东西它就没有参考可减，效果是恒等变换，
            // 测出来的差值只是底噪波动。用户也指出了这一点。
            //
            // 现在：放一段扫频音，同时录，跟"不播放时的底噪"比。差值就是
            // 漏进来的回声。三种配置各来一次，能看出 AEC 和音源各自贡献多少。
            "aecEcho" -> {
                // startedScreenTest 也算忙：实景测试刚开始时音源还在工作线程上量，
                // 那几秒里麦克风同样被占着（isRunning 还没变 true）。
                if (capture != null || SpeakerScreenTest.isRunning || startedScreenTest || micVoiceprint != 0) {
                    result.success(mapOf("error" to "正在用麦克风，先停掉通话或测试"))
                    return
                }
                val ms = (call.argument<Int>("ms") ?: 1500).coerceIn(600, 4000)
                val play = EchoTone(context)
                val out = LinkedHashMap<String, Any?>()
                try {
                    // 通话音源 · 关 AEC
                    out["vcNoAec"] = run {
                        val r = AecSupport.measureEcho(
                            MediaRecorder.AudioSource.VOICE_COMMUNICATION, false, ms,
                            play = { play.start() }, stopPlay = { play.stop() },
                        )
                        mapOf("playing" to r.playingDb, "silent" to r.silentDb, "leak" to r.leak, "usable" to r.usable)
                    }
                    Thread.sleep(300)
                    // 通话音源 · 开 AEC
                    out["vcAec"] = run {
                        val r = AecSupport.measureEcho(
                            MediaRecorder.AudioSource.VOICE_COMMUNICATION, true, ms,
                            play = { play.start() }, stopPlay = { play.stop() },
                        )
                        mapOf(
                            "playing" to r.playingDb, "silent" to r.silentDb,
                            "leak" to r.leak, "usable" to r.usable, "aecOn" to r.aecOn,
                        )
                    }
                    Thread.sleep(300)
                    // 识别音源 · 关 AEC
                    out["vrNoAec"] = run {
                        val r = AecSupport.measureEcho(
                            MediaRecorder.AudioSource.VOICE_RECOGNITION, false, ms,
                            play = { play.start() }, stopPlay = { play.stop() },
                        )
                        mapOf("playing" to r.playingDb, "silent" to r.silentDb, "leak" to r.leak, "usable" to r.usable)
                    }
                } finally {
                    play.release()
                }
                out["sdk"] = android.os.Build.VERSION.SDK_INT
                out["okThreshold"] = AecSupport.LEAK_OK
                out["badThreshold"] = AecSupport.LEAK_BAD
                result.success(out)
            }
            "screenTestStart" -> {
                if (capture != null || startedScreenTest) {
                    // 通话中不抢麦克风；已经在测也别再开一路。
                    result.success(false)
                    return
                }
                if (micVoiceprint != 0) {
                    // 正在录声纹。等录完再测，否则两路抢同一个麦克风。
                    result.success(false)
                    return
                }
                startedScreenTest = true
                // 测试音源：和通话同一个决定。
                //
                // 从前这里把音源钉死在 VOICE_COMMUNICATION，页面上另有一套
                // comm/recog/mic 开关，和设置里的「通话收音」各管各的：同一台
                // 机器上实景测试收 VC、通话可能收 VR，分数没法互相印证。
                // 现在两边都问 [MicSource]，设置里选什么、auto 量到什么，两边一样。
                //
                // auto 要开三条音源各量 1.5 秒（约 4.5 秒），放工作线程量完再
                // 起采集，别卡住主线程。
                val requested = call.argument<String>("source")
                val done = result
                val mine = ++screenTestGeneration
                Thread({
                    val pick = MicSource.resolve(requested, "screenTest")
                    // 量这 4.5 秒里用户可能已经按了停止：那一轮就别再开麦克风了。
                    if (mine != screenTestGeneration) {
                        main.post { done.success(false) }
                        return@Thread
                    }
                    // 测试也要进通信模式，和通话一样。
                    //
                    // 不进的话有两个后果，都是实测踩到的：
                    // 1. TTS 走默认流（可能是通知/铃声），不进媒体流——音量键调不到，
                    //    声音也可能被系统调得很小甚至不响。
                    // 2. AEC 拿不到参考：通话能把播放轨 remap 到通信链路，AEC 从
                    //    下行抽样消除自己的声音；测试不 remap，AEC 标志是 true 却
                    //    没东西可减，回声直接漏回麦克风被当成插话。
                    val enterComm = {
                        val am = audio
                        if (am != null && previousMode == null) {
                            previousMode = am.mode
                            runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }
                            communicationActive = true
                        }
                        // 外放：测试就是要让自己的声音被麦克风听到。
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            runCatching {
                                am?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                                    ?.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                                    ?.let { am.setCommunicationDevice(it) }
                            }
                        }
                        speaker = true
                    }
                    main.post { runCatching { enterComm() } }
                    val ok = runCatching {
                        SpeakerScreenTest.start(pick.source) { w ->
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
                                        // 这一轮到底收的哪一路。页面直接显示，
                                        // 不用再猜"这次是 auto 选的吗"。
                                        "source" to pick.chosen,
                                        "sourceRequested" to pick.requested,
                                    ),
                                )
                            }
                        }
                    }.getOrDefault(false)
                    if (!ok) startedScreenTest = false
                    main.post { done.success(ok) }
                }, "dsh-screen-test-source").apply { isDaemon = true }.start()
            }
            "screenTestStop" -> {
                screenTestGeneration++
                SpeakerScreenTest.stop()
                startedScreenTest = false
                // 还原音频模式：测试借用了通信模式，结束要还回去，否则后面
                // 放音乐、放视频都会走通话音量。
                previousMode?.let { m ->
                    runCatching { audio?.mode = m }
                    previousMode = null
                }
                communicationActive = false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    runCatching { audio?.clearCommunicationDevice() }
                }
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
                // 存一份原始音频。
                //
                // 用户提的：录进去的声纹能不能回放。之前只留了 192 维向量，
                // 想听"当时到底录到了什么"没有办法——而这恰恰是排查
                // "为什么认不出来"最需要的东西（比如录进去一半是空白）。
                val clip = runCatching {
                    val stamp = System.currentTimeMillis()
                    val f = File(
                        File(context.getExternalFilesDir(null), "voiceprint-clips").apply { mkdirs() },
                        "vp-$stamp.wav",
                    )
                    SpeakerScreenTest.writeWav(f, samples)
                    f.absolutePath
                }.getOrNull()
                result.success(
                    mapOf(
                        "samples" to samples,
                        "clip" to clip,
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

    /**
     * 从一段录音反推「让正常说话达到目标响度」的固定倍数。
     *
     * 目标 -18 dBFS：留出约 18dB 余量，够应付感叹、靠近麦克风的情况，
     * 又不至于把安静说话者压得太低。
     *
     * [currentGain] 是这段音频已经被乘过的倍数，先除回去再算新值，
     * 这样连量两次结果一样，不会累积放大。
     *
     * 返回 null 表示这段录音不可用（太短、几乎全静音）——那种情况算出来
     * 的倍数会是几十倍，乘上去只剩噪声。
     */
    private fun measureGain(audio: FloatArray, currentGain: Float): Map<String, Any?>? {
        if (audio.size < VoiceprintRecorder.RATE / 2) return null
        // 还原到未放大的幅度，避免连续测量越量越大。
        val raw = if (currentGain > 1.001f) audio.map { it / currentGain } else audio.toList()

        // 每 20ms 一个窗口算 RMS，取 90 分位当作「正常说话时的响度」。
        // 用分位而不是最大值：最大值常是磕碰、咳嗽的孤立尖峰。
        val win = 320
        val levels = ArrayList<Double>(raw.size / win + 1)
        var i = 0
        while (i + win <= raw.size) {
            var acc = 0.0
            for (k in i until i + win) {
                val v = raw[k]
                acc += v * v
            }
            levels.add(kotlin.math.sqrt(acc / win))
            i += win
        }
        if (levels.isEmpty()) return null
        levels.sort()
        val p90 = levels[(levels.size * 0.9).toInt().coerceAtMost(levels.size - 1)]
        // 90 分位都低到听不见，说明这段没说话（或麦克风没给数据）。
        if (p90 < 1e-5) return null

        // 目标 -30 dBFS 的 RMS，不是 -18。
        //
        // RMS 和峰值差得远：说话时峰值通常比 RMS 高 12~15dB。按 -18dBFS 的
        // RMS 去凑，峰值会顶到 -1dB 附近——实测就是这么调到 0.857 的，稍微
        // 大声一点就削顶，而削顶引入的失真对声纹特征是灾难性的。
        // -30dBFS 的 RMS 对应峰值约 -18dBFS，留足余量。
        val target = 0.0316         // -30 dBFS

        // 段内实际峰值也参与：这段本来就很响就不该再乘。
        //
        // 取 99.9 分位而不是绝对最大值——绝对最大值常是爆音、磕碰，
        // 一个尖峰就能把倍数压到 1，白白损失整段的提升空间。
        val absVals = raw.map { kotlin.math.abs(it) }.sorted()
        val peak = absVals[(absVals.size * 0.999).toInt().coerceAtMost(absVals.size - 1)]
        val gainByRms = (target / p90).toFloat()
        // 峰值顶到 0.6 就不再放大：留 4dB 余量，够应付忽然提高的嗓门。
        val gainByPeak = if (peak > 0.6) (0.6 / peak).toFloat() else Float.MAX_VALUE
        val gain = minOf(gainByRms, gainByPeak).coerceIn(1.0f, 32.0f)
        return mapOf(
            "gain" to gain.toDouble(),
            "peakP90" to p90,
            "peak" to peak,
            "currentGain" to currentGain.toDouble(),
            "windows" to levels.size,
        )
    }

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
        bargeOffset = offset
        c.bargeIn = bargeIn
        c.pause = pause
        c.bargeOffset = offset
        // 通话采集走哪一路：和实景测试同一个决定（[MicSource]），设置里的
        // 「通话收音」是唯一入口。auto 时这里会真的开三条音源各量 1.5 秒
        // （约 4.5 秒，同步发生在主线程上——和改动前一样，没在这里顺手改时序）。
        c.preferredSource = MicSource.resolve(callMicSource, "call").source
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
