package io.github.ccch1mneyyy.dsh_app.nativemedia

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

/**
 * fbank 的两件事：形状对，以及**静默不能算出向量**。
 *
 * 后者是真机上报出来的 bug：纯静默也能得到 0.5 左右的相似度——因为模型对
 * 全常数的输入照样吐东西，归一化后是一串随机方向，和谁比都能有个数。
 * 这类输入必须在这里就被挡掉，不能留到比对那一步。
 */
class KaldiFbankTest {
    private val fbank = KaldiFbank()

    private fun tone(ms: Int, hz: Double = 220.0, amp: Double = 0.2): FloatArray {
        val n = 16000 * ms / 1000
        return FloatArray(n) { (amp * sin(2 * PI * hz * it / 16000.0)).toFloat() }
    }

    @Test
    fun `声音能算出 80 维的帧`() {
        val frames = fbank.compute(tone(1000))
        assertNotNull("有人声的音频应当算出帧", frames)
        val f = frames!!
        assertEquals(80, f[0].size)
        // 25ms 窗、10ms 步：1 秒约 98 帧（首尾各少一点）。
        assertEquals(98, f.size)
    }

    @Test
    fun `静默返回 null`() {
        // 全零：真正的数字静默。
        assertNull("全零必须被挡掉", fbank.compute(FloatArray(16000)))
    }

    @Test
    fun `极低的底噪也返回 null`() {
        // 约 -60 dBFS 的白噪：太低，不算有人在说。
        val quiet = FloatArray(16000) { ((Math.random() - 0.5) * 0.002).toFloat() }
        assertNull("底噪不能当成说话", fbank.compute(quiet))
    }

    @Test
    fun `短于两成的有声帧返回 null`() {
        // 说 150ms，剩下 850ms 全静默：有声帧不足两成。
        val samples = FloatArray(16000)
        tone(150).copyInto(samples)
        assertNull("零星几个有声帧不算一段话", fbank.compute(samples))
    }

    @Test
    fun `太短返回 null`() {
        assertNull(fbank.compute(FloatArray(100)))
    }

    @Test
    fun `同一段音频算两次结果一致`() {
        val a = fbank.compute(tone(800))!!
        val b = fbank.compute(tone(800))!!
        assertEquals(a.size, b.size)
        for (i in a.indices) {
            for (k in 0 until 80) {
                assertEquals("第 $i 帧第 $k 维应可重现", a[i][k], b[i][k], 1e-4f)
            }
        }
    }
}
