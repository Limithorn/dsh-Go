import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'wake_pinyin.dart';

/// 唤醒词：人写中文，模型要的是拼音音素（换算见 wake_pinyin.dart）。
///
/// 设置里存的是中文那一个词；开听之前把它写成模型目录的 keywords.txt，
/// 引擎读的就是这一行。
class WakeWords {
  /// 默认为「你好肥鱼」，和设置里那一栏的初值一致。
  static const fallback = '你好肥鱼';

  static const _key = 'wake.word';

  /// 存下来的唤醒词；没设过就是 [fallback]。
  static Future<String> read() async {
    final prefs = await SharedPreferences.getInstance();
    final word = prefs.getString(_key)?.trim();
    return (word == null || word.isEmpty) ? fallback : word;
  }

  static Future<void> write(String word) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = sanitizeWakeWord(word);
    if (clean.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, clean);
  }

  /// 把当前唤醒词写进模型目录。引擎启动前调用。
  static Future<String> syncTo(String modelDir) async {
    final word = await read();
    final line = wakeKeywordLine(word);
    final file = File('$modelDir/keywords.txt');
    // 转不出来（生僻字、纯符号）就保留打包时那份原词表，至少还能被叫醒。
    if (line == null) return word;
    await file.writeAsString('$line\n', flush: true);
    return word;
  }
}
