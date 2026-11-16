import 'package:lpinyin/lpinyin.dart';

/// 中文 → 关键词检测要的音素行。纯函数，不碰存储也不碰 Flutter，
/// 这样 `dart run tool/wake_probe.dart` 能直接验。
///
/// 一行一个词：`n ǐ h ǎo f éi y ú @你好肥鱼`
String? wakeKeywordLine(String word) {
  final clean = sanitizeWakeWord(word);
  if (clean.isEmpty) return null;
  final pinyin = PinyinHelper.getPinyinE(
    clean,
    separator: ' ',
    format: PinyinFormat.WITH_TONE_MARK,
  );
  if (pinyin.trim().isEmpty) return null;
  final parts = <String>[];
  for (final syllable in pinyin.trim().split(RegExp(r'\s+'))) {
    if (syllable.isEmpty) continue;
    final split = splitWakeSyllable(syllable);
    if (split == null) return null;
    parts.add(split);
  }
  if (parts.isEmpty) return null;
  return '${parts.join(' ')} @$clean';
}

/// 只留汉字：字母、数字、标点对发音没有意义，模型也只认读音。
String sanitizeWakeWord(String word) {
  final out = StringBuffer();
  for (final rune in word.runes) {
    final isHan = (rune >= 0x4E00 && rune <= 0x9FFF) || (rune >= 0x3400 && rune <= 0x4DBF);
    if (isHan) out.writeCharCode(rune);
  }
  return out.toString();
}

/// 一个音节切成声母和韵母：`hǎo` → `h ǎo`；零声母就原样（`ér` → `ér`）。
String? splitWakeSyllable(String syllable) {
  for (final initial in _initials) {
    if (syllable.startsWith(initial) && syllable.length > initial.length) {
      return '$initial ${syllable.substring(initial.length)}';
    }
  }
  return syllable;
}

/// 长的在前，否则 `zh` 会被当成 `z`。
const _initials = [
  'zh', 'ch', 'sh', //
  'b', 'p', 'm', 'f', 'd', 't', 'n', 'l', 'g', 'k', 'h', //
  'j', 'q', 'x', 'r', 'z', 'c', 's', 'y', 'w',
];
