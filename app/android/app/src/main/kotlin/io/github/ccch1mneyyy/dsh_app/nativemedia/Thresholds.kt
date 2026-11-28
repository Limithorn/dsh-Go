package io.github.ccch1mneyyy.dsh_app.nativemedia

import kotlin.math.ceil
import kotlin.math.sqrt

/**
 * 白名单取 max 之后的门槛：人数一多，就要把单人的门槛往上提。
 *
 * 为什么必须提：N 个模板各比一次、取最大的那个，只要**任何一个人**误接受就成立，
 * 所以误接受概率约 1-(1-p)^N。想把整体压回 p，单人的误接受得压到 p/N。
 * 实务上不是给分数加固定偏移（分布不是均匀的），而是按 p/N 去查分位数——
 * 这里用的 [curve] 就是"分数 → 该分数对应的误接受率"的一张单调曲线，
 * 由 P0 实测分布拟合；没有实测数据时用默认的那条保守曲线。
 *
 * 人去人留要**重算**：5 人删到 1 人，门槛要回落，不能沿用 N=5 的严格值。
 */
object Thresholds {

    /** 一次通话里允许的误接受次数（外部先定目标，再反查分位数）。 */
    const val TARGET_PER_CALL = 0.5

    /** 假设一次通话里大概有多少段"外人开口"的候选，用来把 per-call 化成 per-trial。 */
    const val TRIALS_PER_CALL = 20.0

    /**
     * 哪一道闸在做判定。
     *
     * **为什么必须分开**：三处的音频质量差得远，同一个分数在三个场景里意味着
     * 不同的事。
     *
     *  - [BARGE]（插话）：AEC 开着，而且判定恰好发生在对方声音最大、AEC 最积极
     *    的时候。它分不清"我的话"和"对方的回声"（频谱重叠），连我的一起削。
     *    实测本人只有 0.45 上下，而干净录音能到 0.80——同一段代码，两种结果。
     *  - [WAKE]（唤醒）：没有播放，AEC 不工作，音频是干净的单人声。本人能到
     *    0.75 以上，可以要求得严。
     *  - [TURN]（对话）：也常和播放重叠，取两者之间。
     *
     * 用一套阈值同时管三处，只能照顾到最差的那个，把好的两处一起放松了。
     */
    enum class Gate {
        /** 插话：AEC 在工作，音频损失最大。 */
        BARGE,

        /** 唤醒：没有播放，音频干净。 */
        WAKE,

        /** 对话里的判定：介于两者之间。 */
        TURN,
    }

    /**
     * 三档：宽松 / 标准 / 严格。
     *
     * 值是在 **N=1** 时给的单模板门槛参考；N>1 时由 [forCount] 往上修。
     *
     * **这套数是从真机实测反推的，不是文献值。** 早先用的 0.65/0.72/0.80 来自
     * 干净录音下的经验区间，但通话里的音频完全不是那个样子：AEC 在播放期间
     * 削掉一部分人声（它分不清"你的声音"和"她的回声"，两者频谱重叠），
     * 于是一个人在诊断页能拿 0.80，到了通话只剩 0.45。三档全都在 0.45 之上，
     * 结果就是**谁都打断不了**——包括自己。
     *
     * 现在的标定：自己人通话里约 0.45（600ms 窗口）到 0.6（1500ms 窗口），
     * 旁人约 0.2–0.4。三档落在这个区间的上半段。
     */
    enum class Level(val base: Float) {
        LOOSE(0.40f),
        NORMAL(0.50f),
        STRICT(0.60f),

        /**
         * 最严：只认"非常像"的。
         *
         * 给多人共用一台机器、或者旁人声音和自己接近的场景。代价是本人说轻
         * 一点、隔得远一点就会被挡在外面——必须说得清楚。
         */
        VERY_STRICT(0.70f),
    }

    /** 不确定带宽：YOU 与 OTHER 之间留一条带子，落在里面的算 UNKNOWN（不切断）。 */
    const val BAND = 0.08f

    /**
     * N 个模板时的门槛。每加一个人往上提一点，提的幅度由"误接受随 N 增长"推出来：
     *
     *   accept(N) = accept(1) + k * ln(N)
     *
     * 取对数而不是线性，是因为 1-(1-p)^N 在 p 很小时近似 N*p，再换成分数空间就是
     * 对数关系。k 由 [PER_EXTRA] 定，保守取 0.045——5 人时比 1 人高约 0.072，
     * 与"每人把误接受压到 1/N"的量级相当。
     */
    fun accept(level: Level, count: Int, gate: Gate = Gate.BARGE, bias: Float = 0f): Float {
        val n = count.coerceAtLeast(1)
        return (baseFor(level, gate) + PER_EXTRA * ln(n) + bias).coerceIn(0.05f, 0.97f)
    }

    /**
     * 每道闸的基线。见 [Gate] 的说明。
     *
     * [Gate.BARGE] 的数是按真机实测反推的：本人 0.45、旁人 0.2–0.4。
     * 这不是偏好问题——AEC 削掉的分数补不回来，阈值只能跟着降。
     * [Gate.WAKE] 用干净录音的区间，和文献值接近。
     */
    fun baseFor(level: Level, gate: Gate): Float = when (gate) {
        Gate.BARGE -> when (level) {
            Level.LOOSE -> 0.40f
            Level.NORMAL -> 0.50f
            Level.STRICT -> 0.60f
            Level.VERY_STRICT -> 0.70f
        }
        // 没有播放、没有 AEC，音频和注册时接近：可以要求到 0.65 起。
        Gate.WAKE -> when (level) {
            Level.LOOSE -> 0.60f
            Level.NORMAL -> 0.70f
            Level.STRICT -> 0.80f
            Level.VERY_STRICT -> 0.90f
        }
        Gate.TURN -> when (level) {
            Level.LOOSE -> 0.50f
            Level.NORMAL -> 0.58f
            Level.STRICT -> 0.68f
            Level.VERY_STRICT -> 0.76f
        }
    }

    /** 拒绝线 = 接受线 − 带宽。落在 (reject, accept) 之间的一律 UNKNOWN。 */
    fun reject(level: Level, count: Int, gate: Gate = Gate.BARGE, bias: Float = 0f): Float =
        (accept(level, count, gate, bias) - BAND).coerceAtLeast(0.0f)

    fun forCount(level: Level, count: Int, bias: Float = 0f): SpeakerGate.Cutoffs =
        SpeakerGate.Cutoffs(
            accept = accept(level, count, bias = bias),
            reject = reject(level, count, bias = bias),
        )

    /** 每多一个模板往上提的系数（对数空间）。 */
    private const val PER_EXTRA = 0.045f

    private fun ln(n: Int): Float = kotlin.math.ln(n.toFloat())

    /**
     * 给"每个模板平均误接受压到 target/N"用的系数，供实测调参时对照。
     * 纯数学，不参与运行时判定。
     */
    @Suppress("unused")
    fun smoothingFor(count: Int): Int = ceil(sqrt(count.toDouble())).toInt()
}
