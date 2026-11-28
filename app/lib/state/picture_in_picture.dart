import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通话页的跨应用形态：把整个 App 缩成系统窗口（画中画），通话继续。
///
/// 画中画里的 Activity 仍算可见，麦克风不会被系统掐，所以通话轮次、话音识别
/// 都不需要另起前台服务；离开 App 只是换了个窗口大小。
///
/// 这条路不需要悬浮窗权限（SYSTEM_ALERT_WINDOW），是跨应用最低成本的一步。
const _channel = MethodChannel('dsh/app');

/// 系统是否给这个 App 画中画能力（Android 8 以下没有）。
Future<bool> pictureInPictureAvailable() async {
  try {
    return await _channel.invokeMethod<bool>('pictureInPictureAvailable') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// 进入画中画。返回 false 表示系统不允许或没有该能力。
///
/// [dismiss] 在真的进小窗之前调用一次：小窗画的是 [CallCardLayer] 这一层，
/// 而底部弹层（背景设置那种）挂在 MaterialApp 的 Navigator 里，比这一层还高。
/// 不收掉它，小窗里就把它一起画了进去——"小窗怎么是设置页"就是这么来的。
Future<bool> enterPictureInPicture({Future<void> Function()? dismiss}) async {
  if (dismiss != null) {
    await dismiss();
  }
  try {
    return await _channel.invokeMethod<bool>('enterPictureInPicture') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// 现在是不是在画中画小窗里。
///
/// 小窗只有巴掌大，整页缩进去按钮会挤成一团，所以通话页需要知道这件事，
/// 在里面换一套只留球、状态和挂断的布局。
final pictureInPictureMode = ValueNotifier<bool>(false);

/// 通话中锁着屏：界面被锁屏盖住，但麦克风还在（前台服务撑着）。
/// 这种时候不算「切到后台」，否则锁屏叫醒后通话马上就结束了。
final callScreenLocked = ValueNotifier<bool>(false);

bool _watching = false;

/// 开始听原生的画中画进出事件（通话页起来时调一次）。
void watchPictureInPicture() {
  if (_watching) return;
  _watching = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'pictureInPictureChanged') {
      pictureInPictureMode.value = call.arguments as bool? ?? false;
    } else if (call.method == 'callScreenLocked') {
      callScreenLocked.value = call.arguments as bool? ?? false;
    }
  });
}

/// 通话页离开时停掉，不把通道占着。
void stopWatchingPictureInPicture() {
  if (!_watching) return;
  _watching = false;
  _channel.setMethodCallHandler(null);
  pictureInPictureMode.value = false;
  callScreenLocked.value = false;
}
///
/// 通话中按 home 或切走时，原生会直接缩成小窗，而不是退到后台——
/// 后台麦克风会被系统掉，通话就断了。
Future<void> setCallActive(bool active) async {
  try {
    await _channel.invokeMethod<void>('setCallActive', {'active': active});
  } on PlatformException {
    // 没有原生侧（桌面、测试）：不拦。
  } on MissingPluginException {
    // 同上。
  }
}

/// 通话时的屏幕行为：锁竖屏，并让手机贴到耳边就熄屏（挂断时传 false 撤销）。
Future<void> setCallScreen(bool active) async {
  try {
    await _channel.invokeMethod<void>('setCallScreen', {'on': active});
  } on PlatformException {
    // 同上。
  } on MissingPluginException {
    // 同上。
  }
}

/// 整页通话收起（返回键/收起键）时告诉原生：若此刻正锁屏，撤掉 showWhenLocked，
/// 让 keyguard 立刻盖住界面——一次返回就回到锁屏，而不是先露出底下的对话页。
///
/// 是否真的撤由原生判断（showWhenLocked 时 Dart 收不到锁屏生命周期，判不准）。
/// 没锁屏时原生什么都不做，正常收起成卡片继续聊。
Future<void> leaveCallToLock() async {
  try {
    await _channel.invokeMethod<void>('leaveCallToLock');
  } on PlatformException {
    // 没有原生侧（桌面、测试）：不拦。
  } on MissingPluginException {
    // 同上。
  }
}
