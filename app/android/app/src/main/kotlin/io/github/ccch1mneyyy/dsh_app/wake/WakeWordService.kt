package io.github.ccch1mneyyy.dsh_app.wake

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R

/**
 * 让后台的麦克风合法。
 *
 * Android 只要离开了前台，录音就会被掐，唯一的路是挂一个 microphone 类型的前台服务；
 * 这个服务本身不碰 AudioRecord，采集在 WakePlugin（同一个进程，跟着 Flutter engine 走），
 * 它负责的是"这条进程还在用麦克风"这件事和那条常驻通知。
 *
 * Android 14 起，这类服务必须在 App 可见时启动。开关在设置页里，人点的时候 App
 * 就在前台，所以这一条自然满足；真正被后台拉起的情况一律失败，失败就如实停掉。
 */
class WakeWordService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        try {
            val n = notification(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            running = true
        } catch (e: Exception) {
            Log.w("DshWake", "wake service could not go foreground", e)
            running = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "dsh-wake"
        private const val NOTIFICATION_ID = 3091

        @Volatile var running = false
            private set

        /** 与 [on] 对齐地启动或停止；已经一致就什么都不做。 */
        fun ensure(context: Context, on: Boolean) {
            if (on == running) return
            try {
                if (on) {
                    context.startForegroundService(Intent(context, WakeWordService::class.java))
                    running = true
                } else {
                    context.stopService(Intent(context, WakeWordService::class.java))
                    running = false
                }
            } catch (e: Exception) {
                // 后台被拒（厂商策略）：唤醒也就跟着没了，交给上层如实显示。
                Log.w("DshWake", "wake service ${if (on) "start" else "stop"} refused", e)
                running = false
            }
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.wake_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = context.getString(R.string.wake_channel_description)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        private fun notification(context: Context): Notification {
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context)
            }
            return builder
                .setContentTitle(context.getString(R.string.wake_notification_title))
                .setContentText(context.getString(R.string.wake_notification_text))
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentIntent(open)
                .setOngoing(true)
                .build()
        }
    }
}
