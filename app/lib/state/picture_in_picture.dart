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
Future<bool> enterPictureInPicture() async {
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

bool _watching = false;

/// 开始听原生的画中画进出事件（通话页起来时调一次）。
void watchPictureInPicture() {
  if (_watching) return;
  _watching = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'pictureInPictureChanged') {
      pictureInPictureMode.value = call.arguments as bool? ?? false;
    }
  });
}

/// 通话页离开时停掉，不把通道占着。
void stopWatchingPictureInPicture() {
  if (!_watching) return;
  _watching = false;
  _channel.setMethodCallHandler(null);
  pictureInPictureMode.value = false;
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
