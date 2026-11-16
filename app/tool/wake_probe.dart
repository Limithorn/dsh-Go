// 唤醒词转换的自检：中文 → 音素行，并把音素与 tokens.txt 对一遍。
//
//   dart run tool/wake_probe.dart
//
// 对不上的音素会打出来，那说明这个词念不出来，换一个。
import 'dart:io';

import 'package:dsh_app/speech/wake_pinyin.dart';

void main() {
  final tokens = <String>{};
  final file = File('assets/wake/tokens.txt');
  if (file.existsSync()) {
    for (final line in file.readAsLinesSync()) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.isNotEmpty && parts.first.isNotEmpty) tokens.add(parts.first);
    }
  }
  print('tokens: ${tokens.length}');
  for (final word in ['你好肥鱼', '你好米', '小艺小艺', '米米']) {
    final line = wakeKeywordLine(word);
    if (line == null) {
      print('$word -> 转不出来');
      continue;
    }
    final phones = line.split('@').first.trim().split(RegExp(r'\s+'));
    final missing = phones.where((p) => !tokens.contains(p)).toList();
    print('$word -> $line${missing.isEmpty ? '  ✓' : '  缺: $missing'}');
  }
}
