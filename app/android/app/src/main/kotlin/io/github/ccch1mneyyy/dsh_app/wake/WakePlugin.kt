package io.github.ccch1mneyyy.dsh_app.wake

import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 唤醒的通道：开、关、以及把麦克风数据推给 Dart。
 *
 * 分工是这样——这个类只管采集（WakeCapture）和那条撑住后台麦克风的前台服务
 * （WakeWordService）；判断是否叫到名字在 Dart，模型和 sherpa 都在那边。
 * 采集出的 PCM16 按小端字节数组推过去（Flutter 的标准消息编码没有 Int16List，
 * 用字节最稳），Dart 再还原成样本喂给关键词检测。
 */
class WakePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var capture: WakeCapture? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val ch = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> result.success(start())
            "stop" -> {
                stop()
                result.success(true)
            }
            "isRunning" -> result.success(capture?.active == true)
            "hasMicrophone" -> result.success(
                context?.packageManager?.hasSystemFeature(PackageManager.FEATURE_MICROPHONE) == true,
            )
            else -> result.notImplemented()
        }
    }

    private fun start(): Boolean {
        val ctx = context ?: return false
        WakeWordService.ensure(ctx, true)
        if (capture?.active == true) return true
        val c = WakeCapture(
            main,
            onChunk = { samples -> send(samples) },
            onError = { reason ->
                channel?.invokeMethod("error", reason)
                stop()
            },
        )
        if (!c.start()) {
            WakeWordService.ensure(ctx, false)
            return false
        }
        capture = c
        return true
    }

    private fun stop() {
        capture?.stop()
        capture = null
        context?.let { WakeWordService.ensure(it, false) }
    }

    private fun send(samples: ShortArray) {
        val bytes = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) bytes.putShort(s)
        channel?.invokeMethod("chunk", bytes.array())
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    companion object {
        const val CHANNEL = "dsh/wake"
    }
}
