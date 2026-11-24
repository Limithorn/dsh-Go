package io.github.ccch1mneyyy.dsh_app.speech

import android.media.MediaRecorder
import android.util.Log

/**
 * 采集音源：一处决定，通话和实景测试共用同一个结论。
 *
 * 为什么要有这一层：实景测试原来把音源钉死在 `VOICE_COMMUNICATION`（页面上另有
 * 一套 comm/recog/mic 三段开关），通话走的却是设置里的「通话收音」——auto 时会
 * 按实测电平换成 `VOICE_RECOGNITION`。同一台机器上两条路径收的不是同一路声音，
 * 分数自然不可比：实测 Sony 上 VC 是 −74.1 dBFS、VR 是 −20.8，差 53 dB。
 *
 * 现在两边都从 [resolve] 取音源：设置里的「通话收音」（auto / communication /
 * recognition）是唯一入口，[Pick] 原样记下"量到了什么、最后选了哪一路"，诊断页
 * 按 [lastCall] / [lastScreenTest] 显示，谁也不用再猜。
 *
 * auto 的判据沿用原来那条：识别那一路的峰值比通话那一路高 [SWAP_DB] 以上才换。
 * 这是"哪一路还能听见人"的判据，和 Thresholds.kt 里声纹的门槛无关，别混。
 */
internal object MicSource {
    private const val TAG = "MicSource"

    const val AUTO = "auto"
    const val COMMUNICATION = "communication"
    const val RECOGNITION = "recognition"
    const val MIC = "mic"

    /** 自动换路的判据：识别那一路比通话那一路高多少 dB，才值得放弃 AEC。 */
    const val SWAP_DB = 20.0

    /**
     * 探测打不开时的占位值（见 [VoiceprintRecorder.probeSources]）。
     * −900 上下都不是真实电平，不能拿去比大小。
     */
    private const val FAILED = -900.0

    /** 一次音源决定，以及做出这个决定所依据的实测值。 */
    data class Pick(
        /** 哪条路径留下的：call / screenTest / probe。 */
        val where: String,
        /** 设置里要的那一档（auto / communication / recognition / mic）。 */
        val requested: String,
        /** 最终打开的音源名，和 [android.media.AudioRecord.audioSource] 对得上。 */
        val chosen: String,
        val source: Int,
        /** 判定依据的实测峰值（dBFS，按音源名）；手动指定的档位不量，这里为空。 */
        val peaks: Map<String, Double>,
        /** 识别减通话，dB；没量就是 null。 */
        val deltaDb: Double?,
        /** 一句话说明为什么选了它。 */
        val reason: String,
        val at: Long,
    ) {
        /** auto 真的把通话那一路换掉了。 */
        val swapped: Boolean
            get() = requested == MicSource.AUTO && source == MediaRecorder.AudioSource.VOICE_RECOGNITION
    }

    /** 最近一次通话选的音源。 */
    @Volatile var lastCall: Pick? = null
        private set

    /** 最近一次实景测试选的音源。和 [lastCall] 同一套判据，两者应当一致。 */
    @Volatile var lastScreenTest: Pick? = null
        private set

    /** 诊断页手动量的那一次，不参与实际采集。 */
    @Volatile var lastProbe: Pick? = null
        private set

    /** MethodChannel 上的旧写法（"comm" / "recog"）一并认，认不出的一律 auto。 */
    fun of(wire: String?): String = when (wire?.trim()?.lowercase()) {
        COMMUNICATION, "comm" -> COMMUNICATION
        RECOGNITION, "recog" -> RECOGNITION
        MIC -> MIC
        else -> AUTO
    }

    fun sourceOf(wire: String): Int = when (of(wire)) {
        RECOGNITION -> MediaRecorder.AudioSource.VOICE_RECOGNITION
        MIC -> MediaRecorder.AudioSource.MIC
        else -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
    }

    /**
     * 定下这条路径该用哪一路。
     *
     * auto 会真的把三条音源各开 1.5 秒量峰值（约 4.5 秒），**别在主线程叫它**：
     * 实景测试的入口就是放到工作线程量完再 start 的。手动指定的档位不量。
     */
    fun resolve(requested: String?, where: String): Pick {
        val want = of(requested)
        if (want != AUTO) {
            val source = sourceOf(want)
            return remember(
                Pick(where, want, AecSupport.sourceName(source), source, emptyMap(), null, "设置指定，没有量电平", System.currentTimeMillis()),
            )
        }
        return remember(decide(where, want, probePeaks()))
    }

    /**
     * 软件 AEC 专用：钉死在识别音源。
     *
     * VOICE_COMMUNICATION 的 AEC/NS 在 HAL 里，应用关不掉；软件 AEC 若还从
     * 这条路采，就是在已经被削过一遍的信号上再减一次参考，近端人声会被
     * 一起吃掉。VOICE_RECOGNITION 按要求不做过度处理，正好是我们要的原始
     * 采集；Xperia 实测它也比 VC 高 53 dB，不是"牺牲电平换 AEC"。
     */
    fun software(where: String): Pick {
        val source = MediaRecorder.AudioSource.VOICE_RECOGNITION
        return remember(
            Pick(
                where,
                RECOGNITION,
                AecSupport.sourceName(source),
                source,
                emptyMap(),
                null,
                "自建 AEC 需要不带 HAL AEC 的原始采集，固定识别音源",
                System.currentTimeMillis(),
            ),
        )
    }

    /** 只量不选：诊断页的「量一遍音源」用。 */
    fun probe(): Pick = remember(decide("probe", AUTO, probePeaks()))

    private fun probePeaks(): Map<String, Double> =
        runCatching { VoiceprintRecorder.probeSources() }.getOrDefault(emptyMap())

    private fun decide(where: String, requested: String, peaks: Map<String, Double>): Pick {
        val vc = peaks["VOICE_COMMUNICATION"]
        val vr = peaks["VOICE_RECOGNITION"]
        val now = System.currentTimeMillis()
        fun pick(source: Int, delta: Double?, reason: String) =
            Pick(where, requested, AecSupport.sourceName(source), source, peaks, delta, reason, now)

        if (vc == null || vr == null) {
            return pick(MediaRecorder.AudioSource.VOICE_COMMUNICATION, null, "量不到通话/识别两路，按通话音源走")
        }
        if (vc <= FAILED || vr <= FAILED) {
            return pick(MediaRecorder.AudioSource.VOICE_COMMUNICATION, null, "有一路打不开，按通话音源走")
        }
        val delta = vr - vc
        val useVr = delta > SWAP_DB
        val reason = if (useVr) {
            "识别比通话高 ${"%.1f".format(delta)} dB（> ${"%.0f".format(SWAP_DB)}）：换识别——通话那一路把人声吃掉了"
        } else {
            "识别只比通话高 ${"%.1f".format(delta)} dB（≤ ${"%.0f".format(SWAP_DB)}）：留通话——要它自带的 AEC"
        }
        val source = if (useVr) {
            MediaRecorder.AudioSource.VOICE_RECOGNITION
        } else {
            MediaRecorder.AudioSource.VOICE_COMMUNICATION
        }
        Log.i(TAG, "$where auto: vc=${"%.1f".format(vc)} vr=${"%.1f".format(vr)} -> ${AecSupport.sourceName(source)}")
        return pick(source, delta, reason)
    }

    private fun remember(p: Pick): Pick {
        when (p.where) {
            "call" -> lastCall = p
            "screenTest" -> lastScreenTest = p
            else -> lastProbe = p
        }
        return p
    }

    /** 给 MethodChannel 的形状；没量过的数值一律 null，别把占位值送出去。 */
    fun toMap(p: Pick?): Map<String, Any?>? = p?.let {
        mapOf(
            "where" to it.where,
            "requested" to it.requested,
            "chosen" to it.chosen,
            "swapped" to it.swapped,
            "vc" to it.peaks["VOICE_COMMUNICATION"]?.takeIf { v -> v.isFinite() },
            "vr" to it.peaks["VOICE_RECOGNITION"]?.takeIf { v -> v.isFinite() },
            "mic" to it.peaks["MIC"]?.takeIf { v -> v.isFinite() },
            "delta" to it.deltaDb,
            "reason" to it.reason,
            "at" to it.at,
        )
    }

    /** 诊断页要的一屏：两条路径各自最近一次决定，加上手量的那一次。 */
    fun report(): Map<String, Any?> = mapOf(
        "swapDb" to SWAP_DB,
        "call" to toMap(lastCall),
        "screen" to toMap(lastScreenTest),
        "probe" to toMap(lastProbe),
    )
}
