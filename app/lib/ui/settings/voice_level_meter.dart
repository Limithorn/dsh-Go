import 'package:flutter/material.dart';

/// 录音时的音量量表：一条横条随声音涨落，左边那道竖线是环境的底噪。
///
/// 为什么不用绝对刻度：同一句话，安静房间里 -48 dB 够用，马路边的 -48 dB 什么都不是。
/// 所以条的起点是**底噪**，长度是**比底噪高了多少**——条过线就是"说清楚了"，
/// 换到哪儿都读得懂。
class VoiceLevelMeter extends StatelessWidget {
  const VoiceLevelMeter({
    super.key,
    required this.db,
    this.floor = -70,
    this.needed = 12,
    this.span = 36,
  });

  /// 当前电平（dBFS）。
  final double db;

  /// 环境底噪（dBFS），条的起点。
  final double floor;

  /// 要比底噪高出多少分贝才算够。
  final double needed;

  /// 条满格对应"比底噪高出多少分贝"。
  final double span;

  double get _over => (db - floor).clamp(0.0, span);

  double get _fraction => (_over / span).clamp(0.0, 1.0);

  double get _neededFraction => (needed / span).clamp(0.0, 1.0);

  bool get _enough => _over >= needed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: 10,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              // 及格线：条越过它就算说清楚了。
              Positioned(
                left: width * _neededFraction - 1,
                top: -2,
                bottom: -2,
                child: Container(width: 2, color: scheme.outline),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 90),
                curve: Curves.easeOut,
                left: 0,
                top: 0,
                bottom: 0,
                width: width * _fraction,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _enough ? scheme.primary : scheme.error,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
