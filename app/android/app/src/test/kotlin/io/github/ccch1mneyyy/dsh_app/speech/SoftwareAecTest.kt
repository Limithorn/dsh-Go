package io.github.ccch1mneyyy.dsh_app.speech

import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.sqrt

class SoftwareAecTest {
    private companion object {
        const val FRAME = 320 // 20 ms @ 16 kHz
        const val DELAY = 1600 // 100 ms speaker-to-mic, inside the 20~400 ms search range
    }

    @Test
    fun cancelsDelayedPlaybackEcho() {
        val random = Random(20261124)
        val allRef = ArrayList<Short>()
        var beforePower = 0.0
        var afterPower = 0.0
        var measured = 0
        var report: Map<String, Any?> = emptyMap()

        SoftwareAec.setEnabled(true)
        SoftwareAec.begin()
        try {
            for (f in 0 until 180) { // 3.6 s: enough to find the lag and converge
                val ref = ShortArray(FRAME) { (random.nextInt(16001) - 8000).toShort() }
                allRef.addAll(ref.asIterable())
                SoftwareAec.feedPlayback(16000, bytes(ref))

                val echo = ShortArray(FRAME) { i ->
                    val at = f * FRAME + i - DELAY
                    val s = if (at >= 0) allRef[at] else 0
                    (s * 0.45).toInt().toShort()
                }
                val mic = echo.copyOf() // 安静房间：采集里只有回声
                SoftwareAec.processCapture(mic)

                if (f >= 130) {
                    for (i in mic.indices) {
                        beforePower += echo[i].toDouble() * echo[i]
                        afterPower += mic[i].toDouble() * mic[i]
                    }
                    measured++
                }
            }
            // end() 会清状态，诊断值必须在停止前抓。
            report = SoftwareAec.report()
        } finally {
            SoftwareAec.end()
        }

        val gain = 10 * kotlin.math.log10(beforePower / afterPower)
        assertTrue("echo reduced by $gain dB, expected > 10", gain > 10.0)
        assertTrue("aligned lag ${report["delayMs"]} ms, expected ~100", (report["delayMs"] as Double) in 95.0..105.0)
        assertTrue("filter correlation ${report["filterCorrelation"]}", (report["filterCorrelation"] as Double) > 0.7)
        assertTrue("frames counted: ${report["frames"]}", measured > 0)
    }

    @Test
    fun leavesMicrophoneUntouchedWithoutPlayback() {
        SoftwareAec.setEnabled(true)
        SoftwareAec.begin()
        try {
            val frame = ShortArray(FRAME) { (it * 97 - 12000).toShort() }
            val original = frame.copyOf()
            SoftwareAec.processCapture(frame)
            assertTrue(frame.contentEquals(original))
        } finally {
            SoftwareAec.end()
        }
    }

    private fun bytes(samples: ShortArray): ByteArray {
        val out = ByteArray(samples.size * 2)
        for (i in samples.indices) {
            out[2 * i] = (samples[i].toInt() and 0xFF).toByte()
            out[2 * i + 1] = (samples[i].toInt() shr 8).toByte()
        }
        return out
    }
}
