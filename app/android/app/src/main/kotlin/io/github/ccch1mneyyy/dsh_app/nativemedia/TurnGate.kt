package io.github.ccch1mneyyy.dsh_app.nativemedia

/** A capture owns a gate and serializes calls; edges are emitted only by [consume]. */
interface TurnGate : AutoCloseable {
    fun consume(frame: ShortArray, levelDb: Double, nowMs: Long): SpeechGate.Edge
    fun setPlaying(on: Boolean, nowMs: Long)

    /** How long a pause ends the turn; may change between frames. */
    var pause: TurnPause

    /**
     * 播放态插话门槛的档位偏移（0=标准，负=灵敏更容易打断，正=迟钝更不易自打断）。
     * 只影响「AI 正在说话」时的判定，不碰用户说话时的端点检测。可在通话中改。
     */
    var bargeOffset: Float

    fun reset() {}
    override fun close() {}
}
