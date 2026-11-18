package io.github.ccch1mneyyy.dsh_app.nativemedia

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Kaldi 风格的 80 维 log-mel，喂给 CAM++ 声纹模型。
 *
 * 为什么不复用 [WhisperMel]：两者的窗、滤波器组、归一化都不一样。Whisper 用
 * Hann 窗、自己的 mel 映射；CAM++ 的 ONNX 文件元数据写的是 Kaldi 那一套
 * （Povey 窗、预加重 0.97、去 DC、25ms / 10ms、80 维、global-mean）。用错一套
 * 不会报错，只会让相似度整体偏低，而且偏低得没法解释——所以这里单独写一份，
 * 参数全部照 Kaldi 的默认值来，不做"看着差不多"的近似。
 *
 * 所有输入按 sherpa-onnx 的约定：[normalizeSamples] 为 true 时波形是 -1..1
 * 的 float（模型的 normalize_samples=1 是同一个意思）。
 */
internal class KaldiFbank(
    private val sampleRate: Int = 16_000,
    private val numBins: Int = 80,
    private val frameLengthMs: Double = 25.0,
    private val frameShiftMs: Double = 10.0,
    private val lowFreq: Double = 20.0,
    private val highFreq: Double = 0.0, // 0 = Nyquist
    private val preemph: Double = 0.97,
    private val energyFloor: Double = 1.0,
) {
    private val frameLength = (sampleRate * frameLengthMs / 1000.0).toInt()   // 400
    private val frameShift = (sampleRate * frameShiftMs / 1000.0).toInt()     // 160
    private val fftSize = nextPow2(frameLength)                               // 512
    private val numBinsFft = fftSize / 2 + 1                                  // 257
    private val window = povedWindow(frameLength)
    private val melBanks = melBank(numBins, fftSize, sampleRate, lowFreq, highFreq)

    /** 逐维减去的均值（global-mean CMN）。录制/推理同分布时用同一份。 */
    private var mean: DoubleArray? = null

    /**
     * 波形 → [frames, 80]。返回 null 表示不够一帧。
     *
     * [subtractMean] 为 true 时用累计均值做 CMN；模型自己也会在内部做一次
     * 归一化，外面这次是为了让不同音量下的分数更稳——两者不冲突。
     */
    fun compute(samples: FloatArray, subtractMean: Boolean = true): Array<FloatArray>? {
        if (samples.size < frameLength) return null
        // 预加重：y[n] = x[n] - 0.97 * x[n-1]，与 Kaldi 一致（第一帧用 round-robin 的那份）。
        val emphasized = DoubleArray(samples.size)
        for (i in samples.indices) {
            val prev = if (i == 0) samples[0] else samples[i - 1]
            emphasized[i] = samples[i] - preemph * prev
        }

        val count = (samples.size - frameLength) / frameShift + 1
        val out = ArrayList<FloatArray>(count)
        // 数一数有几帧是"有人声"的。静默的帧能量极低，分开数——
        // 这就是为什么纯静默也能算出一个向量：模型对全常数的输入照样吐东西，
        // 归一化之后是一串随机方向，和谁比都能有个 ±0.5 的分数。
        // 每帧的原始均方，循环结束后按"相对这段自己的底"来判断。
        val rawEnergies = DoubleArray(count)
        val buffer = DoubleArray(fftSize)
        val power = DoubleArray(fftSize)
        val frame = DoubleArray(frameLength)

        for (f in 0 until count) {
            val start = f * frameShift
            var sum = 0.0
            for (i in 0 until frameLength) {
                val v = emphasized[start + i]
                frame[i] = v
                sum += v
            }
            // 去直流，Kaldi 的 dither=0 时也做这一步。
            val dc = sum / frameLength
            var energy = 0.0
            // "这一帧有没有人声"用**未预加重**的原始能量判断：预加重会按频率
            // 衰减（220Hz 处约 -21dB），拿它判会把人声误判成静默。
            var raw = 0.0
            for (i in 0 until frameLength) {
                val centered = frame[i] - dc
                raw += centered * centered
                val v = centered * window[i]
                buffer[i] = v
                energy += v * v
            }
            rawEnergies[f] = raw / frameLength
            for (i in frameLength until fftSize) buffer[i] = 0.0
            // Kaldi 对整帧都乘一遍窗后算能量；低于 energyFloor 的帧给一个下限，避免 log(0)。
            for (i in frameLength until fftSize) energy += buffer[i] * buffer[i]
            if (energy <= energyFloor) energy = energyFloor

            fft(buffer, power)
            val bins = FloatArray(numBins)
            for (m in 0 until numBins) {
                var e = 0.0
                for (k in 0 until numBinsFft) {
                    val w = melBanks[m][k]
                    if (w != 0.0) e += w * power[k]
                }
                bins[m] = ln(max(e, Float.MIN_VALUE.toDouble())).toFloat()
            }
            out.add(bins)
        }
        if (out.isEmpty()) return null

        // 有没有人声，用**相对**判断：看有多少帧明显高于这段自己的低点。
        //
        // 不用绝对门限：同一个门限在不同手机、不同音量下意味着完全不同的东西——
        // 上一版用 1e-4，真人说话也被挡掉了。改成"比这段最安静的帧高 6dB 以上"，
        // 静默时所有帧差不多平（数出来的很少），说话时会有明显的高帧。
        val sorted = rawEnergies.sortedArray()
        val baseline = sorted[sorted.size / 5] // 最安静的两成，避开偶尔的咔哒声
        // 相对 +6dB，再抬到绝对下限之上。
        //
        // 下限不是摆设：通话里 AEC 会把开头削成近乎数字静默（实测 baseline 低到
        // 3e-10），这时"相对 +6dB"等于没门槛，噪声全被算成有人说话——于是
        // voiced/need 卡在线上来回摆，一时通过一时被挡。
        // 3e-6 约合 -55dBFS，比正常语音低得多，但高于任何"被削平"的残渣。
        val threshold = maxOf(baseline * 4.0, 3e-6)
        var voiced = 0
        for (e in rawEnergies) if (e > threshold) voiced++

        // 诊断：真人说话时数出几帧、这段的底是多少。
        android.util.Log.i(
            "KaldiFbank",
            "count=$count voiced=$voiced need=${maxOf(3, count / 5)} baseline=${"%.2e".format(baseline)}",
        )
        // 有人声的帧不到两成，就当这段没人在说——返回 null，别拿噪声去比。
        if (voiced < maxOf(3, count / 5)) return null

        if (subtractMean) {
            val running = mean
            if (running == null) {
                mean = DoubleArray(numBins).also { m ->
                    for (fr in out) for (k in 0 until numBins) m[k] += fr[k]
                    for (k in 0 until numBins) m[k] /= out.size
                }
            }
        }
        return out.toTypedArray()
    }

    /** 用给定均值做 CMN（推理时沿用录入阶段的均值，保证同分布）。 */
    fun applyMean(frames: Array<FloatArray>, mean: DoubleArray?): Array<FloatArray> {
        if (mean == null) return frames
        for (fr in frames) {
            for (k in fr.indices) fr[k] = (fr[k] - mean[k]).toFloat()
        }
        return frames
    }

    fun currentMean(): DoubleArray? = mean?.copyOf()

    fun loadMean(values: DoubleArray?) {
        mean = values?.copyOf()
    }

    private fun fft(input: DoubleArray, output: DoubleArray) {
        // 原地 radix-2；input 进来是实数帧，输出为功率谱。
        val n = fftSize
        val re = DoubleArray(n)
        val im = DoubleArray(n)
        for (i in 0 until n) re[i] = input[i]
        // 位反转置换
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j or bit
            if (i < j) {
                val tr = re[i]; re[i] = re[j]; re[j] = tr
                val ti = im[i]; im[i] = im[j]; im[j] = ti
            }
        }
        var len = 2
        while (len <= n) {
            val ang = -2.0 * PI / len
            val wr = cos(ang)
            val wi = kotlin.math.sin(ang)
            var i = 0
            while (i < n) {
                var curR = 1.0
                var curI = 0.0
                for (k in 0 until len / 2) {
                    val a = i + k
                    val b = a + len / 2
                    val tr = curR * re[b] - curI * im[b]
                    val ti = curR * im[b] + curI * re[b]
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                    val nR = curR * wr - curI * wi
                    curI = curR * wi + curI * wr
                    curR = nR
                }
                i += len
            }
            len = len shl 1
        }
        for (i in 0 until numBinsFft) {
            output[i] = re[i] * re[i] + im[i] * im[i]
        }
    }

    private companion object {
        fun nextPow2(n: Int): Int {
            var p = 1
            while (p < n) p = p shl 1
            return p
        }

        /** Kaldi 的 Povey 窗：0.5 - 0.5cos(2πn/(N-1))，再乘 0.85^... 的修正。 */
        fun povedWindow(size: Int): DoubleArray {
            val w = DoubleArray(size)
            val a = 2.0 * PI / (size - 1)
            for (i in 0 until size) {
                val v = 0.5 - 0.5 * cos(a * i)
                w[i] = v.pow(0.85)
            }
            return w
        }

        fun melBank(bins: Int, fftSize: Int, sampleRate: Int, lowFreq: Double, highFreq: Double): Array<DoubleArray> {
            val nyquist = sampleRate / 2.0
            val high = if (highFreq <= 0.0) nyquist else highFreq
            val lowMel = hzToMel(lowFreq)
            val highMel = hzToMel(high)
            val numBinsFft = fftSize / 2 + 1
            val bank = Array(bins) { DoubleArray(numBinsFft) }
            val melPoints = DoubleArray(bins + 2) { lowMel + (highMel - lowMel) * it / (bins + 1) }
            val binPoints = DoubleArray(bins + 2) { melToHz(melPoints[it]) * fftSize / sampleRate }

            for (m in 0 until bins) {
                val left = binPoints[m]
                val center = binPoints[m + 1]
                val right = binPoints[m + 2]
                for (k in 0 until numBinsFft) {
                    val x = k.toDouble()
                    val w = when {
                        x <= left || x >= right -> 0.0
                        x <= center -> if (center > left) (x - left) / (center - left) else 0.0
                        else -> if (right > center) (right - x) / (right - center) else 0.0
                    }
                    bank[m][k] = w
                }
            }
            return bank
        }

        fun hzToMel(hz: Double): Double = 1127.0 * ln(1.0 + hz / 700.0)

        fun melToHz(mel: Double): Double = 700.0 * (exp(mel / 1127.0) - 1.0)

        @Suppress("unused")
        fun db(x: Double): Double = 20.0 * log10(max(x, 1e-10))

        @Suppress("unused")
        fun norm(v: FloatArray): FloatArray {
            var s = 0.0
            for (x in v) s += x.toDouble() * x
            val n = sqrt(s).toFloat()
            if (n > 0f) for (i in v.indices) v[i] /= n
            return v
        }
    }
}
