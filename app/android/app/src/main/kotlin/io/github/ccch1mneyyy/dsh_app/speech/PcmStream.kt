package io.github.ccch1mneyyy.dsh_app.speech

import android.media.AudioAttributes
import android.media.AudioManager
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGate
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * One stream of raw PCM16 mono audio played as it arrives (DeepSeek's TTS sends 24 kHz little-endian
 * samples while it is still synthesizing). The app writes chunks in order; a writer thread feeds an
 * [AudioTrack] in stream mode, so the first chunk is heard as soon as it lands.
 *
 * [end] means nothing more is coming: the stream reports [Listener.onDone] once the last sample has
 * actually played (a little silence after it makes even a very short line start). [write] answers
 * how many bytes wait to be played, so the app holds back when it runs far ahead of playback. [stop] silences it at once (from any thread); a stopped stream reports nothing
 * more after [Listener.onStopped]. The writer thread owns the track and releases it.
 *
 * With [levels] on, it reports how loud each 40 ms is, timed to when that audio is heard (for a mouth
 * or a speaking indicator).
 */
class PcmStream(
    val id: String,
    private val rate: Int,
    val call: Boolean,
    private val levels: Boolean,
    private val main: Handler,
    private val listener: Listener,
    /** 读系统音量用；null 就不补偿（测试环境）。 */
    private val audio: android.media.AudioManager? = null,
) {
    interface Listener {
        fun onStart(stream: PcmStream)
        fun onLevel(stream: PcmStream, value: Double)
        fun onDone(stream: PcmStream)
        fun onStopped(stream: PcmStream)
        fun onError(stream: PcmStream, reason: String)
    }

    private val queue = LinkedBlockingQueue<ByteArray>()

    /** Bytes written by the app and not yet handed to the track. */
    private val waiting = AtomicLong(0)
    private var bufferBytes = 0
    @Volatile private var stopped = false
    @Volatile private var finished = false
    private var track: AudioTrack? = null
    private var thread: Thread? = null

    /** Heard or about to be: the track has started. */
    @Volatile var started = false
        private set

    fun open(): Boolean {
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val t = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        // 一律媒体用法：增益按 STREAM_MUSIC 曲线算（Pixel 4 实测通话
                        // 音量 7 与 1 的输出功率都是 -33 dB，usage 不决定增益）。
                        // 免提/听筒的路由交给 SpeechPlugin 的通信模式切换，不在这条轨上
                        // 设 preferredDevice——那样 patch 会建到 earpiece，轨却留在 SPEAKER。
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(rate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                // About 400 ms: enough to ride out network jitter, small enough to stop at once.
                .setBufferSizeInBytes(max(min, rate * 2 * 2 / 5))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        }.getOrNull() ?: return false
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            t.release()
            return false
        }
        bufferBytes = runCatching { t.bufferSizeInFrames * 2 }.getOrDefault(rate * 2 * 2 / 5)
        // 不设 setStartThresholdInFrames：它会把轨钉在 FAST 输出上，通信模式切听筒时
        // 那条 FAST 轨不会跟着 setCommunicationDevice 迁到 earpiece。普通输出即可。
        track = t
        applyLoudnessCompensation(t)
        thread = Thread({ run(t) }, "dsh-speech-pcm").also { it.start() }
        return true
    }

    /** Queues one chunk; answers the bytes now waiting, or -1 once the stream has ended or stopped. */
    fun write(bytes: ByteArray): Long {
        if (stopped || finished) return -1
        if (bytes.isNotEmpty()) {
            waiting.addAndGet(bytes.size.toLong())
            queue.offer(bytes)
        }
        return waiting.get()
    }

    /** The bytes waiting to be played, or -1 once it has ended or stopped. */
    fun waiting(): Long = if (stopped) -1 else waiting.get()

    /** Nothing more is coming. */
    fun end() {
        if (stopped || finished) return
        finished = true
        queue.offer(END)
    }

    /**
     * 系统音量低的时候在轨上补一点。
     *
     * 为什么需要：Android 的音量曲线是厂商定的，普遍是"对数感"的——音量键
     * 从 15 档拉到 7 档，听感掉得比 7/15 多得多，50% 以下会明显偏小。这条
     * 不是我们能改的（改不了曲线），但可以在轨上乘一个系数把低档抬起来。
     *
     * 补偿用**平方根**而不是直接乘倒数：后者在最低档会把音乐里的本底噪声
     * 一起放大到听得见，而 sqrt 在 50% 时只补到 1.41 倍、10% 时补到 3.16 倍，
     * 听感上接近"线性"，又不至于把底噪糊上来。
     *
     * 上限 [MAX_BOOST]：再往上补容易在 100% 附近爆音，也不值得——真觉得小
     * 就把音量键往上按。
     */
    private fun applyLoudnessCompensation(t: AudioTrack) {
        val am = audio ?: return
        val max = runCatching { am.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0)
        if (max <= 0) return
        val cur = runCatching { am.getStreamVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(max)
        val ratio = (cur.toDouble() / max).coerceIn(0.02, 1.0)
        // 满档不动；越往下补得越多，但不超过 MAX_BOOST。
        val boost = (1.0 / kotlin.math.sqrt(ratio)).coerceAtMost(MAX_BOOST)
        if (boost > 1.001) {
            runCatching { t.setVolume(boost.toFloat()) }
            android.util.Log.i("PcmStream", "loudness: vol=$cur/$max boost=${"%.2f".format(boost)}")
        }
    }

    /** Quieter while the person may be speaking over it ([on]), or back to full. */
    fun duck(on: Boolean) {
        runCatching { track?.setVolume(if (on) DUCKED else currentGain()) }
    }

    /** duck 之后恢复要用的增益：补偿后的值，不是 1f。 */
    private fun currentGain(): Float {
        val am = audio ?: return 1f
        val max = runCatching { am.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0)
        if (max <= 0) return 1f
        val cur = runCatching { am.getStreamVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(max)
        val ratio = (cur.toDouble() / max).coerceIn(0.02, 1.0)
        return (1.0 / kotlin.math.sqrt(ratio)).coerceAtMost(MAX_BOOST).toFloat()
    }

    /** Silence now. Safe from any thread; the writer releases the track. */
    fun stop() {
        if (stopped) return
        stopped = true
        queue.offer(END)
        val t = track ?: return
        runCatching {
            t.pause()
            t.flush()
        }
    }

    private fun run(t: AudioTrack) {
        var frames = 0L
        var carry: Byte? = null
        val frameBytes = rate * 2 * LEVEL_MS / 1000
        val pending = ByteArray(frameBytes)
        var pendingLength = 0
        var failed: String? = null
        try {
            while (!stopped) {
                val chunk = queue.poll(200, TimeUnit.MILLISECONDS) ?: continue
                if (chunk === END) break
                waiting.addAndGet(-chunk.size.toLong())
                // Samples are two bytes; an odd chunk leaves its last byte for the next.
                val data = carry?.let { byteArrayOf(it) + chunk } ?: chunk
                val even = data.size and 1.inv()
                carry = if (even < data.size) data[data.size - 1] else null
                if (even == 0) continue
                if (!started) {
                    t.play()
                    started = true
                    main.post { if (!stopped) listener.onStart(this) }
                }
                var offset = 0
                while (offset < even && !stopped) {
                    val n = t.write(data, offset, even - offset)
                    if (n < 0) {
                        failed = "write $n"
                        break
                    }
                    if (n == 0) Thread.sleep(5)
                    if (levels) {
                        // Levels per 40 ms of what was just written, posted for when it will be heard.
                        var i = offset
                        while (i < offset + n) {
                            val take = min(frameBytes - pendingLength, offset + n - i)
                            System.arraycopy(data, i, pending, pendingLength, take)
                            pendingLength += take
                            i += take
                            if (pendingLength == frameBytes) {
                                val value = loudness(pending, pendingLength)
                                // Frames queued ahead of this one: written before it, less what has played.
                                val ahead = (frames + (i - offset) / 2 - t.playbackHeadPosition.toLong()).coerceAtLeast(0)
                                main.postDelayed({ if (!stopped) listener.onLevel(this, value) }, ahead * 1000 / rate)
                                pendingLength = 0
                            }
                        }
                    }
                    frames += n / 2
                    offset += n
                }
                if (failed != null) break
            }
            if (!stopped && failed == null && started) {
                // A buffer of silence after the last sample: a line shorter than the start
                // threshold starts too, and nothing is cut off. It is not counted in [frames].
                val silence = ByteArray(bufferBytes)
                var at = 0
                while (at < silence.size && !stopped) {
                    val n = t.write(silence, at, silence.size - at)
                    if (n <= 0) break
                    at += n
                }
                // Ended: wait until the last written sample has played (head position counts frames).
                val deadline = System.nanoTime() + (frames * 1000 / rate + 1500) * 1_000_000
                while (!stopped && t.playbackHeadPosition.toLong() and 0xFFFFFFFFL < frames && System.nanoTime() < deadline) {
                    Thread.sleep(20)
                }
            }
        } catch (_: InterruptedException) {
            stopped = true
        } catch (error: RuntimeException) {
            failed = error.javaClass.simpleName
        } finally {
            runCatching { t.stop() }
            runCatching { t.release() }
            track = null
        }
        val reason = failed
        main.post {
            when {
                stopped -> listener.onStopped(this)
                reason != null -> listener.onError(this, reason)
                else -> listener.onDone(this)
            }
        }
    }

    private fun loudness(bytes: ByteArray, length: Int): Double {
        val samples = ShortArray(length / 2)
        for (k in samples.indices) {
            samples[k] = ((bytes[2 * k].toInt() and 0xFF) or (bytes[2 * k + 1].toInt() shl 8)).toShort()
        }
        val db = SpeechGate.levelOf(samples, samples.size)
        // −50 dBFS and below is closed; −10 dBFS is wide open.
        return ((db + 50.0) / 40.0).coerceIn(0.0, 1.0)
    }

    private companion object {
        val END = ByteArray(0)
        const val LEVEL_MS = 40

        /** About −12 dB: still heard, out of the way of the person speaking. */
        const val DUCKED = 0.25f

        /** 低音量补偿的上限倍数。再高容易在满档附近爆音。 */
        const val MAX_BOOST = 3.0
    }
}
