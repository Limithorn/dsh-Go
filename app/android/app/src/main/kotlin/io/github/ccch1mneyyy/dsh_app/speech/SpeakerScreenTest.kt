package io.github.ccch1mneyyy.dsh_app.speech

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AudioEffect
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * 实景测试：TTS 正在说话的时候，量"人说话能不能打断"。
 *
 * 为什么不能离线测：自打断和人插话都只在**扬声器真的在响**时才有意义。
 * AI 的声音从扬声器出来、被机壳绕回麦克风、经 AEC 削掉一部分——这条声学
 * 路径跟音量、握姿、免提还是听筒都有关系。离线跑 embed 复现不了。
 *
 * 这里只做采集和判定，不自己发声：TTS 由 Dart 侧起（复用现有
 * CompanionVoice 通道），因为"说什么、说多久"要让界面上的人看见。
 *
 * 每次 1.5 秒的窗口算一个分数（和通话里 SpeakerGate 的窗口一致，否则分数
 * 不可比），并把这段音频留给界面回听——"到底因为什么判成这样"，听一遍就
 * 知道了，不用再猜。
 */
internal object SpeakerScreenTest {
    private const val TAG = "SpeakerScreenTest"

    /** 和 SpeakerGate.WINDOW_MS 一致：窗口长度不同，分数不能直接比。 */
    private const val WINDOW_MS = 1500

    private const val RATE = 16_000
    private const val FRAME_MS = 20
    private const val FRAME_SAMPLES = RATE / 1000 * FRAME_MS
    private val windowSamples = WINDOW_MS / 1000 * RATE

    private val running = AtomicBoolean(false)

    @Volatile private var thread: Thread? = null

    /** 采集时 AEC 是否真的挂上了。false 表示回声没被削，分数会虚高。 */
    @Volatile var echoCancelled: Boolean = false
        private set

    /** 这次采集的 AEC 详情，界面上逐层显示。 */
    @Volatile internal var lastAec: AecSupport.Report? = null
        private set

    val isRunning: Boolean get() = running.get()

    /** 一次判定窗口的结果。 */
    data class Window(
        /** 和白名单里最像的那个的余弦；没算出向量时是 -1。 */
        val score: Float,
        /** YOU / OTHER / UNKNOWN / NONE / NOPROFILE。 */
        val kind: String,
        /** 这段的响度（dBFS）。看"是不是根本没收到声音"用。 */
        val rms: Double,
        /** 当时闸门会不会放行——也就是"这次算不算打断成功"。 */
        val barged: Boolean,
        /** 这段音频，16k mono。留给界面回听。 */
        val audio: FloatArray,
    )

    /**
     * 开始采集并判定。
     *
     * [onWindow] 每 1.5 秒回调一次，在工作线程上跑，不要在里面碰 UI。
     */
    @SuppressLint("MissingPermission")
    fun start(onWindow: (Window) -> Unit): Boolean {
        if (running.getAndSet(true)) return false
        val t = Thread({ loop(onWindow) }, "dsh-screen-test").apply { isDaemon = true }
        thread = t
        t.start()
        return true
    }

    fun stop() {
        running.set(false)
        thread?.let { runCatching { it.join(1200) } }
        thread = null
    }

    @SuppressLint("MissingPermission")
    private fun loop(onWindow: (Window) -> Unit) {
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) {
            running.set(false)
            return
        }
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, RATE / 5 * 2),
            )
        } catch (e: Exception) {
            Log.w(TAG, "AudioRecord unavailable", e)
            running.set(false)
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            running.set(false)
            return
        }

        // 和 CallCapture 完全一样地挂效果器：测试要反映通话时的真实条件。
        // 顺带量出"AEC 到底有没有生效"——Sony 之类的 ROM 上，
        // isAvailable 是 true 但 create 返回 null 是常见事。
        val effects = ArrayList<AudioEffect>()
        val report = AecSupport.attach(record, effects)
        echoCancelled = report.effective
        lastAec = report

        if (runCatching { record.startRecording() }.isFailure ||
            record.recordingState != AudioRecord.RECORDSTATE_RECORDING
        ) {
            effects.forEach { runCatching { it.release() } }
            record.release()
            running.set(false)
            return
        }

        Log.i(TAG, "started aec=$echoCancelled")

        val buffer = ShortArray(FRAME_SAMPLES)
        val window = ShortArray(windowSamples)
        var filled = 0

        try {
            while (running.get()) {
                val n = runCatching { record.read(buffer, 0, buffer.size) }.getOrDefault(-1)
                if (n <= 0) continue
                var i = 0
                while (i < n) {
                    val take = minOf(n - i, window.size - filled)
                    System.arraycopy(buffer, i, window, filled, take)
                    filled += take
                    i += take
                    if (filled < window.size) continue
                    filled = 0
                    onWindow(judge(FloatArray(window.size) { window[it] / 32768f }))
                    if (!running.get()) break
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "capture loop ended", e)
        } finally {
            runCatching { record.stop() }
            runCatching { record.release() }
            effects.forEach { runCatching { it.release() } }
            running.set(false)
            Log.i(TAG, "stopped")
        }
    }

    private fun judge(audio: FloatArray): Window {
        var sum = 0.0
        for (v in audio) sum += v * v
        val rms = sqrt(sum / audio.size)
        val rmsDb = 20 * log10(maxOf(rms, 1e-9))

        val vector = runCatching { Voiceprint.embed(audio) }.getOrNull()
        if (vector == null || vector.isEmpty()) {
            return Window(score = -1f, kind = "NONE", rms = rmsDb, barged = false, audio = audio)
        }
        val profiles = Voiceprint.currentProfiles()
        if (profiles.isEmpty()) {
            return Window(score = -1f, kind = "NOPROFILE", rms = rmsDb, barged = false, audio = audio)
        }
        var best = -1f
        for (p in profiles) {
            var dot = 0f
            val len = minOf(vector.size, p.vector.size)
            for (i in 0 until len) dot += vector[i] * p.vector[i]
            if (dot > best) best = dot
        }
        val c = Voiceprint.cutoffs()
        val kind = when {
            best >= c.accept -> "YOU"
            best <= c.reject -> "OTHER"
            else -> "UNKNOWN"
        }
        // 闸门的实际行为：YOU 放行；OTHER 看 allowOthers；UNKNOWN 一律放行
        // （那一处是有意为之——认不准时不替人做决定，见 SpeakerGate 的注释）。
        // 这里照抄同一套规则，否则"测出来能打断"和"真的能打断"对不上。
        val barged = when (kind) {
            "YOU" -> true
            "OTHER" -> c.allowOthers
            else -> true
        }
        Log.i(TAG, "score=${"%.3f".format(best)} kind=$kind rms=${"%.1f".format(rmsDb)} barged=$barged")
        return Window(score = best, kind = kind, rms = rmsDb, barged = barged, audio = audio)
    }

    /** 把一段音频写成 16k mono 的 wav，给界面回听。 */
    fun writeWav(file: File, audio: FloatArray) {
        val dataSize = audio.size * 2
        val bytes = ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN)
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
            bytes.putShort((v.coerceIn(-1f, 1f) * 32767).toInt().toShort())
        }
        file.parentFile?.mkdirs()
        file.writeBytes(bytes.array())
    }
}
