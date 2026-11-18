package io.github.ccch1mneyyy.dsh_app.speech

import android.content.Context
import android.content.res.AssetManager
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.nativemedia.CampplusEmbedder
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

    /** 唤醒也认声音。与 [enabled] 分开：通话和唤醒是两个独立的闸。 */
    @Volatile var wake: Boolean = false

    /** 每次判定的回调（影子日志 / 调测页 / Dart 事件），由 [SpeechPlugin] 接上。 */
    @Volatile var onVerdict: ((SpeakerGate.Verdict) -> Unit)? = null

    val isReady: Boolean get() = embedder != null && !blocked

    /** 当前门槛；人数变了要跟着变（去人后门槛回落）。 */
    fun cutoffs(gate: Thresholds.Gate = Thresholds.Gate.BARGE): SpeakerGate.Cutoffs {
        val n = profiles.get().size
        val accept = Thresholds.accept(level, n, gate)
        val reject = Thresholds.reject(level, n, gate)
        // 唤醒自己有个开关；通话看总开关。两者都用同一份模板。
        val on = if (gate == Thresholds.Gate.WAKE) wake else enabled
        return SpeakerGate.Cutoffs(
            accept = accept,
            reject = reject,
            allowOthers = allowOthers,
            // 没有模板就不算开：判定需要比对对象。
            enabled = on && n > 0 && !blocked,
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
    ) {
        this.enabled = enabled
        this.allowOthers = allowOthers
        this.level = level
        this.wake = wake
        list?.let { profiles.set(it) }
    }

    /** 后台加载模型；调用方不阻塞。 */
    fun warmUp(assets: AssetManager) {
        if (embedder != null || loading || blocked) return
        loading = true
        Thread({
            try {
                val bytes = assets.open("speech/$MODEL").use { it.readBytes() }
                embedder = CampplusEmbedder(bytes)
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
    )
}
