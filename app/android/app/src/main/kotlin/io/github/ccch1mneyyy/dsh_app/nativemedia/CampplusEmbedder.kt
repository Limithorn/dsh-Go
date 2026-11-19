package io.github.ccch1mneyyy.dsh_app.nativemedia

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.sqrt

/**
 * CAM++（3D-Speaker，zh-cn 16k）的一句话 → 192 维声纹向量。
 *
 * 模型的输入是 Kaldi log-mel（[batch, frames, 80]），不是原始波形；输出
 * [batch, 192]。这里负责把 fbank 拼成张量、跑一次、做 L2 归一化——归一化后
 * 两个向量的点积就是余弦相似度，比对时不必再算长度。
 */
internal class CampplusEmbedder(
    bytes: ByteArray,
    /** 静默检测的参数；设置页改了就换一份新的 embedder（见 [Voiceprint.setSilence]）。 */
    private val silence: KaldiFbank.Silence = KaldiFbank.Silence(),
) : AutoCloseable {
    private val env = OrtEnvironment.getEnvironment()
    private val model: OrtSession = OrtSession.SessionOptions().use { options ->
        options.setIntraOpNumThreads(1)
        options.setInterOpNumThreads(1)
        env.createSession(bytes, options)
    }
    private val fbank = KaldiFbank(silence = silence)

    val dimension: Int = 192

    private companion object {
        /** 打开会把每次的 fbank 形状打到 logcat；排查用，正常关掉。 */
        const val DEBUG = true
    }

    /** 一段 16k mono、-1..1 的音频 → 单位向量；太短或算出空值时返回 null。 */
    fun embed(samples: FloatArray): FloatArray? {
        // 全静音直接不给向量。
        //
        // 之前不管输什么都会算出一个向量：全 0 输入经 fbank/L2 之后得到一个
        // 退化的东西，与任何模板的余弦都可能很高。实测踩过——整段 -240dB
        // （纯 0）的窗口拿到过 0.849 的"本人"分。
        //
        // -65dBFS 作为门槛：实测这台 Xperia 说话在 -37~-42，真静音是 -240；
        // 留 20dB 余量，避免把轻声的话也挡掉。
        var energy = 0.0
        for (v in samples) energy += v.toDouble() * v
        val rmsDb = 10.0 * kotlin.math.log10(kotlin.math.max(energy / samples.size, 1e-24))
        if (rmsDb < -65.0) return null

        val frames = fbank.compute(samples) ?: return null
        if (frames.isEmpty()) return null
        // 诊断：fbank 的形状与取值范围。算错了这里一眼能看出来
        // （正常 log-mel 大约 -20..20，全 0 或全 -50 都说明有问题）。
        if (DEBUG) {
            var lo = Float.MAX_VALUE
            var hi = -Float.MAX_VALUE
            for (f in frames) for (v in f) { if (v < lo) lo = v; if (v > hi) hi = v }
            android.util.Log.i(
                "Campplus",
                "in=${samples.size} frames=${frames.size} bins=${frames[0].size} range=[$lo, $hi]",
            )
        }
        val dims = longArrayOf(1, frames.size.toLong(), 80)
        val flat = FloatBuffer.allocate(1 * frames.size * 80)
        for (frame in frames) for (v in frame) flat.put(v)
        flat.rewind()
        val input = OnnxTensor.createTensor(env, flat, dims)
        return input.use {
            model.run(mapOf(model.inputNames.first() to input)).use { result ->
                val out = result.get(0) as? OnnxTensor ?: return null
                val buffer = out.floatBuffer
                val vector = FloatArray(dimension)
                buffer.get(vector, 0, minOf(dimension, buffer.remaining()))
                l2(vector)
            }
        }
    }

    override fun close() {
        model.close()
    }

    private fun l2(v: FloatArray): FloatArray? {
        var sum = 0.0
        for (x in v) sum += x.toDouble() * x
        val n = sqrt(sum)
        if (n <= 1e-8) return null
        for (i in v.indices) v[i] = (v[i] / n).toFloat()
        return v
    }

}
