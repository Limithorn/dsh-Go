package io.github.ccch1mneyyy.dsh_app.speech

import android.content.Context
import android.content.res.AssetManager
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.nativemedia.CampplusEmbedder
import io.github.ccch1mneyyy.dsh_app.nativemedia.KaldiFbank
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeakerGate
import io.github.ccch1mneyyy.dsh_app.nativemedia.Thresholds
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicReference

/**
 * 声纹的进程级状态：模型、白名单、门槛。
 *
 * 为什么要有这一层而不是每个 [SpeakerGate] 自己管：模型 28MB，一次通话一个实例
 * 会反复加载；而且设置页改白名单、通话里判定，两边看的是同一份。
 *
 * 加载失败一次就不再重试（[blocked]），与 [io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGates]
 * 处理 ONNX 故障的立场一致：不能因为一个可选功能让通话起不来。
 */
object Voiceprint {
    private const val TAG = "Voiceprint"
    private const val MODEL = "3dspeaker_campplus_sv_zh-cn_16k-common.onnx"

    @Volatile private var embedder: CampplusEmbedder? = null
    @Volatile private var loading = false
    @Volatile private var blocked = false

    private val profiles = AtomicReference<List<SpeakerGate.Profile>>(emptyList())

    @Volatile var enabled: Boolean = false
    @Volatile var allowOthers: Boolean = true
    @Volatile var level: Thresholds.Level = Thresholds.Level.NORMAL

    /**
     * 在这台机器上再微调多少。
     *
     * 三档基线是按"正常手机"定的，可 AEC 削掉多少分跟机型、麦克风、外壳都有关：
     * 同一句"是我"，有的机器 0.7、有的 0.5。这个偏移量由设置页给出（见
     * 「测一下，给我个建议」），也允许手动拖。0 表示完全按档位算。
     */
    @Volatile var bias: Float = 0f

    /**
     * 静默检测的参数（"这段里到底有没有人说话"）。
     *
     * 采集电平跟着机器走：VOICE_COMMUNICATION + AEC 是正确的（声纹要和通话同
     * 分布），但不同机器被削掉的幅度差很多——实测有一台机器真人说话的帧能量
     * 只有 1.4e-9，旧代码写死 3e-6 的绝对门限，于是每一帧都判成静默，embed
     * 返回 null，声纹彻底失效（表现："谁都打断不了"）。
     *
     * 所以这三个数交给设置页，随机器调。
     */
    @Volatile var silence: KaldiFbank.Silence = KaldiFbank.Silence()

    /** 唤醒也认声音。与 [enabled] 分开：通话和唤醒是两个独立的闸。 */
    @Volatile var wake: Boolean = false

    /** 每次判定的回调（影子日志 / 调测页 / Dart 事件），由 [SpeechPlugin] 接上。 */
    @Volatile var onVerdict: ((SpeakerGate.Verdict) -> Unit)? = null

    val isReady: Boolean get() = embedder != null && !blocked

    /**
     * 直接算一段音频的向量。
     *
     * 实景测试用：它要一段一段地算、自己留音频，走不了 SpeakerGate 那条
     * 回调链。模型没就绪时返回 null。
     */
    fun embed(samples: FloatArray): FloatArray? = embedder?.embed(samples)

    /** 当前门槛；人数变了要跟着变（去人后门槛回落）。 */
    fun cutoffs(gate: Thresholds.Gate = Thresholds.Gate.BARGE): SpeakerGate.Cutoffs {
        val list = profiles.get()
        val n = list.size
        // 门槛照旧按模板数 n 算。
        //
        // 想过按"人数"算（同一人录了通话、唤醒两份只算一个），但做不到：
        // 模板之间没有可靠的"同属一人"标记，硬猜会把真正的第二个人算成一个。
        // 而 n 抬高 0.045*ln N 的幅度很小：录两份 = +0.031，录四份 = +0.062。
        // 多一份模板同时让"取最高分"更容易命中，两者大致抵得上。
        //
        // 真嫌门槛被抬高，把那人的第二份删掉、或者调「这台机器微调」的 bias。
        val accept = Thresholds.accept(level, n, gate, bias)
        val reject = Thresholds.reject(level, n, gate, bias)
        // 唤醒自己有个开关；通话看总开关。两者都用同一份模板。
        val on = if (gate == Thresholds.Gate.WAKE) wake else enabled
        return SpeakerGate.Cutoffs(
            accept = accept,
            reject = reject,
            allowOthers = allowOthers,
            // 没有模板就不算开：判定需要比对对象。
            enabled = on && n > 0 && !blocked,
            // 打断闸才有播放：外放时 AI 自己的声音会漏回麦克风，那段音频和
            // 本人模板天然很像，会在 accept 线附近来回摆。抬一点线能把
            // "回声刚过线"那批挡住，而真插话通常更响更清楚，不受影响。
            // 唤醒闸不播放，不用抬。
            playingBoost = if (gate == Thresholds.Gate.BARGE) PLAYING_BOOST else 0f,
        )
    }

    /** 唤醒命中时用这一段判"是谁"。返回 false 表示不该答应。 */
    fun isKnownVoice(samples: FloatArray): Boolean {
        val c = cutoffs(Thresholds.Gate.WAKE)
        if (!c.enabled) return true
        val vector = embedder?.embed(samples) ?: return true
        val list = profiles.get()
        if (list.isEmpty()) return true
        var best = -1f
        for (p in list) {
            var dot = 0f
            for (i in vector.indices) dot += vector[i] * p.vector[i]
            if (dot > best) best = dot
        }
        return best >= c.accept
    }

    fun setProfiles(list: List<SpeakerGate.Profile>) {
        profiles.set(list)
    }

    fun currentProfiles(): List<SpeakerGate.Profile> = profiles.get()

    fun setConfig(
        enabled: Boolean,
        allowOthers: Boolean,
        level: Thresholds.Level,
        list: List<SpeakerGate.Profile>?,
        wake: Boolean = false,
        bias: Float = 0f,
        silence: KaldiFbank.Silence? = null,
    ) {
        this.enabled = enabled
        this.allowOthers = allowOthers
        this.level = level
        this.wake = wake
        this.bias = bias
        list?.let { profiles.set(it) }
        // 静默参数变了就得换一份 embedder：它建 fbank 时把参数拷了进去，
        // 改字段不生效。模型只有 28MB，重建一次比留着旧的门限划算。
        if (silence != null && silence != this.silence) {
            this.silence = silence
            refreshEmbedder()
        }
    }

    /**
     * 按当前的 [silence] 重建 embedder。
     *
     * 模型还没加载完、或已经标记为不可用时什么都不做——那种情况由 [warmUp]
     * 负责，它会读到最新的 [silence]。
     */
    private fun refreshEmbedder() {
        val assets = warmAssets ?: return
        if (blocked) return
        Thread({
            try {
                val bytes = assets.open("speech/$MODEL").use { it.readBytes() }
                val next = CampplusEmbedder(bytes, silence)
                embedder?.close()
                embedder = next
                Log.i(TAG, "CAM++ reloaded with silence p=${silence.percentile} x${silence.multiple}")
            } catch (e: Exception) {
                Log.w(TAG, "reload with new silence failed; keeping the old one", e)
            }
        }, "dsh-speaker-reload").apply { isDaemon = true }.start()
    }

    /** [warmUp] 拿到的 AssetManager，重建 embedder 时还要用。 */
    @Volatile private var warmAssets: AssetManager? = null

    /** 后台加载模型；调用方不阻塞。 */
    fun warmUp(assets: AssetManager) {
        if (embedder != null || loading || blocked) return
        warmAssets = assets
        loading = true
        Thread({
            try {
                val bytes = assets.open("speech/$MODEL").use { it.readBytes() }
                embedder = CampplusEmbedder(bytes, silence)
                Log.i(TAG, "CAM++ loaded, dim=${embedder?.dimension}")
            } catch (e: Exception) {
                blocked = true
                Log.w(TAG, "voiceprint model unavailable; the call runs without it", e)
            } catch (e: LinkageError) {
                blocked = true
                Log.w(TAG, "ONNX Runtime unavailable for voiceprint", e)
            } finally {
                loading = false
            }
        }, "dsh-speaker-warmup").apply { isDaemon = true }.start()
    }

    /**
     * 给采集用的 gate。模型没就绪就返回 null，调用方退回原来的 gate。
     */
    /**
     * 播放时 accept 抬高多少。
     *
     * 0.05：实测外放漏回来的回声，分数通常比本人真说话低 0.03~0.08。
     * 抬 0.05 能把大部分挡住；再往上会开始挡掉"轻声说"的真插话。
     */
    private const val PLAYING_BOOST = 0.05f

    /** 判定音频的落盘目录（排查用）。空串就不写。 */
    var dumpDir: String = ""

    fun gateFor(inner: io.github.ccch1mneyyy.dsh_app.nativemedia.TurnGate): SpeakerGate? {
        val ex = embedder ?: return null
        if (blocked) return null
        return SpeakerGate(
            inner = inner,
            embedder = object : SpeakerGate.Embedder {
                override fun embed(samples: FloatArray): FloatArray? = ex.embed(samples)
                override fun close() {} // 模型是共享的，不随这个 gate 关掉
            },
            profiles = SpeakerGate.ProfileSource { profiles.get() },
            onVerdict = { v -> onVerdict?.invoke(v) },
        ).also { gate ->
            gate.configure(cutoffs())
            gate.dumpDir = dumpDir
        }
    }

    /** 同步算一段音频的声纹（录入流程用）。 */
    fun embedSamples(samples: FloatArray): FloatArray? = embedder?.embed(samples)

    /** 从 ByteBuffer 读 float（Dart 传 Float32List 过来）。 */
    fun floatsOf(buffer: ByteBuffer, count: Int): FloatArray {
        val b = buffer.order(ByteOrder.nativeOrder())
        val out = FloatArray(count)
        for (i in 0 until count) out[i] = b.float
        return out
    }

    fun available(): Boolean = embedder != null && !blocked

    /**
     * 等同模型就绪再回答（设置页用它，最多等 [waitMs]）。
     *
     * [warmUp] 是在后台线程里加载 28MB 模型的；设置页一打开就问，
     * 直接读 [embedder] 多半还是 null——那就是"这台手机不支持"，是误判。
     */
    fun availableBlocking(assets: AssetManager, waitMs: Long = 4000): Boolean {
        warmUp(assets)
        val deadline = System.currentTimeMillis() + waitMs
        while (loading && System.currentTimeMillis() < deadline) {
            try {
                Thread.sleep(40)
            } catch (_: InterruptedException) {
                break
            }
        }
        return available()
    }

    /** 供诊断：当前白名单人数与门槛。 */
    fun describe(): Map<String, Any> = mapOf(
        "profiles" to profiles.get().size,
        "enabled" to enabled,
        "accept" to cutoffs().accept,
        "reject" to cutoffs().reject,
        "ready" to available(),
        // 诊断页要看到的那一串：门槛怎么来的、静默检测怎么判的。
        // 光看 accept 一个数，分不清"分数不够"和"根本没算"。
        "level" to level.name.lowercase(),
        "bias" to bias,
        "allowOthers" to allowOthers,
        "wake" to wake,
        "blocked" to blocked,
        "loading" to loading,
        "silencePercentile" to silence.percentile,
        "silenceMultiple" to silence.multiple,
        "silenceFloor" to silence.absoluteFloor,
        "silenceVoicedFraction" to silence.voicedFraction,
        // 三道闸各自的线，一起给出来对照。
        "acceptBarge" to Thresholds.accept(level, profiles.get().size, Thresholds.Gate.BARGE, bias),
        "acceptWake" to Thresholds.accept(level, profiles.get().size, Thresholds.Gate.WAKE, bias),
        "acceptTurn" to Thresholds.accept(level, profiles.get().size, Thresholds.Gate.TURN, bias),
        "band" to Thresholds.BAND,
    )
}
