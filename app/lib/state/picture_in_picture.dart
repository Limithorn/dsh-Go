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
