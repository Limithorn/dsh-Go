package io.github.ccch1mneyyy.dsh_app.speech

import kotlin.math.log10
import kotlin.math.min
import kotlin.math.sqrt

/**
 * 归一化 LMS 回声消除器。
 *
 * 输入是 16 kHz 单声道采集帧和**已经对齐**的播放参考帧，输出写回同一帧。
 * 选 NLMS 而不是 WebRTC AEC3 的理由很实际：项目里没有 native C++ 构建链，
 * 而这个场景只有一条自家 TTS 播放流、采样率已知、没有网络抖动；一条
 * 64 ms 的自适应 FIR 足够把扬声器→麦克风的线性通路消掉，代价是几百行
 * Kotlin，而不是塞进一整套 AEC3 + 构建系统。
 *
 * 已知边界：房间混响的尾部、麦克风削波、以及双工时近端说话，单靠线性
 * NLMS 消不干净。这里用"双工降步长"避免把近端人声当成回声学进去；
 * 残余抑制留给已有的 SpeechGate/Voiceprint 层判断，不在这里乱加门。
 */
private class NlmsFilter(
    val taps: Int = 1024, // 64 ms @ 16 kHz
    private val mu: Float = 0.35f,
) {
    private val w = FloatArray(taps)
    private val x = FloatArray(taps)
    private var xPos = 0
    private var windowPower = 0f

    /** 最近一次双工判据：采集与参考的归一化相关。越低越可能是近端在说话。 */
    @Volatile var lastCorrelation = 0f
        private set

    /** 回声削减量（dB），前后 RMS 的平滑比。 */
    @Volatile var gainDb = 0f
        private set

    @Volatile var frames = 0L
        private set

    private var before = 0f
    private var after = 0f

    fun reset() {
        w.fill(0f)
        x.fill(0f)
        xPos = 0
        windowPower = 0f
        lastCorrelation = 0f
        gainDb = 0f
        frames = 0
        before = 0f
        after = 0f
    }

    fun run(mic: ShortArray, ref: ShortArray) {
        val n = min(mic.size, ref.size)
        if (n <= 0) return

        var micPower = 0f
        var refPower = 0f
        var cross = 0f
        for (i in 0 until n) {
            val d = mic[i] / 32768f
            val r = ref[i] / 32768f
            micPower += d * d
            refPower += r * r
            cross += d * r
        }
        lastCorrelation = (cross / sqrt(micPower * refPower + 1e-9f)).coerceIn(0f, 1f)

        val step = if (lastCorrelation >= DOUBLE_TALK_CORR) mu else mu * QUIET_STEP
        val norm = step / (windowPower + EPS)

        var outPower = 0f
        for (i in 0 until n) {
            // 逐采样推进参考：mic[i] 必须和 ref[i] 及其过去对齐，不能先
            // 把整帧写进延迟线再用帧末状态去减整帧（那样每帧只剩一个值）。
            val r = ref[i] / 32768f
            val old = x[xPos]
            windowPower += r * r - old * old
            x[xPos] = r
            xPos++
            if (xPos == taps) xPos = 0
            val idx = if (xPos == 0) taps - 1 else xPos - 1

            var y = 0f
            var k = 0
            var p = idx
            while (k < taps) {
                y += w[k] * x[p]
                p--
                if (p < 0) p = taps - 1
                k++
            }
            val d = mic[i] / 32768f
            val e = d - y
            outPower += e * e

            p = idx
            k = 0
            val delta = norm * e
            while (k < taps) {
                w[k] += delta * x[p]
                p--
                if (p < 0) p = taps - 1
                k++
            }
            mic[i] = (e * 32767f).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }

        val b = micPower / n
        val a = outPower / n
        before += SMOOTH * (b - before)
        after += SMOOTH * (a - after)
        gainDb = (10f * log10((before + 1e-8f) / (after + 1e-8f))).coerceIn(-24f, 24f)
        frames++
    }

    private companion object {
        const val DOUBLE_TALK_CORR = 0.35f
        const val QUIET_STEP = 0.15f
        const val EPS = 1e-4f
        const val SMOOTH = 0.08f
    }
}

/**
 * 通话链路上的软件 AEC 单例。
 *
 * 播放端（[PcmStream.write]）喂参考，采集端（[CallCapture]）取结果。
 * 默认开启：这是用户明确要求的"自己写 AEC"路径，系统 HAL 的 AEC/NS
 * 在这一模式下不再挂到采集上，避免两套消除器互相打架。
 * 诊断页可以关掉它回退到原路径（`softwareAecSet {enabled:false}`）。
 */
internal object SoftwareAec {
    @Volatile var enabled: Boolean = true
        private set

    @Volatile var active: Boolean = false
        private set

    private val reference = AecReference()
    private val filter = NlmsFilter()

    fun setEnabled(on: Boolean) {
        if (enabled == on) return
        enabled = on
        if (!on) end()
    }

    /** 一通通话开始：清掉上一通的参考和滤波器状态。 */
    fun begin() {
        reference.reset()
        filter.reset()
        active = true
    }

    fun end() {
        active = false
        reference.reset()
        filter.reset()
    }

    /** 播放侧原始 PCM（任意采样率）。不在通话中时也存着，begin() 会清掉。 */
    fun feedPlayback(rate: Int, pcm: ByteArray) {
        if (!enabled) return
        reference.feed(rate, pcm)
    }

    /** 采集侧 16 kHz 帧；有可信参考时原地消回声，否则什么都不做。 */
    fun processCapture(frame: ShortArray) {
        if (!enabled || !active) return
        val ref = reference.next(frame.size, frame) ?: return
        filter.run(frame, ref)
    }

    fun report(): Map<String, Any?> = mapOf(
        "enabled" to enabled,
        "active" to active,
        "mode" to "nlms",
        "taps" to filter.taps,
        "delayMs" to reference.delaySamples / 16.0,
        "correlation" to reference.lastCorrelation.toDouble(),
        "filterCorrelation" to filter.lastCorrelation.toDouble(),
        "gainDb" to filter.gainDb.toDouble(),
        "frames" to filter.frames,
        "alignedFrames" to reference.alignedFrames,
    )
}
