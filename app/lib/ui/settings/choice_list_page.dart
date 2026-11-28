import 'package:flutter/material.dart';

import '../theme/semantic_colors.dart';
import '../theme/app_icons.dart';

/// 二级页里的一档。
class ChoiceOption<T> {
  const ChoiceOption(this.value, this.title, {this.subtitle});

  final T value;
  final String title;

  /// 这一档的副作用 / 代价。必填的理由见 [ChoiceListPage]。
  final String? subtitle;
}

/// 二级页单选：一行档位，选中打勾。
///
/// 为什么用整页而不是弹层：这些档位都带「副作用说明」（通话音源压人声、
/// 自动要等 4.5 秒），弹层里塞不下，而且用户要来回对照着选。整页能一次
/// 看完所有说明再决定。
///
/// 返回选中的值；左上角返回或按返回键返回 `null`，调用方据此判断「没改」。
class ChoiceListPage<T> extends StatelessWidget {
  const ChoiceListPage({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    this.footer,
  });

  final String title;
  final List<ChoiceOption<T>> options;
  final T selected;

  /// 页脚补充说明，比如「多人时门槛会自动抬高」。
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < options.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: scheme.outlineVariant.withValues(alpha: 0.5)),
                  _OptionRow<T>(
                    option: options[i],
                    selected: options[i].value == selected,
                    onTap: () => Navigator.of(context).pop(options[i].value),
                  ),
                ],
              ],
            ),
          ),
          if (footer case final f?)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                f,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({required this.option, required this.selected, required this.onTap});

  final ChoiceOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        option.title,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: selected ? scheme.primary : scheme.onSurface,
                          fontWeight: selected ? FontWeight.w600 : null,
                        ),
                      ),
                      if (option.subtitle case final s?) ...[
                        const SizedBox(height: 2),
                        Text(
                          s,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.4),
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 12),
                  Icon(AppIcons.selected, size: 20, color: scheme.primary),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开 [ChoiceListPage]，返回选中的值（没选返回 null）。
Future<T?> showChoicePage<T>(
  BuildContext context, {
  required String title,
  required List<ChoiceOption<T>> options,
  required T selected,
  String? footer,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (_) => ChoiceListPage<T>(
        title: title,
        options: options,
        selected: selected,
        footer: footer,
      ),
    ),
  );
}
