import 'package:flutter/material.dart';

import '../theme/semantic_colors.dart';
import '../theme/typography.dart';
import 'settings_widgets.dart';

/// 带刻度的滑条行：拖到哪算哪，松手才提交。
///
/// 和 [SettingsSliderTile] 的区别：那个是百分比、无刻度、给「模糊度 30%」
/// 这类无级参数用的；这个给**有档位语义**的参数用（判定门槛的四档），
/// 底下标出档位名字，拖到档位上会吸附。
///
/// 为什么松手才提交（`onChangeEnd` 而不是 `onChanged`）：这些值一路走到
/// 原生 `configure()`，拖动时每一步都推会变成每秒几十次跨端调用，还会让
/// 判定在拖动过程中反复抖动。拖动只更新本地显示，松手推一次最终值。
class GradedSliderTile extends StatefulWidget {
  const GradedSliderTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.onCommit,
    this.grades = const [],
    this.enabled = true,
    this.format,
  });

  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;

  /// 松手时回调最终值（已吸附到最近的档位刻度，若给出 [grades]）。
  final ValueChanged<double> onCommit;

  /// 档位刻度：(值, 名字)。给出时会在下方标注，并在这些值处吸附。
  final List<(double, String)> grades;

  final bool enabled;

  /// 右侧数值的写法；默认保留两位小数。
  final String Function(double value)? format;

  @override
  State<GradedSliderTile> createState() => _GradedSliderTileState();
}

class _GradedSliderTileState extends State<GradedSliderTile> {
  /// 拖动中的临时值。null 表示没在拖，显示外部的 [GradedSliderTile.value]。
  double? _dragging;

  double get _current => (_dragging ?? widget.value).clamp(widget.min, widget.max);

  String get _text => (widget.format ?? _defaultFormat)(_current);

  static String _defaultFormat(double v) => v.toStringAsFixed(2);

  /// 就近吸附：距离最近刻度不到 3% 量程才吸。
  ///
  /// 不做全量吸附——那样滑条就等于变成了四档选择，失去微调的意义。
  double _snapIfNear(double v) {
    if (widget.grades.isEmpty) return v;
    final span = widget.max - widget.min;
    var best = v;
    var bestDist = double.infinity;
    for (final (g, _) in widget.grades) {
      final d = (v - g).abs();
      if (d < bestDist) {
        bestDist = d;
        best = g;
      }
    }
    return bestDist <= span * 0.03 ? best : v;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 14, SettingsMetrics.inset, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: settingsTitleStyle(context)?.copyWith(
                      color: widget.enabled ? scheme.onSurface : colors.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _text,
                  // 数字用等宽，拖动时不会因为字宽变化而左右跳。
                  style: AppType.tabular(theme.textTheme.bodyMedium!).copyWith(
                    color: widget.enabled ? scheme.onSurfaceVariant : colors.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              widget.subtitle,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
            ),
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                activeTrackColor: widget.enabled ? scheme.primary : scheme.onSurface.withValues(alpha: 0.25),
                inactiveTrackColor: scheme.surfaceContainerHighest,
                thumbColor: widget.enabled ? scheme.primary : scheme.onSurface.withValues(alpha: 0.35),
              ),
              child: Slider(
                value: _current,
                min: widget.min,
                max: widget.max,
                onChanged: widget.enabled
                    ? (v) => setState(() => _dragging = v)
                    : null,
                onChangeEnd: widget.enabled
                    ? (v) {
                        final snapped = _snapIfNear(v);
                        setState(() => _dragging = null);
                        widget.onCommit(snapped);
                      }
                    : null,
              ),
            ),
            if (widget.grades.isNotEmpty)
              // 刻度标签：用同一量程换算位置，和滑条轨道对齐。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final span = widget.max - widget.min;
                    return SizedBox(
                      height: 16,
                      child: Stack(
                        children: [
                          for (final (g, name) in widget.grades)
                            Positioned(
                              left: (constraints.maxWidth - 40) * ((g - widget.min) / span),
                              width: 40,
                              child: Text(
                                name,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
