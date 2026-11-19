package io.github.ccch1mneyyy.dsh_app.nativemedia

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * 只认白名单里那几个人的声音：包在别的 gate 外面，播放期间拦住外人的开口。
 *
 * 为什么放在这一层而不是 Dart：`CallCapture` 在拿到 [SpeechGate.Edge.START] 时才建
 * utterance 缓冲、才让 `SpeechPlugin` 发 speechStart 并 duck。判定挪到 Dart 就是
 * "事后撤销"——`bargeIn=false` 时根本没有缓冲可撤。在这里直接不吐 START，下游
 * 什么都没有发生，语义最干净。
 *
 * **怎么做到"开口那一刻就有结论"**：不等到 START 才去攒音频。整个播放期间都在
 * 攒 600ms 滑窗、持续判分，结论一直摆在那儿；门控吐 START 时直接读最近的结论。
 * `SpeechGate` 的 SETTLE_MS（400ms）本来就不吐 START，那段时间正好把第一段分算完。
 *
 * 三条不变量：
 *  1. 不在播放、功能关、或没有模板时**完全直通**，与没有这一层时逐帧一致；
 *  2. 判定落后于音频就丢掉这一段，绝不排队（读麦克风的线程不能被推理拖住）；
 *  3. 结论只在"算完了、且是针对最近这段音频"时才用；否则按 [Kind.UNKNOWN] 处理。
 */
class SpeakerGate(
    private val inner: TurnGate,
    private val embedder: Embedder,
    private val profiles: ProfileSource,
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-speaker-model").apply { isDaemon = true }
    },
    private val onVerdict: (Verdict) -> Unit = {},
) : TurnGate {

    /** 判定结论。分数是和白名单所有模板 cosine 的最大值。 */
    enum class Kind { YOU, OTHER, UNKNOWN }

    data class Verdict(
        val kind: Kind,
        val score: Float,
        val matched: String?,
        /** 这次判定是否发生在播放期间（只有这时才算"插话"候选）。 */
        val overPlayback: Boolean,
        /** 这段音频结束的帧序号，用来判断结论新旧。 */
        val atFrame: Long,
    )

    interface Embedder : AutoCloseable {
        fun embed(samples: FloatArray): FloatArray?
        override fun close() {}
    }

    /** 一份白名单模板：id 用来回报，向量已 L2 归一化。 */
    /**
     * 一份可用来比对的声纹模板。
     *
     * [source] 只是记着"这份是怎么录的"（call / wake / raw），比对时不参与
     * 计算——同一句话在不同场景下分数天然不同，取最高分自然会选中对的那份。
     * 它只用来数"有几个人"：同一个人录了两份，门槛不该按两人抬。
     */
    data class Profile(val id: String, val vector: FloatArray, val source: String = "call")

    fun interface ProfileSource {
        fun current(): List<Profile>
    }

    /**
     * 门槛与开关。[accept]/[reject] 由白名单人数补偿过（见 [Thresholds]）。
     * [allowOthers] 打开时外人也能开口，只是上层会慢一拍处理。
     */
    data class Cutoffs(
        val accept: Float = DEFAULT_ACCEPT,
        val reject: Float = DEFAULT_REJECT,
        val allowOthers: Boolean = true,
        val enabled: Boolean = false,
    )

    /** 落盘目录。由 SpeechPlugin 在启动时设一次；没设就不写。 */
    var dumpDir: String = ""

    private val windowFrames = WINDOW_MS / FRAME_MS
    private val capacity = windowFrames * FRAME_SAMPLES
    private val window = ShortArray(capacity)

    private var filled = 0
    private var frames = 0L
    private var generation = 0L
    private var inFlight = false
    private var playing = false

    @Volatile private var cutoffs = Cutoffs()

    /** 已落盘的份数（排查用）。 */
    private var dumped = 0
    @Volatile private var latest: Verdict? = null
    private val delivered = AtomicReference<Verdict?>(null)

    /** 最近一次判定，供上层与调测页读取；没有结论时为 null。 */
    fun verdict(): Verdict? = latest

    fun configure(next: Cutoffs) {
        cutoffs = next
        if (!next.enabled) latest = null
    }

    override var pause: TurnPause
        get() = inner.pause
        set(v) { inner.pause = v }

    override var bargeOffset: Float
        get() = inner.bargeOffset
        set(v) { inner.bargeOffset = v }

    override fun setPlaying(on: Boolean, nowMs: Long) {
        playing = on
        inner.setPlaying(on, nowMs)
        // 一段播报结束就作废旧结论：下一段播报是别人说的，不能拿旧的顶上。
        if (!on) {
            filled = 0
            latest = null
        }
    }

    override fun consume(frame: ShortArray, levelDb: Double, nowMs: Long): SpeechGate.Edge {
        val edge = inner.consume(frame, levelDb, nowMs)
        val c = cutoffs

        // 直通：不播放、功能关着、没有模板——都不插手，也不看音频。
        if (!playing || !c.enabled || profiles.current().isEmpty()) {
            filled = 0
            return edge
        }

        push(frame)
        if (edge != SpeechGate.Edge.START) return edge

        return when (answer()) {
            Kind.YOU -> SpeechGate.Edge.START
            // 外人：缺省拦住；开关打开时放行，上层看到 lastVerdict 是外人才会慢一拍。
            Kind.OTHER -> if (c.allowOthers) SpeechGate.Edge.START else SpeechGate.Edge.NONE
            // 认不准时放行，**不要拦住**。
            //
            // 早先这里是 NONE（"等人说久一点再分"），结果是死锁：开口要结论，
            // 结论要开完口才攒得够音频，于是谁都开不了口——连自己人也打断不了。
            // 宁可偶尔放过一个旁人，也不能让功能看起来是坏的。
            // 与 allowOthers 无关：没认出来就不该替人做决定。
            Kind.UNKNOWN -> SpeechGate.Edge.START
        }
    }

    /**
     * 把这次判定的音频写成 wav，存到应用私有目录。
     *
     * 只在 [DUMP] 打开时写，且最多 20 份——够看清问题，不至于占满存储。
     */
    private fun dumpWindow(audio: FloatArray) {
        if (!DUMP || dumped >= MAX_DUMPS) return
        // 只留"这段真的有人在说"的——静默窗口占绝大多数，留着它们只会把
        // 有用的那几条挤掉（实测：想看的几句全被 20 份静默覆盖了）。
        var sum = 0.0
        for (v in audio) sum += v * v
        val rms = kotlin.math.sqrt(sum / audio.size)
        if (rms < DUMP_MIN_RMS) return
        dumped++
        try {
            // 落到外部存储：release 版不能 run-as，私有目录里的东西拿不出来。
            // 这是排查用，正式版会把 DUMP 关掉。
            val dir = File(dumpDir).apply { mkdirs() }
            val file = File(dir, "judge-${System.currentTimeMillis()}.wav")
            val bytes = ByteBuffer.allocate(44 + audio.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            val dataSize = audio.size * 2
            bytes.put("RIFF".toByteArray())
            bytes.putInt(36 + dataSize)
            bytes.put("WAVEfmt ".toByteArray())
            bytes.putInt(16)
            bytes.putShort(1)
            bytes.putShort(1)
            bytes.putInt(RATE)
            bytes.putInt(RATE * 2)
            bytes.putShort(2)
            bytes.putShort(16)
            bytes.put("data".toByteArray())
            bytes.putInt(dataSize)
            for (v in audio) {
                val pcm = (v.coerceIn(-1f, 1f) * 32767).toInt().toShort()
                bytes.putShort(pcm)
            }
            file.writeBytes(bytes.array())
        } catch (e: Exception) {
            android.util.Log.w("SpeakerGate", "dump failed", e)
        }
    }

    /** 攒帧；攒满一段就派一次推理（上一段没算完就丢，不排队）。 */
    private fun push(frame: ShortArray) {
        val copy = minOf(FRAME_SAMPLES, frame.size)
        // 滑窗：先把旧的往前挪，腾出尾部空间。
        if (filled + copy > capacity) {
            val drop = filled + copy - capacity
            System.arraycopy(window, drop, window, 0, filled - drop)
            filled -= drop
        }
        System.arraycopy(frame, 0, window, filled, copy)
        filled += copy
        frames++

        if (filled < capacity || inFlight) return
        inFlight = true
        val gen = ++generation
        val at = frames
        val audio = FloatArray(capacity) { window[it] / 32768f }
        // 存一份判定用的原始音频：分数不对时，先听一下"到底送进去的是什么"。
        // 很多"模型不准"其实是送进去的音频本身不对（混了两个人的声音、被 AEC 削平）。
        dumpWindow(audio)
        try {
            worker.execute {
                val v = try {
                    judge(audio, at)
                } catch (_: Exception) {
                    null
                } catch (_: OutOfMemoryError) {
                    null
                }
                if (gen == generation) latest = v
                delivered.set(v)
                inFlight = false
                if (v != null) onVerdict(v)
            }
        } catch (_: Exception) {
            inFlight = false
        }
    }

    /** 门控开口那一刻能用的结论：够新才算。 */
    private fun answer(): Kind {
        val v = latest ?: run {
            if (playing) android.util.Log.i("SpeakerGate", "no verdict yet (frames=$frames filled=$filled)")
            return Kind.UNKNOWN
        }
        val age = frames - v.atFrame
        // 结论太旧就当作认不出——人可能换了。
        // 用一个固定的一秒，而不是"两倍窗口"：窗口加长到 1.5s 之后，
        // 两倍窗口就是 3 秒，那时早就可能换人说话了。
        return if (age > STALE_FRAMES) Kind.UNKNOWN else v.kind
    }

    private fun judge(audio: FloatArray, atFrame: Long): Verdict? {
        val vector = embedder.embed(audio) ?: return null
        val list = profiles.current()
        if (list.isEmpty()) return null
        var best = -1f
        var bestId: String? = null
        for (p in list) {
            val cos = dot(vector, p.vector)
            if (cos > best) {
                best = cos
                bestId = p.id
            }
        }
        val c = cutoffs
        val kind = when {
            best >= c.accept -> Kind.YOU
            best <= c.reject -> Kind.OTHER
            else -> Kind.UNKNOWN
        }
        android.util.Log.i(
            "SpeakerGate",
            "score=$best kind=$kind accept=${c.accept} reject=${c.reject} n=${list.size}",
        )
        return Verdict(kind, best, bestId, overPlayback = playing, atFrame = atFrame)
    }

    override fun reset() {
        inner.reset()
        filled = 0
        frames = 0
        latest = null
        delivered.set(null)
    }

    override fun close() {
        inner.close()
        worker.shutdownNow()
        embedder.close()
    }

    companion object {
        const val FRAME_MS = 20
        const val FRAME_SAMPLES = 320
        const val WINDOW_MS = 1500

        /** 结论超过这么久没更新就不算数。 */
        val STALE_FRAMES = 1000 / FRAME_MS

        /** 把判定用的音频存成 wav（排查用）。 */
        const val DUMP = true
        const val MAX_DUMPS = 30

        /**
         * 低于这个 RMS 的窗口不存。
         *
         * 取 −60dBFS（1e-3）偏松：实测这台机器说话时整段 RMS 在 −60 上下，
         * 再紧就一条都存不到了。静默窗口在 −85 以下，挡得住。
         */
        const val DUMP_MIN_RMS = 1e-3
        const val RATE = 16000

        /** 单模板默认门槛（P0 实测前先用这些值；只影响判定，不动任何现有阈值）。 */
        const val DEFAULT_ACCEPT = 0.72f
        const val DEFAULT_REJECT = 0.60f

        fun dot(a: FloatArray, b: FloatArray): Float {
            if (a.size != b.size) return -1f
            var s = 0.0
            for (i in a.indices) s += a[i].toDouble() * b[i]
            return s.toFloat()
        }
    }
}
