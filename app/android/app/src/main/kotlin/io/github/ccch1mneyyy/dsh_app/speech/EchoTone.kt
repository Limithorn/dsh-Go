package io.github.ccch1mneyyy.dsh_app.speech

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.util.Log
import kotlin.math.PI
import kotlin.math.sin

/**
 * 测 AEC 用的测试音。
 *
 * 为什么不是"放一段人声录音"：测的是**回声路径**，不是识别能力。要的是一段
 * 已知、稳定、覆盖人声频段的信号，这样"漏回来多少"才有可比性。放人声录音
 * 的话，每次内容、音量包络不同，两次测的结果没法相减。
 *
 * 用 200Hz→3.5kHz 的线性扫频，3 秒一轮，循环播。这个频段正是 AEC 主要
 * 处理的范围，也是手机扬声器最容易漏进麦克风的范围。
 *
 * 音量上故意用**媒体流的满音量**：测的是"最坏情况"，如果满音量都不漏，
 * 平时就不可能漏。
 */
internal class EchoTone(context: Context) {

    private val audio = context.getSystemService(AudioManager::class.java)

    @Volatile private var track: AudioTrack? = null
    @Volatile private var thread: Thread? = null
    @Volatile private var running = false

    fun start() {
        if (running) return
        running = true
        val t = Thread({ loop() }, "dsh-echo-tone").apply { isDaemon = true }
        thread = t
        t.start()
    }

    fun stop() {
        running = false
        thread?.let { runCatching { it.join(600) } }
        thread = null
        runCatching { track?.pause() }
        runCatching { track?.flush() }
        runCatching { track?.stop() }
        runCatching { track?.release() }
        track = null
    }

    fun release() = stop()

    private fun loop() {
        val rate = 48_000
        val min = AudioTrack.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (min <= 0) {
            Log.w("EchoTone", "no buffer")
            running = false
            return
        }
        val t = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        // 和 AI 说话同一条路：媒体用法，这样它和正常播放走同一个
                        // 增益、同一个输出设备，测出来的才有意义。
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(rate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(min, rate * 2 / 5))
                .build()
        }.getOrNull()
        if (t == null) {
            running = false
            return
        }
        track = t
        // 满音量：测最坏情况。原音量测完恢复。
        val am = audio
        val streamMax = if (am != null) {
            runCatching { am.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0)
        } else 0
        val before = if (am != null) {
            runCatching { am.getStreamVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0)
        } else 0
        if (am != null && streamMax > 0 && before < streamMax) {
            runCatching { am.setStreamVolume(AudioManager.STREAM_MUSIC, streamMax, 0) }
        }

        try {
            runCatching { t.play() }
            val chunk = ShortArray(2048)
            var phase = 0.0
            val total = rate * 3 // 3 秒一轮
            var i = 0
            while (running) {
                for (k in chunk.indices) {
                    // 200Hz → 3.5kHz 线性扫频
                    val frac = (i % total).toDouble() / total
                    val f = 200.0 + (3500.0 - 200.0) * frac
                    phase += 2 * PI * f / rate
                    if (phase > 2 * PI) phase -= 2 * PI
                    // 幅度 0.85：留点余量，避免满幅削顶产生谐波干扰测量。
                    chunk[k] = (sin(phase) * 0.85 * 32767).toInt().toShort()
                    i++
                }
                val n = runCatching { t.write(chunk, 0, chunk.size) }.getOrDefault(-1)
                if (n < 0) break
            }
        } catch (e: Exception) {
            Log.w("EchoTone", "tone loop ended", e)
        } finally {
            if (am != null && streamMax > 0 && before in 1 until streamMax) {
                runCatching { am.setStreamVolume(AudioManager.STREAM_MUSIC, before, 0) }
            }
        }
    }
}
