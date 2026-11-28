// 画中画小窗里的通话样子：那颗动态光球 + 一句状态。
//
// 从 voice_call_page.dart 抽出（fork(call) 的 A 区）：整页缩进小窗时
// （MainActivity 把 PiP 进出告诉 Dart），通话页与小窗卡片层都画这副。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../speech/call/voice_call.dart';
import '../../../speech/speech_settings.dart';
import '../../theme/motion.dart';
import 'call_card.dart';
import 'call_visuals.dart';

/// 画中画小窗里的样子：通话界面那颗**动态**光球 + 一句状态。
///
/// 小窗是方的、宽度只有屏幕的三分之一，整页缩进去会挤成一片，所以单独排。
/// 小窗里不做可点控件：Android 把小窗里的单击拿去展开系统控制，双击才回 App，
/// 按钮画得再好也点不到。想操作就双击回 App。
///
/// 光球自己持有一个 [CallScene]，由 [CallClock] 每帧推进。PiP 时原生特意
/// 不停帧（MainActivity.onPause），所以小窗里它一直是活的，不是定格图。
/// 收起状态下页面已经 pop 了，这副样子也由 CallCardLayer 画给画中画。
Widget callPipView({
  required L10n l10n,
  required ThemeData theme,
  required VoiceCallController call,
  bool signedIn = false,
  CallVisual visual = CallVisual.glass,
  Widget? backdrop,
  bool dark = false,
}) => CallPipView(
  key: const ValueKey('call-pip-view'),
  l10n: l10n,
  theme: theme,
  call: call,
  signedIn: signedIn,
  visual: visual,
  backdrop: backdrop,
  dark: dark,
);

class CallPipView extends StatefulWidget {
  const CallPipView({
    super.key,
    required this.l10n,
    required this.theme,
    required this.call,
    required this.signedIn,
    required this.visual,
    this.backdrop,
    this.dark = false,
  });

  final L10n l10n;
  final ThemeData theme;
  final VoiceCallController call;
  final bool signedIn;
  final CallVisual visual;

  /// 通话页挑的那张底（海 / 图片 / 她），小窗里铺在光球下面。
  ///
  /// 小窗只有一块 3:4 的地方，所以这里要的是「和通话页同一处地方」，
  /// 不是光球换掉：光球还是画面正中那个，底在它后面。
  final Widget? backdrop;

  /// 底片在的时候画面按深色走（和通话页同一个判断），状态字才读得出来。
  final bool dark;

  @override
  State<CallPipView> createState() => _CallPipViewState();
}

class _CallPipViewState extends State<CallPipView> {
  final _scene = CallScene();
  bool _still = false;

  @override
  void dispose() {
    _scene.dispose();
    super.dispose();
  }

  void _tick(double seconds) {
    _scene.tick(
      seconds,
      phase: widget.call.phase,
      mic: widget.call.micLevel,
      voice: widget.call.voiceLevel,
      isMuted: widget.call.muted,
      still: _still,
    );
  }

  @override
  Widget build(BuildContext context) {
    _still = AppMotion.reduced(context);
    // 有底片就跟通话页一样按深色走：图片或她铺满时，深色字读不出来。
    final dark = widget.dark || widget.theme.brightness == Brightness.dark;
    final palette = CallPalette.of(widget.theme.colorScheme, light: !dark);
    final (status, _) = callStatus(widget.l10n, widget.call, signedIn: () => widget.signedIn);
    final fg = dark ? Colors.white : const Color(0xFF14161F);
    // 一圈细边：小窗浮在别人的壁纸上，底片再深也可能和桌面同色，没有边就
    // 糊成一片看不出窗口在哪儿。深色画面上用亮白描边（0.38 才压得住那片
    // 深蓝，0.22 几乎看不见），浅色画面上用淡黑描边。
    final edge = dark ? Colors.white.withValues(alpha: 0.38) : Colors.black.withValues(alpha: 0.14);
    return DecoratedBox(
      key: const ValueKey('call-pip-edge'),
      decoration: BoxDecoration(
        border: Border.all(color: edge, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CallClock(
          onTick: _tick,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 和通话页同一张底，铺在最下面；光球和光晕都在它上面。
              if (widget.backdrop case final back?) Positioned.fill(child: IgnorePointer(child: back)),
              // The page's field, so the small window is not a flat swatch of
              // colour: the same faint light sits behind the sphere, a little
              // stronger, since a window this small shows it less.
              //
              // 有底片时不铺主题底色：那整块不透明的 rect 会把刚垫上的图片盖掉，
              // 人就只看到一片纯色。光晕留着，压在图上当作那团光。
              CallField(scene: _scene, palette: palette, strength: 1.7, opaque: widget.backdrop == null),
              SafeArea(
                minimum: const EdgeInsets.all(6),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = math.min(constraints.maxWidth, constraints.maxHeight) * 0.8;
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Center(
                            child: FittedBox(
                              child: CallOrb(
                                key: const ValueKey('call-pip-orb'),
                                scene: _scene,
                                call: widget.call,
                                visual: widget.visual,
                                palette: palette,
                                dark: dark,
                                size: size,
                                halo: 0.35,
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            status,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: widget.theme.textTheme.labelMedium?.copyWith(color: fg),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
