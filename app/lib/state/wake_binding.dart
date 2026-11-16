import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 唤醒之后跟哪一间对话说话。
///
/// 叫醒它的时候人不在 App 里，没有"当前会话"这回事；指了就把话送进那间，
/// 没指就现开一间。之前这里什么都没存，会话给的是 null，结果叫醒之后说的话
/// 没有地方去，界面上就是发不出去。
class WakeBinding {
  static const _key = 'wake.sessionId';

  /// 指定的会话；`null` 表示每回都新开一间。
  static Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_key);
    return (id == null || id.isEmpty) ? null : id;
  }

  static Future<void> write(String? sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    if (sessionId == null || sessionId.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, sessionId);
  }
}

/// 设置页读它来显示当前绑的是哪间；改完 [WakeBinding.write] 之后 invalidate。
final wakeBindingProvider = FutureProvider<String?>((ref) => WakeBinding.read());
