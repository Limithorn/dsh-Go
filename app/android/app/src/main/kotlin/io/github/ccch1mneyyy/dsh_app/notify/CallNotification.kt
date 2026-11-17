package io.github.ccch1mneyyy.dsh_app.notify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings

/**
 * 语音通话的常驻通知。
 *
 * 通话时 Activity 靠画中画保持可见、麦克风不被掐；但用户在小窗里按 x 关掉小窗后，
 * 通话其实还在（Dart 侧控制器和麦克风都没停），界面却没了，看起来像"通话断了"。
 * 这条 ongoing 通知让通知栏一直挂着"语音通话进行中"，点按回到 App 的通话界面。
 *
 * 生命周期跟 [setCallActive] 绑在一起：通话真正结束（Dart 侧 phase=ended / close）
 * 才 cancel，收起成卡片、进画中画、按 x 关小窗期间都保持显示。
 */
object CallNotification {
    private const val CHANNEL_ID = "dsh-call"
    private const val NOTIFICATION_ID = 3092

    /** 通话开始：建渠道、发通知。可在任意线程调用。 */
    fun show(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(manager, context)
        manager.notify(NOTIFICATION_ID, build(context))
    }

    /** 通话结束：撤掉通知。 */
    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    private fun ensureChannel(manager: NotificationManager, context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            AppStrings.get(context, R.string.call_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = AppStrings.get(context, R.string.call_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun build(context: Context): Notification {
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
            .setContentTitle(AppStrings.get(context, R.string.call_notification_title))
            .setContentText(AppStrings.get(context, R.string.call_notification_text))
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .build()
    }
}
