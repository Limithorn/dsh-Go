// 收起的通话卡片挂载层（fork(call) 的 A 区组件）。
//
// 包在 RootGate 的最外面（ui/shell/root_gate.dart）：在一切页面之上、在
// 任何 push 上去的路由之下——整页的通话页盖得住它；页面 pop 掉（收起）后
// 它浮在别的页面上，只有卡片自己收触摸，下面的页面照常可用。这正是宿主
// 架构的意义（state/voice_call_host.dart）：那条路由永远做不到穿透触摸
// （test/speech/collapsed_card_hit_test.dart）。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../speech/call/voice_call.dart';
import '../../../speech/speech_settings.dart';
import '../../../state/account_state.dart';
import '../../../state/picture_in_picture.dart';
import '../../../state/voice_call_host.dart';
import '../voice_call_page.dart' show pushVoiceCallPage;
import 'call_backdrop.dart';
import 'call_card.dart';
import 'call_pip.dart';

/// The hosted call as a card over the app's own pages. Hung on the RootGate:
/// it is under any pushed route, so the full call page covers it; with the
/// page popped (收起) it floats over whatever the person is doing, and only
/// the card itself takes touches — the pages beneath stay usable. That is the
/// whole point (the route could never pass touches through).
///
/// With no hosted call it is nothing but its child.
class CallCardLayer extends StatefulWidget {
  const CallCardLayer({super.key, required this.child});

  final Widget child;

  @override
  State<CallCardLayer> createState() => _CallCardLayerState();
}

class _CallCardLayerState extends State<CallCardLayer> with SingleTickerProviderStateMixin {
  VoiceCallHost get _host => VoiceCallHost.instance;

  /// Where the card was dragged. A ValueNotifier, so a pan rebuilds only the
  /// transform and the gesture recognizer is never thrown away mid-drag.
  final _cardOffset = ValueNotifier<Offset>(Offset.zero);

  /// 松手时把超出屏幕的部分滑回来。没有它，横着多拖几次卡片就停在
  /// 屏幕外，四个键和拖拽起点一起消失（真机上看着就是「卡死」）。
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  VoidCallback? _snapTick;

  @override
  void initState() {
    super.initState();
    _host.addListener(_onHost);
    // 冷启动 / RootGate 重建时若根本没有通话，把原生侧可能残留的
    // callActive（以及 Android 12+ 的 autoEnter）关掉。否则在对话页按返回，
    // popSystemNavigator、onUserLeaveHint、autoEnter 都会把人送进小窗。
    if (_host.call == null) unawaited(setCallActive(false));
  }

  @override
  void dispose() {
    _stopSnap();
    _snap.dispose();
    _host.removeListener(_onHost);
    _cardOffset.dispose();
    super.dispose();
  }

  /// 卡片现在是窄的一条（[CollapsedCallCard.width]），居中摆，左右都留出了
  /// 余量：横向终于能真的挪动，而不是第三轮那样只剩 ±8dp 的跟手弹性。
  /// 竖向范围不变，照样能一路拖到顶。
  static const double _screenMargin = 8;
  static const double _dragGive = 24;

  /// 松手后必须停住的范围。left = 居中基准 + dx，两边都要留 [_screenMargin]。
  Offset _clampRest(Offset offset, Size size) {
    final base = (size.width - CollapsedCallCard.width) / 2;
    final side = math.max(0.0, base - _screenMargin);
    final up = math.max(0.0, size.height - 96);
    return Offset(
      offset.dx.clamp(-side, side).toDouble(),
      offset.dy.clamp(-up, 20.0).toDouble(),
    );
  }

  /// 按住时多给一点弹性，手上有跟手的反馈；松手由 [_settle] 收回安全范围。
  Offset _clampDrag(Offset offset, Size size) {
    final rest = _clampRest(offset, size);
    final base = (size.width - CollapsedCallCard.width) / 2;
    final side = math.max(0.0, base - _screenMargin) + _dragGive;
    return Offset(offset.dx.clamp(-side, side).toDouble(), rest.dy);
  }

  void _stopSnap() {
    _snap.stop();
    final tick = _snapTick;
    if (tick != null) {
      _snap.removeListener(tick);
      _snapTick = null;
    }
  }

  /// 松手：卡片永远完整留在屏内，静音/展开/小窗/挂断四个键都点得到。
  void _settle(Size size) {
    final from = _cardOffset.value;
    final to = _clampRest(from, size);
    if (from == to) return;
    _stopSnap();
    final anim = Tween<Offset>(begin: from, end: to)
        .animate(CurvedAnimation(parent: _snap, curve: Curves.easeOut));
    void tick() {
      if (mounted) _cardOffset.value = anim.value;
    }

    _snapTick = tick;
    _snap.addListener(tick);
    _snap.forward(from: 0).whenCompleteOrCancel(() {
      if (_snapTick == tick) {
        _snap.removeListener(tick);
        _snapTick = null;
      }
    });
  }

  /// 点卡片：页面重新 push 上来，复用宿主里那同一个控制器。宿主只搬状态
  /// （[VoiceCallHost.expanding]），页面这条路由由这层推——宿主不碰 ui。
  Future<void> _expand(BuildContext context) async {
    final call = _host.call;
    if (call == null || _host.pageUp || !_host.collapsed) return;
    _host.expanding();
    try {
      await pushVoiceCallPage(
        context,
        call: call,
        title: _host.title,
        onCollapse: _host.collapse,
        backdrop: _host.backdrop,
      );
    } finally {
      _host.pageDown();
    }
  }

  void _onHost() {
    if (!mounted) return;
    if (_host.call == null) {
      _stopSnap();
      _cardOffset.value = Offset.zero;
      // 通话没了就把原生标志一起清掉：留着它，下一次在对话页按返回
      // 会被当成「还在通话」而缩进小窗。
      unawaited(setCallActive(false));
    }
    // The call, its shape, or its status changed: redraw (what shows — the
    // card, its status, her small window — is decided in build).
    setState(() {});
    final call = _host.call;
    if (call == null) return;
    // 挂断或出错发生在收起时：把页面推回来，让人读到原因——和收起前一样。
    if (call.phase == CallPhase.ended && _host.collapsed && !_host.pageUp) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final now = _host.call;
        if (now == call && call.phase == CallPhase.ended && _host.collapsed && !_host.pageUp) {
          unawaited(_expand(context));
        }
      });
    }
  }

  /// 收起状态按返回：进画中画，而不是让系统把 App 裸送进后台（麦克风会
  /// 被掐、回来后每一句都发不出去）。小窗用不了就退回通话页。
  Future<void> _leaveToPip(BuildContext context) async {
    final call = _host.call;
    // 没有活通话就绝不能进小窗：哪怕 PopScope 因为状态残留误拦了一次返回。
    if (call == null || call.phase == CallPhase.ended) return;
    // 挂着的弹层（背景设置那种）在 root Navigator 上，比小窗那层还高：
    // 不收掉它，小窗里就会跟它一起被画出来。返回键这条路也得收。
    final root = Navigator.of(context, rootNavigator: true);
    if (root.canPop()) {
      final page = ModalRoute.of(context);
      var closed = false;
      if (page != null) {
        root.popUntil((r) {
          if (identical(r, page)) return true;
          closed = true;
          return false;
        });
      }
      if (closed) await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final entered = await enterPictureInPicture();
    if (entered || !context.mounted) return;
    if (_host.collapsed && !_host.pageUp) await _expand(context);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: pictureInPictureMode,
      builder: (context, pip, _) {
        final call = _host.call;
        final liveCall = call != null && call.phase != CallPhase.ended;
        final collapsed = _host.collapsed && !_host.pageUp;
        final small = pip && collapsed && liveCall;
        // 恒定结构：PopScope → Stack → [页面, 覆盖层]。状态切换只改属性，
        // 下面的页面树永远不卸载。发起通话的聊天页持有会话绑定，拆了它，
        // 回来后每一句都「没发出去，再说一次」。
        return PopScope(
          // 只有「确实有活通话、而且收起了」才拦返回交给画中画。
          // 没有通话时按返回就是正常退后台，别把人塞进小窗。
          canPop: !collapsed || !liveCall,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_leaveToPip(context));
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Offstage(offstage: small, child: widget.child),
              if (small)
                Positioned.fill(
                  // Consumer + watch：底片和视觉都是设置项，进小窗前改过，
                  // 小窗也得是新的。
                  child: Consumer(
                    builder: (_, ref, _) {
                      final settings = ref.watch(callSettingsProvider);
                      final theme = Theme.of(context);
                      final picture = settings.backdrop == CallBackdrop.image && settings.image.isNotEmpty;
                      final her = settings.backdrop == CallBackdrop.companion;
                      // 只要有底片就按深色走：海是 #10265A→#02050D 那片深蓝，
                      // 图片和她更不用说。只有完全没有底片（纯色场）时才跟主题。
                      final hasBackdrop = settings.backdrop == CallBackdrop.sea || picture || her;
                      return callPipView(
                        l10n: context.l10n,
                        theme: theme,
                        call: call,
                        // 和整页同一个视觉设置：光球 / 光环 / 细线，一一对上。
                        visual: settings.visual,
                        // 和通话页同一张底，铺在光球下面。
                        backdrop: callCardBackdrop(
                          backdrop: settings.backdrop,
                          image: settings.image,
                          her: her,
                        ),
                        // 有底片的画面一律浅色字，否则深蓝底上的深色状态字看不见。
                        dark: theme.brightness == Brightness.dark || hasBackdrop,
                      );
                    },
                  ),
                )
              else if (collapsed && call != null)
                ValueListenableBuilder<Offset>(
                  valueListenable: _cardOffset,
                  // 布局位置真的跟着拖，命中区域也跟着走。用 Transform 只挪
                  // 绘制、不挪布局盒子，卡片拖走后按钮就点不到了。
                  builder: (_, offset, child) => Positioned(
                    left: (MediaQuery.sizeOf(context).width - CollapsedCallCard.width) / 2 + offset.dx,
                    width: CollapsedCallCard.width,
                    bottom: 20 - offset.dy,
                    child: child!,
                  ),
                  // 卡片是纯色白卡（和以前一样），不吃底片；外面这层 child
                  // 是缓存的，拖动时只重排位置。
                  child: RepaintBoundary(child: _card(context, call)),
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        );
      },
    );
  }

  /// The card and its drag. The pan drives a ValueNotifier that only rebuilds
  /// the transform: the buttons and the recognizer under it are cached, so a
  /// drag never dies halfway (the old "拖一下就卡住" was the recognizer being
  /// rebuilt with the whole tree). 松手时 [_settle] 把卡片收回屏内：
  /// 让它停在屏幕外，下一根手指就既拖不到也点不到按钮。
  Widget _card(BuildContext context, VoiceCallController call) {
    final container = ProviderScope.containerOf(context, listen: false);
    final size = MediaQuery.sizeOf(context);
    return GestureDetector(
      // Pan and the buttons' taps compete in the same arena: a tap wins a
      // press, a drag wins a move. Cached by the notifier above, so the
      // recognizer is never rebuilt under an active drag.
      onPanStart: (_) => _stopSnap(),
      onPanUpdate: (details) =>
          _cardOffset.value = _clampDrag(_cardOffset.value + details.delta, size),
      onPanEnd: (_) => _settle(size),
      onPanCancel: () => _settle(size),
      child: CollapsedCallCard(
        status: callStatus(context.l10n, call, signedIn: () => container.read(accountProvider).signedIn).$1,
        ended: call.phase == CallPhase.ended,
        l10n: context.l10n,
        theme: Theme.of(context),
        muted: call.muted,
        onMute: () => call.setMuted(!call.muted),
        onExpand: () => unawaited(_expand(context)),
        onPip: enterPictureInPicture,
        onHangUp: () {
          HapticFeedback.heavyImpact();
          call.hangUp();
        },
      ),
    );
  }
}
