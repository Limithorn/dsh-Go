import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../speech/speech_audio.dart';

/// 唤醒词灵敏度存在哪。
///
/// 和 [WakeBinding] 一样是「读一次、写一次」的短设置：模型载入时读一次门槛，
/// 设置页改了就重载。改完要 [wakeProvider] 先 stop 再 start，sherpa 的
/// keywordsThreshold 只在建 KeywordSpotter 时读得进去。
class WakeSensitivityStore {
  static const _key = 'wake.sensitivity';

  /// 存着的档位；没存过就是默认的 [WakeSensitivity.normal]（0.25）。
  static Future<WakeSensitivity> read() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_key);
    return WakeSensitivity.values.asNameMap()[name] ?? WakeSensitivity.normal;
  }

  static Future<void> write(WakeSensitivity level) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, level.name);
  }
}

/// 设置页读它显示当前档位；改完 [WakeSensitivityStore.write] 之后 invalidate。
final wakeSensitivityProvider = FutureProvider<WakeSensitivity>((ref) => WakeSensitivityStore.read());
