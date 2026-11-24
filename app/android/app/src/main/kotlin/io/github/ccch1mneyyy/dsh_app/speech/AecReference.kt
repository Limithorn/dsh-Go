package io.github.ccch1mneyyy.dsh_app.speech

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * 播放参考信号的对齐器。
 *
 * 自建 AEC 的关键不是滤波器，而是**拿哪一帧播放去减哪一帧采集**。
 * 我们把 TTS 写进 AudioTrack **之前**的 PCM 存进环形缓冲；采集线程来取时，
 * 按估计出的 `delaySamples` 往回取同一段。这个时延包含 AudioTrack 缓冲、
 * 硬件输出和声音从扬声器回到麦克风的时间，不能凭常量猜——所以这里用
 * 归一化互相关在 20~400 ms 范围内找峰值，找到后平滑跟随。
 *
 * 不做 Android API 依赖：写入端和读取端都只是 PCM + 单调时钟，便于单测。
 */
internal class AecReference(
    private val capacity: Int = RATE * 3,
    private val minDelay: Int = RATE * 20 / 1000,
    private val maxDelay: Int = RATE * 400 / 1000,
) {
    private val buf = ShortArray(capacity)
    private var writePos = 0L
    private var lastWriteNs = 0L
    private var framesSinceEstimate = 0

    /** 当前认定的"播放→回采"时延（采样点）。 */
    @Volatile var delaySamples: Int = RATE * 120 / 1000
        private set

    /** 最近一次时延估计的置信度（0~1），诊断用。 */
    @Volatile var lastCorrelation: Float = 0f
        private set

    /** 最近一次成功对齐的帧数。 */
    @Volatile var alignedFrames: Long = 0L
        private set

    @Synchronized
    fun reset() {
        buf.fill(0)
        writePos = 0
        lastWriteNs = 0
        framesSinceEstimate = 0
        delaySamples = RATE * 120 / 1000
        lastCorrelation = 0f
        alignedFrames = 0
    }

    /**
     * 写入一段播放 PCM。TTS 常见 24 kHz，采集固定 16 kHz，所以先低通再插值。
     * 不低通直接抽点会把高频混叠进低频，互相关会锁到错误的时延上。
     */
    @Synchronized
    fun feed(rate: Int, pcm: ByteArray) {
        if (rate <= 0 || pcm.size < 2) return
        val decoded = ShortArray(pcm.size / 2) { i ->
            ((pcm[2 * i].toInt() and 0xFF) or (pcm[2 * i + 1].toInt() shl 8)).toShort()
        }
        val samples = if (rate == RATE) decoded else resample(decoded, rate)
        if (samples.isEmpty()) return
        for (s in samples) {
            buf[(writePos % capacity).toInt()] = s
            writePos++
        }
        lastWriteNs = System.nanoTime()
    }

    /**
     * 取与这帧采集对应的播放参考。播放停下超过 [ACTIVE_MS] 就返回 null——
     * 没有参考时滤波器必须直通，不能拿旧音频去减当前麦克风。
     */
    @Synchronized
    fun next(n: Int, mic: ShortArray): ShortArray? {
        val now = System.nanoTime()
        if (lastWriteNs == 0L || now - lastWriteNs > ACTIVE_MS * 1_000_000L) return null
        val len = min(n, mic.size)
        if (len <= 0) return null
        // 按帧计数而不是墙钟：墙钟在快速离线回放/低负载设备上可能几百毫秒
        // 才走一帧，错过整个更新窗口；按帧数才是"每 240 ms 音频"一次。
        framesSinceEstimate++
        if (framesSinceEstimate >= ESTIMATE_FRAMES) {
            estimate(mic, len)
            framesSinceEstimate = 0
        }
        val start = writePos - delaySamples - len
        if (start < 0) return null
        val out = ShortArray(len)
        for (i in 0 until len) out[i] = buf[slot(start + i)]
        alignedFrames++
        return out
    }

    /** 在 [minDelay, maxDelay] 里找与当前采集最像的那段播放。 */
    private fun estimate(mic: ShortArray, len: Int) {
        var micPower = 0.0
        for (i in 0 until len) micPower += mic[i].toDouble() * mic[i]
        if (micPower < MIN_POWER) return

        var bestLag = delaySamples
        var bestScore = -1.0
        var step = 8 // 0.5 ms; enough for speech-band echo alignment
        var lag = minDelay
        while (lag <= maxDelay) {
            val start = writePos - lag - len
            if (start >= 0) {
                var cross = 0.0
                var refPower = 0.0
                for (i in 0 until len) {
                    val r = buf[slot(start + i)].toDouble()
                    cross += mic[i] * r
                    refPower += r * r
                }
                if (refPower >= MIN_POWER) {
                    val score = cross / sqrt(micPower * refPower)
                    // 当前值有惯性：分数差不到 SWITCH_SCORE 就不抖过去，
                    // 否则旁人说话的一次巧合会把对齐拉到几十毫秒之外。
                    val biased = if (abs(lag - delaySamples) <= step) score + 0.03 else score
                    if (biased > bestScore) {
                        bestScore = biased
                        bestLag = lag
                    }
                }
            }
            lag += step
        }
        if (bestScore >= MIN_CORR) {
            delaySamples = bestLag
            lastCorrelation = bestScore.coerceAtMost(1.0).toFloat()
        } else {
            // 没找到可信峰：保留旧时延，但把置信度降下来给诊断看。
            lastCorrelation *= 0.8f
        }
    }

    private fun slot(pos: Long): Int = (pos % capacity).toInt()

    private fun resample(src: ShortArray, rate: Int): ShortArray {
        val outN = (src.size.toLong() * RATE / rate).toInt()
        if (outN <= 0) return ShortArray(0)
        // 一阶低通，截止远低于 8 kHz（目标 16 kHz 的 Nyquist）。
        val lp = FloatArray(src.size)
        var acc = 0f
        for (i in src.indices) {
            acc += LOWPASS_A * (src[i] - acc)
            lp[i] = acc
        }
        val out = ShortArray(outN)
        for (j in 0 until outN) {
            val pos = j.toDouble() * rate / RATE
            val i = min(pos.toInt(), src.size - 1)
            val k = min(i + 1, src.size - 1)
            val f = (pos - i).toFloat()
            val v = lp[i] + (lp[k] - lp[i]) * f
            out[j] = v.toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        return out
    }

    companion object {
        const val RATE = 16000

        /** 超过这个时间没收到播放 PCM 就认为不在放音。 */
        const val ACTIVE_MS = 400L

        /** 每 12 帧（240 ms 音频）重估一次时延，代价约 25 万次乘加。 */
        const val ESTIMATE_FRAMES = 12

        private const val MIN_POWER = 1_000_000.0 // 约 −45 dBFS，再小就只剩底噪
        private const val MIN_CORR = 0.45
        private const val SWITCH_SCORE = 0.03
        private const val LOWPASS_A = 0.42f
    }
}
