package io.github.ccch1mneyyy.dsh_app.speech

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGate
import kotlin.math.sqrt

/**
 * 录入声纹用的一小段录音。
 *
 * 为什么单独写一个而不是复用 [io.github.ccch1mneyyy.dsh_app.nativemedia.VoiceCapture]：
 * 那个是给唤醒词和语音输入用的（普通麦克风配置、走门控、只吐边缘事件）；录入要的是
 * **和通话完全同一套采集参数**（VOICE_COMMUNICATION + AEC + 16k mono），半个月后
 * 重录才不至于因为分布不同而分数下滑。
 */
internal object VoiceprintRecorder {
    private const val TAG = "VoiceprintRecorder"
    const val RATE = 16_000

    /**
     * 录一段声音时用哪个音源——决定这份模板将来"像"哪种场景下的声音。
     *
     * 为什么要分开：同一句话，走通话（VOICE_COMMUNICATION + AEC + 降噪）和
     * 走唤醒（无播放、无 AEC）拿到的是两段电平差十几 dB、频谱也被改过的音频，
     * 算出来的向量自然对不上。用一个模板硬扛两种分布，结果就是两边都不准。
     *
     * 实测那台机器：VC 峰值 −68.5 dBFS、VR −54.1、MIC −57.6。差 14dB 的时候，
     * 拿 VC 录的模板去认 VR 采的声音，分数会明显偏低。
     */
    enum class Source(val audioSource: Int, val label: String) {
        /** 通话用：AEC + 降噪开着，和推理时同分布。 */
        CALL(MediaRecorder.AudioSource.VOICE_COMMUNICATION, "call"),

        /** 唤醒用：不降噪、不消回声，电平和录入时接近。 */
        WAKE(MediaRecorder.AudioSource.VOICE_RECOGNITION, "wake"),

        /** 原始麦克风：不经过任何处理，电平最高，用于对照。 */
        RAW(MediaRecorder.AudioSource.MIC, "raw"),

        /**
         * 未处理：Android 7+ 的 UNPROCESSED 音源，规范要求「不做任何音频处理」。
         *
         * 为什么加它：Xperia 的 audio HAL 对第三方 App 的录音路径配了极低的
         * 麦克风增益，还默认挂了噪声门（Sony 社区和 XDA 上有 Xperia 10 III、
         * 1 V、Z2 的长期报告，实测低 20~25 dB）。UNPROCESSED 是唯一在规范层面
         * 声明「别动我的信号」的音源，最有可能绕开那套处理。
         *
         * 对照实测：这台 XQ-CQ72 上 CALL 峰值 0.0186、WAKE 0.0271，而昨天
         * 正常时是 0.09 上下——差 3~5 倍。
         */
        UNPROCESSED(MediaRecorder.AudioSource.UNPROCESSED, "unprocessed");

        companion object {
            fun of(wire: String?): Source = when (wire) {
                "wake" -> WAKE
                "raw" -> RAW
                "unprocessed" -> UNPROCESSED
                else -> CALL
            }
        }
    }

    /** 这一次录制用的音源。默认通话，和旧行为一致。 */
    @Volatile private var source = Source.CALL

    /** 开头 600ms 量环境底噪。 */
    private const val FLOOR_MS = 600

    @Volatile private var record: AudioRecord? = null
    @Volatile private var aec: AcousticEchoCanceler? = null
    @Volatile private var ns: NoiseSuppressor? = null
    @Volatile private var running = false
    private var thread: Thread? = null

    /**
     * 起停互斥：定时器到点和用户点"停"可能同时进来，两次 stop 会把
     * 刚起的那次一起掐掉（表现为 samples=0）。
     */
    private val lock = Any()
    private val chunks = ArrayList<ShortArray>()

    /** 实时电平（dBFS），录的时候给量表用。 */
    @Volatile var level: Double = -120.0
        private set

    /**
     * 这段录音的底噪（dBFS），从开头 [FLOOR_MS] 里学。
     *
     * 为什么不设一个固定的"够响"线：安静房间底噪 -65、说话 -48 就很好；
     * 嘈杂的房间底噪 -45，同样的 -48 其实是没听清。用一个绝对值，永远只对
     * 一种环境成立。改成"比底噪高多少"，两种环境都能用。
     */
    @Volatile var floor: Double = Double.NaN
        private set

    /** 开头这么多毫秒算底噪（这段时间里人还没开始说）。 */
    private val floorFrames = FLOOR_MS / 20
    private var seeded = 0

    val active: Boolean get() = running

    /** 开始录；返回 false 表示麦克风打不开。 */
    @SuppressLint("MissingPermission")
    fun start(which: Source = Source.CALL): Boolean = synchronized(lock) {
        source = which
        startLocked()
    }

    private fun startLocked(): Boolean {
        stopLocked()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val r = try {
            AudioRecord(
                source.audioSource,
                RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                min * 4,
            )
        } catch (e: Exception) {
            Log.w(TAG, "AudioRecord unavailable", e)
            return false
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return false
        }
        // 只有通话档开 AEC/降噪：这一档录到的要和推理时（通话）一样。
        //
        // 唤醒档和原始档必须关掉——它们的意义就是"不被处理过的声音"。
        // 开了 AEC 又把音量削下去，还多了回声门限，录出来的东西和唤醒时
        // 听到的完全不是一回事，模板就白录了。
        val processed = source == Source.CALL
        aec = if (processed && AcousticEchoCanceler.isAvailable()) {
            AcousticEchoCanceler.create(r.audioSessionId)?.also { it.enabled = true }
        } else null
        ns = if (processed && NoiseSuppressor.isAvailable()) {
            NoiseSuppressor.create(r.audioSessionId)?.also { it.enabled = true }
        } else null

        if (runCatching { r.startRecording() }.isFailure ||
            r.recordingState != AudioRecord.RECORDSTATE_RECORDING
        ) {
            r.release()
            return false
        }

        record = r
        synchronized(chunks) { chunks.clear() }
        running = true
        level = -120.0
        floor = Double.NaN
        seeded = 0
        val buffer = ShortArray(320) // 20ms
        // 丢掉起音瞬态，别让它进模板。
        //
        // AudioRecord 启动后的前 100~200ms 有一段强瞬态（实测起手 -35.6dB
        // 然后急降）。之前这段和说话一起进了模板，于是模板开头带着一段
        // 宽带"启动噪声"。
        //
        // 后果不是"模型不准"，而是：判定时如果窗口开头也有类似的启动瞬态
        // （比如实景测试刚启动），两边都含这段宽带噪声，余弦就被拉高——
        // 实测第一个窗口 0.76、之后 0.22，差的就是这个。
        //
        // 丢 250ms：够盖住瞬态，又不至于吃掉说话的开头（提示音之后人才开口）。
        val warmTarget = RATE * 250 / 1000
        var warm = 0
        while (warm < warmTarget && running) {
            val n = try {
                r.read(buffer, 0, buffer.size)
            } catch (_: Exception) {
                break
            }
            if (n > 0) {
                warm += n
            } else {
                break
            }
        }
        thread = Thread({
            while (running) {
                val n = try {
                    r.read(buffer, 0, buffer.size)
                } catch (_: Exception) {
                    break
                }
                if (n > 0) {
                    val db = SpeechGate.levelOf(buffer, n)
                    level = db
                    // 开头这一小段只用来量环境（人还没开口）。
                    if (seeded < floorFrames) {
                        floor = if (floor.isNaN()) db else minOf(floor, db)
                        seeded++
                    }
                    // 录入也乘同一个固定增益。
                    //
                    // 两处必须一致：模板是放大后算的向量，判定时如果不再放大，
                    // 同一个人的两段音频落在不同的幅度区间，余弦会掉下来。
                    Voiceprint.applyGain(buffer, n)
                    synchronized(chunks) { chunks.add(buffer.copyOf(n)) }
                }
            }
        }, "dsh-voiceprint-rec").apply { isDaemon = true }
        thread?.start()
        return true
    }

    /** 结束并取回全部采样（16k mono，-1..1）。太短返回空数组。 */
    fun stop(): FloatArray = synchronized(lock) { stopLocked() }

    private fun stopLocked(): FloatArray {
        running = false
        // 等读循环收尾：太短会把刚进的帧丢掉（表现为 samples=0）。
        val t = thread
        if (t != null) {
            runCatching { t.join(800) }
            if (t.isAlive) runCatching { t.interrupt() }
        }
        thread = null
        runCatching { record?.stop() }
        runCatching { record?.release() }
        record = null
        runCatching { aec?.release() }
        aec = null
        runCatching { ns?.release() }
        ns = null

        val all: List<ShortArray> = synchronized(chunks) {
            val copy = ArrayList(chunks)
            chunks.clear()
            copy
        }
        val total = all.sumOf { it.size }
        // 除响度外还要打 unique / peak / src。
        //
        // 只看 loudness 会把两种情况混成一种：实测一段 6 秒录音 loudness=-62.9，
        // 看着像「声音小」，实际整段只有 82 个不同采样值、范围 [-78, 34]，
        // 而正常录音是 2959 个值、峰值 3155。真因是 Xperia 的 HAL 把第三方
        // 录音的增益压低且挂了噪声门，不是代码在丢数据——区分这两者只能靠
        // 唯一值个数和峰值。
        //
        // src 一起打，是为了能直接对比不同音源：同一句话在 call / wake /
        // unprocessed 下各录一段，峰值差多少一眼可见。
        val flat = if (total > 0) all.flat() else FloatArray(0)
        val uniq = if (flat.isNotEmpty()) flat.toSet().size else 0
        val peak = if (flat.isNotEmpty()) flat.maxOf { kotlin.math.abs(it) } else 0f
        Log.i(
            TAG,
            "stop: chunks=${all.size} samples=$total src=${source.name} " +
                "loudness=${if (total > 0) loudness(flat) else -120.0} " +
                "unique=$uniq peak=${"%.4f".format(peak)}",
        )
        if (total == 0) return FloatArray(0)
        val out = FloatArray(total)
        var at = 0
        for (c in all) {
            for (v in c) {
                out[at++] = v / 32768f
            }
        }
        return out
    }

    private fun List<ShortArray>.flat(): FloatArray {
        val total = sumOf { it.size }
        val out = FloatArray(total)
        var at = 0
        for (c in this) for (v in c) out[at++] = v / 32768f
        return out
    }

    /** 这段录音的响度（RMS 的 dBFS），用来提示"太小声"。 */
    fun loudness(samples: FloatArray): Double {
        if (samples.isEmpty()) return -120.0
        var sum = 0.0
        for (v in samples) sum += v.toDouble() * v
        val rms = sqrt(sum / samples.size)
        return if (rms <= 1e-7) -120.0 else 20.0 * kotlin.math.log10(rms)
    }

    /** 粗略的"环境吵不吵"：过零率与能量的抖动，够用来提示换个地方。 */
    fun noisiness(samples: FloatArray): Double {
        // 只看开头那段（人还没开口）：它的起伏才代表环境，整段算会把"说话/停顿"
        // 的交替也算进去——那是人在说话，不是环境吵。
        val window = FLOOR_MS * RATE / 1000
        if (samples.size < window || window < 1600) return 0.0
        val span = 1600
        var sum = 0.0
        var count = 0
        var i = 0
        while (i + span <= window) {
            var e = 0.0
            for (k in i until i + span) e += samples[k].toDouble() * samples[k]
            sum += e / span
            count++
            i += span
        }
        if (count == 0) return 0.0
        val mean = sum / count
        var varSum = 0.0
        i = 0
        while (i + span <= window) {
            var e = 0.0
            for (k in i until i + span) e += samples[k].toDouble() * samples[k]
            val d = e / span - mean
            varSum += d * d
            i += span
        }
        return sqrt(varSum / count) / (mean + 1e-9)
    }

    /**
     * 对照实验：同一个麦克风、同一段时间，分别用 VOICE_COMMUNICATION / VOICE_RECOGNITION /
     * MIC 各录 1.5 秒，返回各自的峰值 dBFS。
     *
     * 存在的理由：录入一直判"太小声"（对着喊才 -34），权限、静音都正常，
     * 差这么多只能是音源本身的增益/降噪在吃声音。量一下才知道该换哪个。
     */
    @SuppressLint("MissingPermission")
    fun probeSources(): Map<String, Double> {
        val sources = listOf(
            "VOICE_COMMUNICATION" to MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            "VOICE_RECOGNITION" to MediaRecorder.AudioSource.VOICE_RECOGNITION,
            "MIC" to MediaRecorder.AudioSource.MIC,
        )
        val out = LinkedHashMap<String, Double>()
        for ((name, source) in sources) {
            val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val r = try {
                AudioRecord(source, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 4)
            } catch (e: Exception) {
                out[name] = -999.0
                continue
            }
            if (r.state != AudioRecord.STATE_INITIALIZED || runCatching { r.startRecording() }.isFailure) {
                r.release()
                out[name] = -998.0
                continue
            }
            val buffer = ShortArray(320)
            var peak = -120.0
            val end = System.currentTimeMillis() + 1500
            while (System.currentTimeMillis() < end) {
                val n = try { r.read(buffer, 0, buffer.size) } catch (_: Exception) { -1 }
                if (n > 0) {
                    val db = SpeechGate.levelOf(buffer, n)
                    if (db > peak) peak = db
                }
            }
            runCatching { r.stop() }
            r.release()
            out[name] = peak
        }
        Log.i(TAG, "probe: $out")
        return out
    }
}
