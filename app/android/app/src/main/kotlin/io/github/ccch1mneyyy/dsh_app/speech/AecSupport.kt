package io.github.ccch1mneyyy.dsh_app.speech

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * AEC 到底开没开，以及为什么。
 *
 * ### 为什么需要单独一层
 *
 * `AcousticEchoCanceler.isAvailable()` 只是个愿望：它说这个 ROM 支持，
 * 不保证你能用上。真正能不能消回声，取决于四层：
 *
 * 1. ROM 声称支持（isAvailable）
 * 2. 拿得到 effect 对象（create 返回非 null）
 * 3. 真的启用成功（setEnabled 后 enabled 读回 true）
 * 4. **音源本身带 HAL 级 AEC**（VOICE_COMMUNICATION 自带，拿不到对象也生效）
 *
 * 第 4 层最容易误判：Sony/部分 MIUI 把 AEC 挪进了 audio HAL，
 * AudioEffect 这层 create 返回 null，但回声其实被 HAL 消掉了。反过来也有：
 * isAvailable 是 true、create 也成功、setEnabled 也不报错，但 enabled 读回
 * false——那是真没开。
 *
 * 所以这里不只报"开没开"，而是把每一层的结果都留下来，出问题时能看出断在
 * 哪一层。
 *
 * ### 13 与 14 的差别
 *
 * - **13（T）**：AEC 一律走 AudioEffect。`create()` 一般能拿到对象。
 * - **14（U）**：AAudio/MMAP 路径普及，部分 ROM 把效果处理移进 HAL，
 *   `AudioEffect` 层变成空壳：create 成功但 enabled 读回 false，或者
 *   create 直接返回 null。这种情况只能靠第 4 层（音源自带）兜底。
 *
 * 对第 4 层，我们能做的不是"打开它"——它本来就开着，而是**确认它是否在
 * 起作用**：录一小段播放中的声音，看有没有回声残留。这个探测在
 * [SpeakerScreenTest] 里做，这里只负责把状态说清楚。
 */
internal object AecSupport {

    private const val TAG = "AecSupport"

    /** 一层一层的结论。界面和日志都用这个。 */
    data class Report(
        /** ROM 声称支持 AEC。 */
        val available: Boolean,
        /** 拿到了 effect 对象。 */
        val created: Boolean,
        /** setEnabled 调用成功（没抛异常、返回 SUCCESS）。 */
        val enabledCallOk: Boolean,
        /** 读回 effect.enabled == true。 */
        val enabledConfirmed: Boolean,
        /** 降噪的同样四项。 */
        val nsAvailable: Boolean,
        val nsCreated: Boolean,
        val nsEnabledConfirmed: Boolean,
        /** 这次采集用的音源名字，见 [sourceName]。 */
        val source: String,
        /** 这个音源是否自带 HAL 级 AEC。 */
        val sourceHasHalAec: Boolean,
        /** 最终认定"回声被消掉了"。 */
        val effective: Boolean,
        /** 一句话解释：为什么 effective 是这个值。 */
        val note: String,
    ) {
        val summary: String
            get() = when {
                effective && enabledConfirmed -> "AEC 已开（AudioEffect 层确认）"
                effective && sourceHasHalAec -> "AEC 已开（音源自带，HAL 级）"
                available && !created -> "AEC 开不了：ROM 说支持但拿不到对象"
                available && created && !enabledConfirmed -> "AEC 开不了：effect 拿得到但启用不成功"
                !available -> "这台机器不支持 AEC"
                else -> "AEC 状态不明"
            }
    }

    fun sourceName(source: Int): String = when (source) {
        MediaRecorder.AudioSource.VOICE_COMMUNICATION -> "VOICE_COMMUNICATION"
        MediaRecorder.AudioSource.VOICE_RECOGNITION -> "VOICE_RECOGNITION"
        MediaRecorder.AudioSource.MIC -> "MIC"
        MediaRecorder.AudioSource.VOICE_CALL -> "VOICE_CALL"
        MediaRecorder.AudioSource.CAMCORDER -> "CAMCORDER"
        MediaRecorder.AudioSource.DEFAULT -> "DEFAULT"
        else -> "OTHER($source)"
    }

    /**
     * 这个音源是否自带系统级回声消除。
     *
     * `VOICE_COMMUNICATION` 在规范里就要求带 AEC/AGC/NS（HAL 实现），
     * 所以哪怕 AudioEffect 层失败，回声通常也被削过。
     *
     * `VOICE_RECOGNITION` 只要求"不做过度的信号处理"，**不保证有 AEC**。
     * 这点很重要：把通话音源换成识别之后，回声会明显更容易漏回来。
     */
    fun hasHalAec(source: Int): Boolean = source == MediaRecorder.AudioSource.VOICE_COMMUNICATION

    /**
     * 给一个已经建好的 [AudioRecord] 挂 AEC 和降噪，并记下每一层结果。
     *
     * [effects] 由调用方持有，停止录音时一起释放。
     */
    fun attach(record: AudioRecord, effects: MutableList<AudioEffect>): Report {
        val source = runCatching { record.audioSource }.getOrDefault(MediaRecorder.AudioSource.DEFAULT)

        val aeAvailable = runCatching { AcousticEchoCanceler.isAvailable() }.getOrDefault(false)
        var aeCreated = false
        var aeCallOk = false
        var aeConfirmed = false
        if (aeAvailable) {
            runCatching { AcousticEchoCanceler.create(record.audioSessionId) }.getOrNull()?.let { e ->
                effects += e
                aeCreated = true
                aeCallOk = runCatching { e.enabled = true; true }.getOrDefault(false)
                aeConfirmed = runCatching { e.enabled }.getOrDefault(false)
                if (!aeConfirmed) {
                    // 14 上常见：create 给了对象，setEnabled 不报错，但读回 false。
                    // 这时对象是死的，留着没用，释放掉免得占着音频会话。
                    runCatching { e.release() }
                    effects.remove(e)
                }
            }
        }

        val nsAvailable = runCatching { NoiseSuppressor.isAvailable() }.getOrDefault(false)
        var nsCreated = false
        var nsConfirmed = false
        if (nsAvailable) {
            runCatching { NoiseSuppressor.create(record.audioSessionId) }.getOrNull()?.let { e ->
                effects += e
                nsCreated = true
                nsConfirmed = runCatching { e.enabled = true; e.enabled }.getOrDefault(false)
            }
        }

        val halAec = hasHalAec(source)
        // 认定"回声被消了"的条件：AudioEffect 层确认成功，或者音源自带 HAL 级 AEC。
        // 后者是 14 上唯一能指望的，前者是 13 上常见的。
        val effective = aeConfirmed || halAec

        val note = when {
            aeConfirmed -> "AudioEffect 层启用成功，回声由它消"
            aeAvailable && !aeCreated ->
                "ROM 报支持，但 create 返回 null——效果器在 HAL 里，AudioEffect 层拿不到。" +
                    if (halAec) "当前音源自带 AEC，仍可能有效，需要实景测试确认。" else "当前音源不带 AEC，回声可能没消。"
            aeCreated && !aeConfirmed ->
                "create 成功但 enabled 读回 false——Android 14 上效果器被挪进 HAL 时的典型表现。" +
                    if (halAec) "当前音源自带 AEC，仍可能有效。" else "当前音源不带 AEC，回声可能没消。"
            !aeAvailable && halAec -> "ROM 没暴露 AudioEffect，但当前音源自带 HAL 级 AEC。"
            !aeAvailable -> "ROM 没暴露 AudioEffect，且当前音源不带 AEC。"
            else -> "状态不明，用实景测试确认。"
        }

        Log.i(
            TAG,
            "sdk=${Build.VERSION.SDK_INT} source=${sourceName(source)} " +
                "ae(avail=$aeAvailable created=$aeCreated callOk=$aeCallOk confirmed=$aeConfirmed) " +
                "ns(avail=$nsAvailable created=$nsCreated confirmed=$nsConfirmed) " +
                "halAec=$halAec effective=$effective",
        )

        return Report(
            available = aeAvailable,
            created = aeCreated,
            enabledCallOk = aeCallOk,
            enabledConfirmed = aeConfirmed,
            nsAvailable = nsAvailable,
            nsCreated = nsCreated,
            nsEnabledConfirmed = nsConfirmed,
            source = sourceName(source),
            sourceHasHalAec = halAec,
            effective = effective,
            note = note,
        )
    }

    /**
     * 实测量一次"回声到底消掉没有"。
     *
     * 做法：播放一段人声，同时录，比较"播放时"和"停止播放后"的底噪。
     * 如果两者差不多，说明播放的声音没进麦克风（AEC 有效）；如果播放时明显
     * 更响，就是漏回来了。
     *
     * 这里只提供采集部分，播放由调用方负责——[SpeakerScreenTest] 已经有
     * TTS 在说话了，直接复用那一轮的录音更省事。
     */
    data class EchoProbe(
        /** 播放时的 RMS（dBFS）。 */
        val playingDb: Double,
        /** 停止播放后的 RMS（dBFS）。 */
        val silentDb: Double,
    ) {
        /** 播放时比静默高多少。小于 [LEAK_THRESHOLD] 认为没漏。 */
        val leak: Double get() = playingDb - silentDb

        val verdict: String
            get() = when {
                leak < LEAK_THRESHOLD -> "回声没漏进来（差 ${"%.1f".format(leak)} dB）"
                else -> "回声漏进来了（差 ${"%.1f".format(leak)} dB）"
            }

        companion object {
            /** 播放时比静默高 10 dB 以上，才认为回声真的漏进来了。 */
            const val LEAK_THRESHOLD = 10.0
        }
    }

    /**
     * 录一小段，返回 RMS（dBFS）。
     *
     * [source] 决定用哪一路；[withAec] 为 true 时挂上 AEC。
     * 给诊断页的"AEC 对比测试"用：同一句话，开 AEC 录一次、关 AEC 录一次，
     * 差值就是 AEC 实际削掉了多少。
     */
    @android.annotation.SuppressLint("MissingPermission")
    fun probeLevel(source: Int, withAec: Boolean, ms: Int): Double {
        val min = AudioRecord.getMinBufferSize(
            VoiceprintRecorder.RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (min <= 0) return -999.0
        val r = runCatching {
            AudioRecord(
                source,
                VoiceprintRecorder.RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, VoiceprintRecorder.RATE / 5 * 2),
            )
        }.getOrNull() ?: return -999.0
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return -999.0
        }
        val effects = ArrayList<AudioEffect>()
        if (withAec) {
            runCatching { AcousticEchoCanceler.create(r.audioSessionId) }.getOrNull()?.let { e ->
                effects += e
                runCatching { e.enabled = true }
            }
        }
        if (runCatching { r.startRecording() }.isFailure) {
            effects.forEach { runCatching { it.release() } }
            r.release()
            return -999.0
        }
        // 丢掉开头一段。
        //
        // AudioRecord 刚 startRecording 之后，硬件还没 warm up，前 200~400ms
        // 常常整段返回 0。之前把这些 0 也算进去，结果是 -128 dBFS——那不是
        // "声音很小"，是纯数字静默（16bit 能表示的下限约 -96dB，多帧平均
        // 能压到 -128）。据此算出的"AEC 削了 35dB"是假的。
        val warmup = VoiceprintRecorder.RATE * 450 / 1000
        val buf = ShortArray(1600)
        var skipped = 0
        while (skipped < warmup) {
            val n = runCatching { r.read(buf, 0, buf.size) }.getOrDefault(-1)
            if (n <= 0) break
            skipped += n
        }

        val frames = VoiceprintRecorder.RATE * ms / 1000
        var sum = 0.0
        var count = 0
        var silent = 0
        val deadline = System.currentTimeMillis() + ms + 800
        while (count < frames && System.currentTimeMillis() < deadline) {
            val n = runCatching { r.read(buf, 0, buf.size) }.getOrDefault(-1)
            if (n <= 0) break
            for (i in 0 until n) {
                val s = buf[i]
                if (s == 0.toShort()) silent++
                val v = s / 32768.0
                sum += v * v
                count++
            }
        }
        runCatching { r.stop() }
        runCatching { r.release() }
        effects.forEach { runCatching { it.release() } }
        if (count == 0) return -998.0
        // 超过 90% 的采样是 0，说明这一路根本没在采（而不是安静）。
        // 报 -997 区分开，别让界面把它当成"回声很小"。
        if (silent.toDouble() / count > 0.9) return -997.0
        val rms = sqrt(sum / count)
        return 20 * log10(maxOf(rms, 1e-12))
    }

    /**
     * 回声残留的量测结果。
     *
     * 为什么必须"边放边测"：AEC 的工作方式是用**正在播放的音频**作参考信号，
     * 在麦克风里找到并减掉它。不播放时它没有参考可减，效果就是一个恒等变换
     * ——测出来的差值是底噪波动，跟回声消除毫无关系。
     *
     * 所以这里比的是：
     *   [playingDb]  正在播放时的电平（含回声残留）
     *   [silentDb]   停止播放后的电平（纯底噪）
     * 差值就是漏进来的回声。差得越多，AEC 越没用。
     */
    data class EchoResult(
        /** 播放时录到的 RMS（dBFS）。 */
        val playingDb: Double,
        /** 不播放时录到的 RMS（dBFS）。 */
        val silentDb: Double,
        /** 有没有真的挂上 AEC。 */
        val aecOn: Boolean,
        /** 用的哪个音源。 */
        val source: String,
    ) {
        /** 回声漏进来多少 dB。负数说明播放时反而更安静（基本不可能，多半是没采到）。 */
        val leak: Double get() = playingDb - silentDb

        /** 这个结果能不能拿来做判断。 */
        val usable: Boolean
            get() = playingDb > -900 && silentDb > -900

        /**
         * 结论。
         *
         * 门槛按经验定：AEC 正常工作时，外放的回声会被压到底噪以下或与之相当，
         * 差值通常在 10 dB 内；完全没消的话，外放的回声会比底噪高 25 dB 以上。
         */
        val verdict: String
            get() = when {
                !usable -> "没测出来"
                leak < LEAK_OK -> "回声基本没漏（高 ${"%.1f".format(leak)} dB）"
                leak < LEAK_BAD -> "漏了一点（高 ${"%.1f".format(leak)} dB）"
                else -> "回声漏得厉害（高 ${"%.1f".format(leak)} dB）"
            }

        val good: Boolean get() = usable && leak < LEAK_OK
    }

    /** 播放不高于底噪 10 dB：认为消干净了。 */
    const val LEAK_OK = 10.0

    /** 播放高于底噪 22 dB：等于没消。 */
    const val LEAK_BAD = 22.0

    /**
     * 量一次回声：播放一段音，同时录；再静默录一段作对照。
     *
     * [tone] 一个可播的函数，接管"放一段已知声音"，返回后播放已停止。
     * 用回调而不是在这里播，是因为播放器在主线程那边，Dart 侧已经有现成的
     * 播放通道（CompanionVoice），没必要再养一个。
     *
     * 两段录音用**同一个音源**、同一个 session 配置，唯一的变量是"放没放声音"。
     */
    @android.annotation.SuppressLint("MissingPermission")
    fun measureEcho(
        source: Int,
        withAec: Boolean,
        ms: Int,
        play: () -> Unit,
        stopPlay: () -> Unit,
    ): EchoResult {
        if (!probing.compareAndSet(false, true)) {
            return EchoResult(-998.0, -998.0, false, sourceName(source))
        }
        return try {
            val rec = open(source, withAec) ?: return EchoResult(-998.0, -998.0, false, sourceName(source))
            val aecOk = rec.aecOn
            try {
                // 先静默录一小段，作为底噪。
                val silent = recordRms(rec.record, ms)

                // 再边放边录。播放留 300ms 让它真的响起来（MediaPlayer 从 play()
                // 到出声有一段准备时间），这段时间的样本不算进结果。
                play()
                Thread.sleep(350)
                val playing = recordRms(rec.record, ms)
                stopPlay()
                Thread.sleep(200)

                EchoResult(
                    playingDb = playing,
                    silentDb = silent,
                    aecOn = aecOk,
                    source = sourceName(source),
                )
            } finally {
                rec.close()
            }
        } finally {
            probing.set(false)
        }
    }

    private class OpenRec(val record: AudioRecord, val effects: List<AudioEffect>, val aecOn: Boolean) {
        fun close() {
            runCatching { record.stop() }
            runCatching { record.release() }
            effects.forEach { runCatching { it.release() } }
        }
    }

    @android.annotation.SuppressLint("MissingPermission")
    private fun open(source: Int, withAec: Boolean): OpenRec? {
        val min = AudioRecord.getMinBufferSize(
            VoiceprintRecorder.RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (min <= 0) return null
        val r = runCatching {
            AudioRecord(
                source,
                VoiceprintRecorder.RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, VoiceprintRecorder.RATE / 5 * 2),
            )
        }.getOrNull() ?: return null
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return null
        }
        val effects = ArrayList<AudioEffect>()
        var aecOn = false
        if (withAec) {
            runCatching { AcousticEchoCanceler.create(r.audioSessionId) }.getOrNull()?.let { e ->
                effects += e
                aecOn = runCatching { e.enabled = true; e.enabled }.getOrDefault(false)
            }
        }
        if (runCatching { r.startRecording() }.isFailure) {
            effects.forEach { runCatching { it.release() } }
            r.release()
            return null
        }
        // 硬件 warm up：前 400ms 常常整段是 0，不能算进去。
        val buf = ShortArray(1600)
        var skipped = 0
        val warm = VoiceprintRecorder.RATE * 400 / 1000
        while (skipped < warm) {
            val n = runCatching { r.read(buf, 0, buf.size) }.getOrDefault(-1)
            if (n <= 0) break
            skipped += n
        }
        return OpenRec(r, effects, aecOn)
    }

    /** 从已经开着的 record 读 [ms] 毫秒，返回 RMS（dBFS）。 */
    private fun recordRms(r: AudioRecord, ms: Int): Double {
        val frames = VoiceprintRecorder.RATE * ms / 1000
        val buf = ShortArray(1600)
        var sum = 0.0
        var count = 0
        var silent = 0
        val deadline = System.currentTimeMillis() + ms + 800
        while (count < frames && System.currentTimeMillis() < deadline) {
            val n = runCatching { r.read(buf, 0, buf.size) }.getOrDefault(-1)
            if (n <= 0) break
            for (i in 0 until n) {
                val v = buf[i]
                if (v == 0.toShort()) silent++
                val f = v / 32768.0
                sum += f * f
                count++
            }
        }
        if (count == 0) return -998.0
        // 超过 95% 是 0：这一路根本没在采，报个特殊值，别当成"很安静"。
        if (silent.toDouble() / count > 0.95) return -997.0
        return 20 * log10(maxOf(sqrt(sum / count), 1e-12))
    }

    private val probing = AtomicBoolean(false)

    /** 给 Dart 的 map：字段名同为 wire 风格。 */
    fun Report.toMap(): Map<String, Any?> = mapOf(
        "available" to available,
        "created" to created,
        "enabledCallOk" to enabledCallOk,
        "enabledConfirmed" to enabledConfirmed,
        "nsAvailable" to nsAvailable,
        "nsCreated" to nsCreated,
        "nsEnabledConfirmed" to nsEnabledConfirmed,
        "source" to source,
        "sourceHasHalAec" to sourceHasHalAec,
        "effective" to effective,
        "note" to note,
        "summary" to summary,
        "sdk" to Build.VERSION.SDK_INT,
    )
}
