import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../speech/speech_audio.dart';

/// 最近几次声纹判定，只在内存里，给调测页和校准阈值用。
///
/// 为什么要有：阈值（认作自己人 / 旁人）不能照抄论文，得看真实分布。
/// 通话里每判一次就往这里记一条，看一眼就知道"自己人在多少分、旁人在多少分"，
/// 也才知道该把线画在哪儿。
class VoiceprintLog extends Notifier<List<JudgedSample>> {
  static const capacity = 60;

  @override
  List<JudgedSample> build() => const [];

  void add(JudgedSample sample) {
    state = [...state, sample].take(capacity).toList();
  }

  void clear() => state = const [];
}

/// 一条判定记录。
class JudgedSample {
  const JudgedSample({
    required this.kind,
    required this.score,
    required this.at,
    required this.over,
    this.matched,
  });

  final VoiceprintKind kind;
  final double score;
  final DateTime at;
  final bool over;
  final String? matched;
}

final voiceprintLogProvider = NotifierProvider<VoiceprintLog, List<JudgedSample>>(VoiceprintLog.new);

/// 白名单里 与 不在白名单里 两堆分数的分档统计，用来定阈值。
({int you, int other, int unknown, double youMin, double otherMax, double median}) summarise(List<JudgedSample> log) {
  if (log.isEmpty) {
    return (you: 0, other: 0, unknown: 0, youMin: 0, otherMax: 0, median: 0);
  }
  final you = log.where((s) => s.kind == VoiceprintKind.you).toList();
  final other = log.where((s) => s.kind == VoiceprintKind.other).toList();
  final unknown = log.where((s) => s.kind == VoiceprintKind.unknown).toList();
  final sorted = [...log.map((s) => s.score)]..sort();
  return (
    you: you.length,
    other: other.length,
    unknown: unknown.length,
    youMin: you.isEmpty ? 0 : you.map((s) => s.score).reduce((a, b) => a < b ? a : b),
    otherMax: other.isEmpty ? 0 : other.map((s) => s.score).reduce((a, b) => a > b ? a : b),
    median: sorted[sorted.length ~/ 2],
  );
}
