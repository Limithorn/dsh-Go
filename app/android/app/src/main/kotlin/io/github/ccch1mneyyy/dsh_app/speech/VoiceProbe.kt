package io.github.ccch1mneyyy.dsh_app.speech

import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.voice.StreamingPcm
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 语音链路取证：把通话的采集流、播放流和判决事件写到同一条时间轴上。
 *
 * 为什么要单独做：现有的落盘都是局部的（实景测试留 6 段 wav、声纹留
 * voiceprint-clips、SpeakerGate 留 dump 窗口），彼此没有共同时钟。排查
 * "AI 说到一半自己停了"这种问题，必须能把"那一刻播放了什么 / 麦克风收到
 * 了什么 / gate 判了什么"三件事对齐——所以这里用同一个单调时钟给三者打点。
 *
 * 两路 PCM 都是裸 16-bit LE mono，采样率写在 meta.json 里（call 恒 16k；
 * play 是 TTS 流的原始采样率，通常 24k），用 ffmpeg 可以直接拼听：
 *   ffmpeg -f s16le -ar 16000 -ac 1 -i call.pcm \
 *          -f s16le -ar 24000 -ac 1 -i play.pcm -filter_complex amix=inputs=2 out.wav
 *
 * 默认关闭：只有诊断页按了「开始取证」才写文件，日常使用零开销。
 * 上限 60 MB 或 10 分钟，到了就不再写 PCM（事件继续记），避免夜间测试
 * 把手机存储写满。
 */
internal object VoiceProbe {
    private const val TAG = "DshProbe"
    private const val CALL_RATE = 16_000
    private const val MAX_BYTES = 60L * 1024 * 1024
    private const val MAX_MS = 600_000L

    @Volatile var active = false
        private set

    private var dir: File? = null
    private var callOut: BufferedOutputStream? = null
    private var playOut: BufferedOutputStream? = null
    private var eventsOut: BufferedOutputStream? = null
    private var meta = JSONObject()
    private var t0 = 0.0
    private var tapId = 0L
    private var callBytes = 0L
    private var playBytes = 0L
    private var playRate = 0
    private var full = false

    private fun nowMs(): Double = SystemClock.elapsedRealtimeNanos() / 1_000_000.0

    /** 单调时钟，毫秒，相对本次取证开始。事件和 PCM 文件共用它。 */
    private fun t(): Double = nowMs() - t0

    @Synchronized
    fun start(root: File): Map<String, Any?> {
        if (active) return status()
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val session = File(root, stamp)
        runCatching { session.mkdirs() }
        t0 = nowMs()
        full = false
        callBytes = 0
        playBytes = 0
        playRate = 0
        meta = JSONObject()
        meta.put("playbackUsage", "USAGE_MEDIA")
        meta.put("aec", "software")
        meta.put("sdk", Build.VERSION.SDK_INT)
        meta.put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
        meta.put("startedAt", System.currentTimeMillis())
        meta.put("callRate", CALL_RATE)
        meta.put("callEncoding", "pcm_s16le_mono")
        meta.put("playEncoding", "pcm_s16le_mono")
        dir = session
        runCatching {
            callOut = BufferedOutputStream(FileOutputStream(File(session, "call.pcm")))
            playOut = BufferedOutputStream(FileOutputStream(File(session, "play.pcm")))
            eventsOut = BufferedOutputStream(FileOutputStream(File(session, "events.jsonl")))
        }.onFailure { e ->
            Log.w(TAG, "start failed", e)
            closeFiles()
            dir = null
            return mapOf("error" to (e.message ?: "cannot open probe files"))
        }
        active = true
        tapId = System.nanoTime()
        StreamingPcm.enable("call", tapId) { _, bytes, valid ->
            if (valid()) callFrame(bytes)
        }
        event("probeStart", mapOf("dir" to session.absolutePath))
        return status()
    }

    @Synchronized
    fun stop(): Map<String, Any?> {
        if (!active) return status()
        event("probeStop", mapOf("callBytes" to callBytes, "playBytes" to playBytes, "full" to full))
        StreamingPcm.disable(tapId)
        tapId = 0
        active = false
        val out = status()
        closeFiles()
        dir = null
        Log.i(TAG, "STOP ${out["dir"]} call=$callBytes play=$playBytes")
        return out
    }

    @Synchronized
    fun status(): Map<String, Any?> = mapOf(
        "active" to active,
        "playbackUsage" to "USAGE_MEDIA",
        "aec" to "software",
        "dir" to (dir?.absolutePath ?: ""),
        "callRate" to CALL_RATE,
        "playRate" to playRate,
        "callBytes" to callBytes,
        "playBytes" to playBytes,
        "full" to full,
    )

    /** AEC 报告这类嵌套值要转成 JSON，不然 meta.json 里只剩 Map 的 toString。 */
    private fun jsonValue(v: Any?): Any? = when (v) {
        is Map<*, *> -> JSONObject().apply {
            for ((k, item) in v) runCatching { put(k.toString(), jsonValue(item)) }
        }
        is Iterable<*> -> JSONArray(v.map { jsonValue(it) })
        is Array<*> -> JSONArray(v.map { jsonValue(it) })
        else -> v
    }

    /** 把本次采集的关键配置写进 meta.json，事件流里也留一份。 */
    fun configure(fields: Map<String, Any?>) {
        for ((k, v) in fields) runCatching { meta.put(k, jsonValue(v)) }
        event("configure", fields)
    }

    /** 结构化事件。同一行既落 events.jsonl，也进 logcat，方便 adb 实时看。 */
    @Synchronized
    fun event(type: String, fields: Map<String, Any?> = emptyMap()) {
        val line = JSONObject().apply {
            put("t", Math.round(t() * 1000) / 1000.0)
            put("type", type)
            for ((k, v) in fields) runCatching { put(k, jsonValue(v)) }
        }.toString()
        Log.i(TAG, line)
        if (!active) return
        runCatching {
            eventsOut?.write((line + "\n").toByteArray(Charsets.UTF_8))
            eventsOut?.flush()
        }
        checkLimit()
    }

    /** 通话采集帧（16 kHz mono PCM16，已过固定增益）。由 StreamingPcm tap 调用。 */
    @Synchronized
    internal fun callFrame(bytes: ByteArray) {
        if (!active || full) return
        runCatching {
            callOut?.write(bytes)
            callBytes += bytes.size
        }
        checkLimit()
    }

    /** 播放帧（TTS 原始采样率，mono PCM16）。由 PcmStream.write 旁路调用。 */
    @Synchronized
    internal fun playFrame(rate: Int, bytes: ByteArray) {
        if (!active || full || bytes.isEmpty()) return
        if (playRate == 0) {
            playRate = rate
            runCatching { meta.put("playRate", rate) }
            event("playRate", mapOf("rate" to rate))
        } else if (playRate != rate) {
            event("playRateChange", mapOf("from" to playRate, "to" to rate))
            playRate = rate
            runCatching { meta.put("playRate", rate) }
        }
        runCatching {
            playOut?.write(bytes)
            playBytes += bytes.size
        }
        checkLimit()
    }

    private fun checkLimit() {
        if (full || !active) return
        if (t() > MAX_MS || callBytes + playBytes > MAX_BYTES) {
            full = true
            Log.w(TAG, "limit reached, PCM writing paused (events continue)")
        }
    }

    private fun closeFiles() {
        for (out in listOf(callOut, playOut, eventsOut)) {
            runCatching { out?.flush(); out?.close() }
        }
        callOut = null
        playOut = null
        eventsOut = null
        runCatching {
            dir?.let { File(it, "meta.json").writeText(meta.toString(2)) }
        }
    }
}
