package io.github.ccch1mneyyy.dsh_app.speech

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.SystemClock
import io.github.ccch1mneyyy.dsh_app.voice.StreamingPcm
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGate
import io.github.ccch1mneyyy.dsh_app.nativemedia.TurnGate
import io.github.ccch1mneyyy.dsh_app.nativemedia.TurnPause
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The microphone during a voice call: 16 kHz mono from the voice-communication source with the
 * platform's echo canceller and noise suppressor when the phone has them, cut into utterances by a
 * [SpeechGate]. Each utterance (with the 300 ms before speech was detected, so the first syllable is
 * kept) is handed over as a WAV once the person pauses; nothing else is kept, and nothing at all is
 * recorded while muted.
 *
 * While the app's own voice plays ([setPlaying]) the gate is stricter. With [bargeIn] the person
 * speaking over it starts an utterance (the owner stops the playback); without it, speech during
 * playback is ignored.
 */
class CallCapture(
    private val main: Handler,
    private val listener: Listener,
    private val createGate: (Boolean) -> TurnGate = { SpeechGate(it) },
) {
    interface Listener {
        fun onSpeechStart(overPlayback: Boolean)
        fun onUtterance(wav: ByteArray, ms: Int)
        fun onLevel(value: Double)
        fun onError(reason: String)
    }

    private var record: AudioRecord? = null
    private var effects = mutableListOf<AudioEffect>()
    private var thread: Thread? = null
    private var gate: TurnGate? = null

    /** 通话进行中改门槛（声纹人数变了要重算），不动正在读的音频。 */
    internal fun currentGate(): TurnGate? = gate

    @Volatile private var running = false
    @Volatile private var playing = false
    @Volatile private var pcmEpoch = 0
    @Volatile var muted = false
        set(value) {
            if (field != value) pcmEpoch++
            field = value
        }
    @Volatile var bargeIn = true

    /**
     * 播放态插话门槛偏移档位（0=标准，正=更迟钝/更不易自打断，负=更灵敏）。
     * 改动即时作用到当前 gate；gate 为能量门/神经门时换算略有不同，统一用 dB 档位。
     */
    @Volatile var bargeOffset: Float = 0f
        set(value) {
            field = value
            val g = gate ?: return
            synchronized(g) { g.bargeOffset = value }
        }

    /** How long a pause ends what the person says; a change applies from the next frame. */
    @Volatile var pause = TurnPause.NORMAL
        set(value) {
            field = value
            val g = gate ?: return
            synchronized(g) { g.pause = value }
        }
    private var session = 0

    /** The platform echo canceller is on for this capture. */
    var echoCancelled = false
        private set

    /** 这次采集的 AEC 详情，给诊断页看。 */
    @Volatile internal var lastAec: AecSupport.Report? = null
        private set

    /**
     * 用不用自己写的 AEC。默认跟随全局开关；SpeechPlugin 在 callStart 时
     * 按设置显式赋值。开启时不挂系统 AudioEffect，采集源也切成不带 HAL AEC
     * 的那一类，避免两套消除器同时改同一路信号。
     */
    @Volatile var softwareAec: Boolean = SoftwareAec.enabled

    /** 这一通是否真的走了软件 AEC（诊断和取证都记它）。 */
    @Volatile internal var softwareAecActive: Boolean = false
        private set

    /**
     * 通话采集用哪个音源。
     *
     * 默认 VOICE_COMMUNICATION：带 AEC，自己的播放声不会漏回来。
     * 但有些机器（实测 Sony Xperia）在这条路上降噪过狠，说话峰值只有
     * −74 dBFS，而同一个麦克风走 VOICE_RECOGNITION 是 −20.8——差 53 dB。
     * 那种情况下宁可不要 AEC 也得能听见人说话。
     *
     * 由 [SpeechPlugin] 用 [MicSource.resolve] 定好再传进来：和实景测试同一套
     * 判据、同一个设置入口。这里只是执行，不做选择。
     */
    @Volatile var preferredSource: Int = MediaRecorder.AudioSource.VOICE_COMMUNICATION

    /** 这次真正打开的音源（0 = 没在采）；诊断页拿它和设置里的档位对照。 */
    @Volatile var openedSource: Int = 0
        private set

    val active get() = record != null

    @SuppressLint("MissingPermission") // SpeechPlugin checks RECORD_AUDIO first.
    fun start(): Boolean {
        stop()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val r = runCatching {
            AudioRecord(
                preferredSource,
                RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, RATE / 5 * 2),
            )
        }.getOrNull() ?: return false
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return false
        }
        // 软件 AEC 接管时不挂系统效果器：VOICE_COMMUNICATION 的 HAL AEC
        // 是音源自带的，关不掉；再由它先削一遍、我们拿残差去减参考，等于
        // 两个滤波器学同一条通路，近端人声会被一起吃掉。
        val useSoftware = softwareAec && SoftwareAec.enabled
        val report = if (useSoftware) AecSupport.software(preferredSource) else AecSupport.attach(r, effects)
        // gate 只关心"回声还应不应该当成插话"，软件 AEC 和 HAL AEC 都算已处理。
        echoCancelled = report.effective || useSoftware
        lastAec = report
        softwareAecActive = useSoftware
        if (useSoftware) SoftwareAec.begin()
        val g = createGate(echoCancelled).also { it.pause = pause; it.bargeOffset = bargeOffset }
        val started = runCatching { r.startRecording() }.isSuccess && r.recordingState == AudioRecord.RECORDSTATE_RECORDING
        if (!started) {
            g.close()
            if (useSoftware) SoftwareAec.end()
            softwareAecActive = false
            releaseEffects()
            r.release()
            return false
        }
        record = r
        gate = g
        openedSource = runCatching { r.audioSource }.getOrDefault(preferredSource)
        if (playing) g.setPlaying(true, SystemClock.elapsedRealtime())
        running = true
        val mine = ++session
        thread = Thread({ capture(r, g, mine) }, "dsh-speech-call").also { it.start() }
        return true
    }

    /** The app's own voice started or stopped playing. */
    fun setPlaying(on: Boolean) {
        playing = on
        val g = gate ?: return
        synchronized(g) { g.setPlaying(on, SystemClock.elapsedRealtime()) }
    }

    private fun capture(r: AudioRecord, g: TurnGate, mine: Int) {
        val frame = ShortArray((RATE * SpeechGate.FRAME_MS / 1000).toInt())
        val preroll = ArrayDeque<ShortArray>()
        var utterance: ByteArrayOutputStream? = null
        var utteranceFrames = 0
        var filled = 0
        var pcmTap: StreamingPcm.Tap? = null
        var frameEpoch = 0
        var tick = 0
        try {
            while (running) {
                if (filled == 0) {
                    pcmTap = StreamingPcm.current("call")
                    frameEpoch = pcmEpoch
                }
                val n = r.read(frame, filled, frame.size - filled)
                if (!running) break
                if (n < 0) {
                    post(mine) { listener.onError("capture") }
                    break
                }
                filled += n
                if (filled < frame.size) continue
                filled = 0
                if (muted) {
                    // Nothing heard, nothing kept: an utterance under way is dropped.
                    synchronized(g) { g.reset() }
                    utterance = null
                    preroll.clear()
                    frame.fill(0)
                    if (++tick % 2 == 0) post(mine) { listener.onLevel(0.0) }
                    continue
                }
                // 软件 AEC 必须在增益/电平/闸门之前：参考是播放侧的原始 PCM，
                // 采集这端也得保持原始量纲，减完再一起放大才不会把回声比例搞乱。
                // 取证 tap 和 utterance 因此在下游，录到的是消完回声的音频。
                if (softwareAecActive) SoftwareAec.processCapture(frame)
                // 固定增益：在算电平和判定之前放大。
                //
                // 必须放在最前面——levelOf 算出的电平、gate.consume 拿到的
                // 波形、以及 utterance 存下的音频都得是放大后的，否则三处
                // 看到的不是同一段信号。放大的只是幅度，段内的人声/回声/
                // 底噪比例原样保留（这一点和归一化不同，归一化会把回声拉满）。
                Voiceprint.applyGain(frame, frame.size)
                val level = SpeechGate.levelOf(frame, frame.size)
                pcmTap?.let { tap ->
                    val epoch = frameEpoch
                    StreamingPcm.offer(tap, frame) { running && mine == session && !muted && epoch == pcmEpoch }
                }
                if (++tick % 2 == 0) {
                    val shown = ((level + 60.0) / 50.0).coerceIn(0.0, 1.0)
                    post(mine) { listener.onLevel(shown) }
                }
                val overPlayback = playing
                val edge = synchronized(g) { g.consume(frame, level, SystemClock.elapsedRealtime()) }
                val current = utterance
                when {
                    edge == SpeechGate.Edge.START && (!overPlayback || bargeIn) -> {
                        val out = ByteArrayOutputStream(RATE * 2 * 4)
                        for (old in preroll) append(out, old)
                        append(out, frame)
                        utterance = out
                        utteranceFrames = preroll.size + 1
                        post(mine) { listener.onSpeechStart(overPlayback) }
                    }
                    current != null -> {
                        append(current, frame)
                        utteranceFrames++
                        if (edge == SpeechGate.Edge.END || utteranceFrames * SpeechGate.FRAME_MS >= MAX_MS) {
                            if (edge != SpeechGate.Edge.END) synchronized(g) { g.reset() }
                            utterance = null
                            val ms = (utteranceFrames * SpeechGate.FRAME_MS).toInt()
                            val wav = wav(current.toByteArray())
                            post(mine) { listener.onUtterance(wav, ms) }
                        }
                    }
                }
                preroll.addLast(frame.copyOf())
                while (preroll.size > PREROLL_FRAMES) preroll.removeFirst()
            }
        } catch (_: Exception) {
            post(mine) { listener.onError("capture") }
        } finally {
            synchronized(g) { g.close() }
            frame.fill(0)
            preroll.clear()
        }
    }

    private fun append(out: ByteArrayOutputStream, samples: ShortArray) {
        val buffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) buffer.putShort(s)
        out.write(buffer.array())
    }

    private fun post(mine: Int, block: () -> Unit) {
        main.post { if (mine == session && running) block() }
    }

    /** Ends the capture: the thread leaves its read, the recorder and effects are released. */
    fun stop() {
        session++
        running = false
        openedSource = 0
        if (softwareAecActive) SoftwareAec.end()
        softwareAecActive = false
        val r = record ?: return
        record = null
        gate = null
        runCatching { r.stop() }
        val t = thread
        thread = null
        runCatching { t?.join(JOIN_MS) }
        releaseEffects()
        runCatching { r.release() }
    }

    private fun releaseEffects() {
        for (effect in effects) runCatching { effect.release() }
        effects = mutableListOf()
    }

    companion object {
        const val RATE = 16000
        const val JOIN_MS = 300L
        const val PREROLL_FRAMES = 15 // 300 ms
        // DeepSeek's recognizer takes at most 120 s; an utterance is cut well before.
        const val MAX_MS = 110_000L

        fun wav(pcm: ByteArray): ByteArray {
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
            header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2)
                .putShort(2).putShort(16)
            header.put("data".toByteArray()).putInt(pcm.size)
            return header.array() + pcm
        }
    }
}
