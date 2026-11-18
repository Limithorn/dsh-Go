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
    fun start(): Boolean = synchronized(lock) { startLocked() }

    private fun startLocked(): Boolean {
        stopLocked()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val r = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
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
        // 与通话同源：AEC 开着，录到的才和推理时一样。
        aec = if (AcousticEchoCanceler.isAvailable()) {
            AcousticEchoCanceler.create(r.audioSessionId)?.also { it.enabled = true }
        } else null
        ns = if (NoiseSuppressor.isAvailable()) {
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
        Log.i(TAG, "stop: chunks=${all.size} samples=$total loudness=${if (total > 0) loudness(all.flat()) else -120.0}")
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
