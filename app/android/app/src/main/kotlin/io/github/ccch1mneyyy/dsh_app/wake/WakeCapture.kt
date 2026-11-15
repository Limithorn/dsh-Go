package io.github.ccch1mneyyy.dsh_app.wake

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.util.Log

/**
 * 唤醒用的麦克风采集：16 kHz 单声道，一直读到被叫停为止。
 *
 * 跟通话那套（CallCapture）的区别是它不判停、不切句，只把连续的 PCM 一小段一小段
 * 交给上层；判断有没有叫到名字是 Dart 侧 sherpa 的事。缓冲区故意做大（[CHUNK] 一
 * 段约 320 ms），跨进程推一次大约 10 KB，一秒三次，够用也不吵。
 */
class WakeCapture(
    private val main: Handler,
    private val onChunk: (ShortArray) -> Unit,
    private val onError: (String) -> Unit,
) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    @Volatile private var running = false

    val active get() = record != null

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (record != null) return true
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) {
            onError("mic_unavailable")
            return false
        }
        val size = maxOf(min * 2, CHUNK * 2 * 4)
        val r = runCatching {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                size,
            )
        }.getOrNull()
        if (r == null || r.state != AudioRecord.STATE_INITIALIZED) {
            runCatching { r?.release() }
            onError("mic_unavailable")
            return false
        }
        val started = runCatching { r.startRecording() }.isSuccess &&
            r.recordingState == AudioRecord.RECORDSTATE_RECORDING
        if (!started) {
            runCatching { r.release() }
            onError("mic_busy")
            return false
        }
        record = r
        running = true
        thread = Thread({ capture(r) }, "dsh-wake").also {
            it.isDaemon = true
            it.start()
        }
        return true
    }

    private fun capture(r: AudioRecord) {
        val buf = ShortArray(CHUNK)
        while (running) {
            val n = r.read(buf, 0, buf.size)
            if (n <= 0) {
                if (n == AudioRecord.ERROR_INVALID_OPERATION || n == AudioRecord.ERROR_DEAD_OBJECT) break
                continue
            }
            if (n == buf.size) {
                main.post { onChunk(buf.copyOf()) }
            } else {
                main.post { onChunk(buf.copyOf(n)) }
            }
        }
        Log.d("DshWake", "capture ended")
    }

    fun stop() {
        running = false
        val r = record ?: return
        record = null
        runCatching { r.stop() }
        runCatching { r.release() }
        thread?.join(800)
        thread = null
    }

    companion object {
        const val RATE = 16000

        /** 320 ms 一段，一秒三推。 */
        private const val CHUNK = RATE * 320 / 1000
    }
}
