package io.github.ccch1mneyyy.dsh_app

import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.PowerManager
import android.util.Rational
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.files.FilesPlugin
import io.github.ccch1mneyyy.dsh_app.launch.LaunchScreen
import io.github.ccch1mneyyy.dsh_app.launch.LaunchThemeSync
import io.github.ccch1mneyyy.dsh_app.links.LinksPlugin
import io.github.ccch1mneyyy.dsh_app.notify.NotifyPlugin
import io.github.ccch1mneyyy.dsh_app.phone.PhonePlugin
import io.github.ccch1mneyyy.dsh_app.runtime.AndroidBackgroundProtection
import io.github.ccch1mneyyy.dsh_app.runtime.LaunchStart
import io.github.ccch1mneyyy.dsh_app.runtime.RuntimePlugin
import io.github.ccch1mneyyy.dsh_app.share.SharePlugin
import io.github.ccch1mneyyy.dsh_app.shortcuts.ShortcutsPlugin
import io.github.ccch1mneyyy.dsh_app.text.CachedTextActions
import io.github.ccch1mneyyy.dsh_app.update.UpdatePlugin
import io.github.ccch1mneyyy.dsh_app.voice.VoicePlugin
import java.lang.ref.WeakReference
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private var appChannel: MethodChannel? = null

    /** The selection toolbar's text actions, asked of the engine once (see [CachedTextActions]). */
    private var textActions: CachedTextActions? = null

    /**
     * One engine per process, outliving this activity: swiping the app away from recents keeps
     * Dart running, and with it the event subscriptions behind turn-finished / needs-you
     * notifications. Plugins are registered once, with the engine.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        return FlutterEngine(applicationContext).also { engine ->
            engine.plugins.add(RuntimePlugin())
            engine.plugins.add(PhonePlugin())
            engine.plugins.add(NotifyPlugin())
            engine.plugins.add(FilesPlugin())
            engine.plugins.add(LinksPlugin())
            engine.plugins.add(UpdatePlugin())
            engine.plugins.add(VoicePlugin())
            engine.plugins.add(SharePlugin())
            engine.plugins.add(ShortcutsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.diagnostics.DiagnosticsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.media.MediaPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.media.MediaVideoPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.icons.LauncherIconPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.theme.DynamicColorPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.performance.PerformancePlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.pet.PetOverlayPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.islands.IslandsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.nativemedia.NativeMediaPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.nativefiles.NativeFilesPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.web.WebFilesPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.launch.LaunchPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.launch.LaunchClipPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.icons.PictureShortcutPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.usage.UsagePlugin())
        engine.plugins.add(io.github.ccch1mneyyy.dsh_app.wake.WakePlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionVoicePlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.speech.SpeechPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionWidgetPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionReminderPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionMapPlugin())
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            cache.put(ENGINE_ID, engine)
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    /**
     * This activity's own <meta-data> (normal theme, Flutter deep linking off), whichever launcher
     * alias opened it: Flutter reads it for getComponentName(), which is the alias — that has
     * none of it, and is disabled once the user picks another 桌面图标 (icons/).
     */
    override fun getMetaData(): Bundle? =
        packageManager.getActivityInfo(ComponentName(this, MainActivity::class.java), PackageManager.GET_META_DATA).metaData

    override fun onCreate(savedInstanceState: Bundle?) {
        // 「打开 App 时自动启动」: DSH boots while Flutter starts, not after its first frame.
        LaunchStart.onActivityCreate(this)
        // 启动画面: the first activity of a cold start hands the system's launch window to Dart's.
        LaunchScreen.onActivityCreate(this, coldDart = FlutterEngineCache.getInstance().get(ENGINE_ID) == null)
        // Recreated, or reopened from recents: the launch intent is an old notification tap or
        // link that was handled back then. Don't let the plugins route it again.
        if (savedInstanceState != null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) {
            intent.action = Intent.ACTION_MAIN
            intent.replaceExtras(Bundle())
        }
        super.onCreate(savedInstanceState)
        // Fully transparent system bars, no OEM scrim behind the gesture handle.
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) window.setDecorFitsSystemWindows(false)
        current = WeakReference(this)
        // After LaunchScreen read what this launch's splash showed: the next ones show the icon
        // (and launch screen) chosen now (Android 13+).
        LaunchThemeSync.sync(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Light / dark: a custom launch screen's plain splash colour (the page's) may change with it.
        LaunchThemeSync.sync(this)
        // The language: other apps' text actions are named in it.
        textActions?.forget()
    }

    override fun onStart() {
        super.onStart()
        AndroidBackgroundProtection.get(this).setAppVisible(true)
    }

    override fun onStop() {
        AndroidBackgroundProtection.get(this).setAppVisible(false)
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundControl.get(applicationContext).restoreKeptChannel()
        inForeground = true
        // Another app may have been changed meanwhile.
        textActions?.forget()
        // Coming back counts as activity: the first frames may not be scheduled yet.
        framesActive = true
        applyRefreshRate()
        // 锁屏回来了：从「锁屏不算后台」改回正常判断。
        appChannel?.invokeMethod("callScreenLocked", false)
    }

    /**
     * The window's preferred display mode, from the in-app refresh-rate setting.
     *
     * `preferredDisplayModeId = 0` means "no preference": the system picks, and its own
     * refresh-rate setting and power saving still decide. Apps that never ask stay at 60 or
     * 90 Hz on some 120 Hz phones (OriginOS, HyperOS, ColorOS); once an app does ask, those
     * systems show their per-app switch as an in-app setting – hence the setting in 设置 › 性能.
     *
     * auto: fastest mode while Flutter is producing frames, released after the last one.
     * max: pinned. system: never declared.
     */
    private fun applyRefreshRate() {
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay
        val now = display.mode
        val fastest = display.supportedModes
            .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
            .maxByOrNull { it.refreshRate }
        val want = when (refreshMode) {
            "max" -> fastest
            "system" -> null
            else -> if (framesActive) fastest else null
        }
        val target = want?.modeId ?: 0
        if (window.attributes.preferredDisplayModeId != target) {
            window.attributes = window.attributes.apply { preferredDisplayModeId = target }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val view = flutterSurfaceView(findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)) ?: return
        if (view !== votedView) {
            votedView = view
            // Coming back from the background, onResume runs before the surface is made again.
            view.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) = applyRefreshRate()
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                override fun surfaceDestroyed(holder: SurfaceHolder) {}
            })
        }
        val surface = view.holder.surface
        if (surface.isValid) surface.setFrameRate(want?.refreshRate ?: 0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
    }

    /** Flutter's SurfaceView, which [applyRefreshRate] also votes on. */
    private var votedView: SurfaceView? = null

    private fun flutterSurfaceView(view: View?): SurfaceView? {
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                flutterSurfaceView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    override fun onPause() {
        inForeground = false
        // 通话中锁屏：Activity 被盖住了，但麦克风还在（麦克风类型的前台服务撑着）。
        // 告诉 Dart 这种情况不算「切到后台」，否则通话会自己结束——
        // 之前锁屏叫醒后界面刚出来、一秒就退，就是这个。
        if (callActive) {
            val locked = runCatching {
                getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true
            }.getOrDefault(false)
            if (locked) appChannel?.invokeMethod("callScreenLocked", true)
        }
        // 画中画里不能停帧：小窗是活的，停帧就是画面定在那儿不动。
        if (!isInPictureInPictureMode) {
            framesActive = false
            applyRefreshRate()
        }
        super.onPause()
    }

    /// 语音通话进行中按 home / 切到别的 App：直接缩成画中画，而不是退到后台。
    /// 退到后台麦克风会被系统掉，通话就断了（画中画里的 Activity 仍算可见）。
    override fun onUserLeaveHint() {
        if (callActive) enterPip()
        super.onUserLeaveHint()
    }

    /// 画中画进出时告诉 Dart：小窗里要换成简版布局。
    /// 同时把渲染重新打开：进小窗那一刻 onPause 可能已经把帧停了。
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            framesActive = true
            inForeground = true
            applyRefreshRate()
        }
        appChannel?.invokeMethod("pictureInPictureChanged", isInPictureInPictureMode)
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return false
        return try {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder().setAspectRatio(Rational(3, 4)).build(),
            )
        } catch (_: Exception) {
            false
        }
    }

    /** Per activity: the handler acts on this activity, so it goes with it (see [cleanUpFlutterEngine]). */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textActions = CachedTextActions.install(flutterEngine)
        appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/app")
        appChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getTimeZoneId" -> result.success(TimeZone.getDefault().id)
                "initializePairingScanner" -> {
                    try {
                        io.github.ccch1mneyyy.dsh_app.mlkit.MlKitRuntime.initialize(applicationContext)
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("scanner_initialization_failed", "The barcode scanner could not be initialized", null)
                    }
                }
                // A browser sign-in finished (a Custom Tab on top of this task): clearing down
                // to this activity closes the tab and shows the app again.
                // 设置 → 性能 → 刷新率: auto | max | system, and whether Flutter is drawing.
                "setRefreshRateMode" -> {
                    when (call.argument<String>("mode")) {
                        "auto", "max", "system" -> refreshMode = call.argument<String>("mode")!!
                    }
                    applyRefreshRate()
                    result.success(null)
                }
                "setFrameActive" -> {
                    framesActive = call.argument<Boolean>("active") ?: framesActive
                    applyRefreshRate()
                    result.success(null)
                }
                "bringToFront" -> {
                    startActivity(
                        Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                    result.success(null)
                }
                // 语音通话: shrink the whole app into a system window over other apps, so
                // the call keeps the microphone (a picture-in-picture activity still counts
                // as visible) and the conversation is one tap away. Returns false when the
                // system or the device does not allow it.
                "enterPictureInPicture" -> result.success(enterPip())
                // 通话页告诉原生现在是不是在通话，按 home 时据此决定要不要缩成小窗。
                // 通话页的屏幕行为：锁竖屏（通话时转横屏只会让按钮错位），
                // 并持一个 PROXIMITY_SCREEN_OFF 唤醒锁——手机贴到耳边就熄屏。
                "setCallScreen" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on) {
                        runCatching { requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
                        // 锁屏时也要能亮起来把通话页显出来（唤醒词在锁屏时叫醒要靠它们），
                        // 否则 bringToFront 被锁屏挡住，看起来就是「锁屏不能唤醒」。
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                            runCatching {
                                setShowWhenLocked(true)
                                setTurnScreenOn(true)
                            }
                        } else {
                            @Suppress("DEPRECATION")
                            runCatching {
                                window.addFlags(
                                    android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                                        android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
                                )
                            }
                        }
                        if (proxWake == null) {
                            runCatching {
                                val pm = getSystemService(PowerManager::class.java)
                                proxWake = pm?.newWakeLock(
                                    PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                                    "dsh:call-proximity",
                                )?.apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                        }
                    } else {
                        runCatching { requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                            runCatching {
                                setShowWhenLocked(false)
                                setTurnScreenOn(false)
                            }
                        }
                        runCatching { proxWake?.release() }
                        proxWake = null
                    }
                    result.success(null)
                }
                "setCallActive" -> {
                    callActive = call.argument<Boolean>("active") ?: false
                    // Android 12 起该用 autoEnter：事先告诉系统「我在通话」，
                    // 人一按 home 它自己就缩成小窗。onUserLeaveHint 里再调一次
                    // 在 12+ 上容易被当成「Activity 已经走了」而失败，
                    // 这就是之前按 home 后小窗没出来的原因。
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        runCatching {
                            setPictureInPictureParams(
                                PictureInPictureParams.Builder()
                                    .setAspectRatio(Rational(3, 4))
                                    .setAutoEnterEnabled(callActive)
                                    .build(),
                            )
                        }
                    }
                    result.success(null)
                }
                // Whether the system has picture-in-picture for this app at all.
                "pictureInPictureAvailable" -> {
                    val available = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                    result.success(available)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        appChannel?.setMethodCallHandler(null)
        appChannel = null
        textActions = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // Back on the home screen sends the app to the background instead of finishing the activity
    // (Android 12's default for launcher roots): coming back finds it as it was.
    override fun popSystemNavigator(): Boolean = moveTaskToBack(true)

    /** Flutter produced a frame recently (see RefreshRateService): auto mode follows it. */
    private var framesActive = true

    /// 正在语音通话（由 Dart 侧的 call setCallActive 告知），
    /// 按 home 时据此决定是否缩成画中画。
    private var callActive = false

    /// 通话时屏幕靠近脸就熄（耗电和误触都省了），挂断释放。
    private var proxWake: PowerManager.WakeLock? = null

    companion object {
        private const val ENGINE_ID = "dsh-main"

        /** 设置 › 性能 › 刷新率; the Flutter side owns the stored choice. */
        private var refreshMode = "auto"

        /** The app is on screen (resumed). */
        @Volatile var inForeground = false
            private set

        /** The activity now, for what needs one later (the splash theme of the next launches). */
        @Volatile var current: WeakReference<MainActivity>? = null
            private set
    }
}
