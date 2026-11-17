// 语音通话的宿主：通话在页面之外。
//
// 收起这件事，路由做不到（test/speech/collapsed_card_hit_test.dart 钉死的结论：
// 只要通话页是 push 上去的一条路由，收起后下面的页面就一定点不到——透明只是
// 看得见，不是摸得到）。所以把 [VoiceCallController] 从页面里拿出来：
//
//   openChatCall → host.openCall（造控制器、启动、push 页面）
//   收起        → host.collapse：pop 掉全屏路由，卡片挂到 RootGate 的
//                 [CallCardLayer] 上；通话不动
//   点卡片      → host.expand：重新 push 页面，复用同一个控制器
//   通话结束    → 页面收尾（或收起时由卡片弹回页面让人读到原因），
//                 最后 host.close 清干净（原生标志、聊天会话、surface）
//
// 控制器归宿主，页面只是视图；页面来去，通话不中断。设置的改动
// （声音、识别、停顿）用 container.listen 挂在宿主上——收起时页面没了，
// 这些监听也得活着。
//
// 宿主是单例 [ChangeNotifier] 而不是 provider：页面不从 provider 读控制器
// （上一课：页面一旦从 provider 读，测试里没挂载就全崩），openChatCall 造好
// 交给它，卡片和页面各拿各的。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_voice.dart' show speechSpeakerProvider;
import '../companion/companion_voice_source.dart';
import '../l10n/l10n.dart';
import '../speech/call/thinking_cue.dart';
import '../speech/call/voice_call.dart';
import '../speech/deepseek_speech.dart';
import '../speech/speech_audio.dart';
import '../speech/speech_out.dart';
import '../speech/speech_settings.dart';
import '../speech/voice_cloud.dart';
import '../state/account_state.dart';
import '../state/app_notes.dart';
import '../state/call_surface_state.dart';
import '../state/notify_state.dart';
import '../state/picture_in_picture.dart';
import '../state/voice_settings.dart';
import '../state/voice_state.dart' show voiceBridgeProvider;
import '../ui/chat/voice/voice_bridge.dart' show VoicePermission;
import '../ui/speech/voice_call_page.dart'
    show CollapsedCallCard, callPipView, callStatus, pushVoiceCallPage;

/// The call out of any page: [openChatCall] makes the controller and hands it
/// here; the page shows it; 收起 pops the page and the card takes over.
class VoiceCallHost extends ChangeNotifier {
  VoiceCallHost._();

  /// One call at a time, app-wide.
  static final VoiceCallHost instance = VoiceCallHost._();

  VoiceCallController? _call;
  CallVoiceBook? _book;
  ProviderContainer? _container;
  List<ProviderSubscription> _subs = const [];
  String _title = '';
  bool _collapsed = false;
  bool _pageUp = false;
  Timer? _closeTimer;

  /// The last state relayed to the card (the microphone level's stream of
  /// changes stays off this notifier; call_surface_state.dart §「只有 surface
  /// 是全局的」).
  CallPhase _phase = CallPhase.starting;
  bool _muted = false;

  /// The live call, if one is up (shown, shrunk to the card, or winding down).
  VoiceCallController? get call => _call;

  /// Heads the call page and the card.
  String get title => _title;

  /// The page is gone; the card carries the call.
  bool get collapsed => _collapsed;

  /// A call page route is up.
  bool get pageUp => _pageUp;

  /// Opens a call: the controller is made here (its settings and its voice
  /// wired to the container, not to any page) and started before the page is
  /// pushed, so the call outlives the page. [push] shows the page over
  /// whatever is open.
  Future<void> openCall({
    required ProviderContainer container,
    required String title,
    required CallConversation conversation,
    required Future<void> Function() push,
  }) async {
    _container = container;
    _title = title;
    final book = _book = CallVoiceBook(container);
    final made = makeChatCallController(container, conversation, book);
    _call = made;
    _collapsed = false;
    _phase = made.phase;
    _muted = made.muted;
    made.addListener(_onCall);
    container.read(callSurfaceProvider.notifier).set(CallSurface.full);
    // The channel is watched for the whole call, not for a page: 收起 pops
    // the page, and the card still has to hear pictureInPictureChanged.
    watchPictureInPicture();
    // 设置的改动全程都听：收起时页面没了，这些监听也得活着。
    _subs = [
      container.listen(speechVoiceSettingsProvider, (_, _) => unawaited(book.settle())),
      container.listen(voiceSettingsProvider, (_, _) => unawaited(made.refreshRecognizer())),
      container.listen(cloudAsrProvider, (_, _) => unawaited(made.refreshRecognizer())),
      container.listen(callSettingsProvider.select((s) => s.pause), (_, pause) => made.setPause(pause)),
    ];
    notifyListeners();
    unawaited(made.start());
    _pageUp = true;
    try {
      await push();
    } finally {
      pageDown();
    }
  }

  /// 收起 (the page's route pops itself right after): the card takes over on
  /// the RootGate and the call carries on.
  void collapse(BuildContext pageContext) {
    if (_call == null) return;
    _collapsed = true;
    _container?.read(callSurfaceProvider.notifier).set(CallSurface.expanded);
    notifyListeners();
    Navigator.of(pageContext).pop();
  }

  /// The card was tapped: the page again, over whatever is open now; the call
  /// was never gone.
  Future<void> expand(BuildContext context) async {
    final call = _call;
    if (call == null || _pageUp || !_collapsed) return;
    _collapsed = false;
    _pageUp = true;
    _container?.read(callSurfaceProvider.notifier).set(CallSurface.full);
    notifyListeners();
    try {
      await pushVoiceCallPage(context, call: call, title: _title, onCollapse: collapse);
    } finally {
      pageDown();
    }
  }

  /// The page's route went away. A call still live goes on (that was 收起);
  /// an ended one is closed out a moment later, when its reason has been read.
  void pageDown() {
    _pageUp = false;
    final call = _call;
    if (call != null && call.phase == CallPhase.ended) {
      _closeTimer ??= Timer(const Duration(milliseconds: 380), close);
    }
    notifyListeners();
  }

  void _onCall() {
    final call = _call;
    if (call == null) return;
    // The card shows the phase and the mute, not the microphone level.
    if (call.phase == _phase && call.muted == _muted) return;
    _phase = call.phase;
    _muted = call.muted;
    if (call.phase == CallPhase.ended && !_pageUp) {
      // Ended while shrunk: [CallCardLayer] pops the page back up so the
      // reason can be read; pageDown then closes everything out.
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  /// The call is over and nobody shows it: everything down, the way the page
  /// itself used to leave it (the native flags, the chat target, the surface).
  void close() {
    final call = _call;
    if (call == null) return;
    _closeTimer?.cancel();
    _closeTimer = null;
    _book?.close();
    _book = null;
    for (final sub in _subs) {
      sub.close();
    }
    _subs = const [];
    _call = null;
    _collapsed = false;
    _pageUp = false;
    call.removeListener(_onCall);
    stopWatchingPictureInPicture();
    unawaited(setCallActive(false));
    unawaited(setCallScreen(false));
    call.dispose();
    final container = _container;
    _container = null;
    if (container != null) {
      container.read(callChatProvider.notifier).set(null);
      container.read(callSurfaceProvider.notifier).set(CallSurface.none);
    }
    notifyListeners();
  }

  /// Tests: drop everything without touching a container that may already be
  /// gone.
  @visibleForTesting
  void reset() {
    final call = _call;
    _closeTimer?.cancel();
    _closeTimer = null;
    _book?.close();
    _book = null;
    stopWatchingPictureInPicture();
    for (final sub in _subs) {
      sub.close();
    }
    _subs = const [];
    _call = null;
    _container = null;
    _collapsed = false;
    _pageUp = false;
    if (call != null) {
      call.removeListener(_onCall);
      call.dispose();
    }
    notifyListeners();
  }
}

/// A chat call's controller, its wires read once from the container — the same
/// ones the page used to make itself (voice, recognition, choices, permission),
/// but owned by nobody's widget tree.
VoiceCallController makeChatCallController(
  ProviderContainer container,
  CallConversation conversation,
  CallVoiceBook book,
) {
  VoiceCallController? made;
  final audio = container.read(speechAudioProvider);
  final deepseek = container.read(deepSeekSpeechProvider);
  final bridge = container.read(voiceBridgeProvider);
  final speaker = container.read(speechSpeakerProvider);
  made = VoiceCallController(
    audio: audio,
    conversation: conversation,
    recognizer: () async {
      // The phone's own voice warms up while the call starts, not when
      // changed mid-reply.
      await book.settle(warm: made!.phase == CallPhase.starting);
      return container.read(callRecognizerProvider)();
    },
    voice: () => speechOutFor(
      book.current,
      deepseek: deepseek,
      audio: audio,
      speaker: speaker,
      call: true,
      levels: true,
      gap: container.read(deepSeekSpeechGapProvider),
    ),
    // The saved ones, not the defaults shown while they load (a first call
    // after launch).
    choices: () async {
      final saved = await container.read(callSettingsProvider.notifier).ready();
      return (
        bargeIn: saved.bargeIn,
        speaker: saved.speaker,
        spokenHint: saved.spoken ? appNote(appL10n.speechCallHint) : null,
        pause: saved.pause,
      );
    },
    permission: () async => await bridge.requestPermission() == VoicePermission.granted,
    cutNote: (heard) => appNote(heard.isEmpty ? appL10n.speechCallCutEarly : appL10n.speechCallCutNote(heard)),
    thinkingCue: () async {
      // Asked again after the settings: her voice may have begun meanwhile.
      if ((await container.read(callSettingsProvider.notifier).ready()).cue && made!.cueStill) {
        await playThinkingCue(audio);
      }
    },
  );
  return made;
}

/// Her voice for the next reply, kept as the settings change (the hosted
/// counterpart of the page's own voice book).
class CallVoiceBook {
  CallVoiceBook(this._container)
    : current = _container.read(speechVoiceSettingsProvider) ?? _container.read(speechVoiceSettingsProvider.notifier).defaults;

  final ProviderContainer _container;
  CompanionVoiceSettings current;
  int _settling = 0;
  bool _closed = false;

  void close() => _closed = true;

  /// [_voice] from the settings: DeepSeek's with nobody to pay for it here
  /// becomes the phone's own; the phone's own warms up.
  Future<void> settle({bool warm = false}) async {
    final mine = ++_settling;
    var next = await _container.read(speechVoiceSettingsProvider.notifier).ready();
    if (_closed || mine != _settling) return;
    if (next.source == CompanionVoiceSource.deepseek) {
      final speech = await _container.read(deepSeekSpeechProvider)();
      if (speech == null) {
        next = next.copyWith(source: CompanionVoiceSource.system);
      } else {
        speech.close();
      }
    }
    // A later choice has the last word, whichever answer comes back first.
    if (_closed || mine != _settling) return;
    // Setting the speaker up would cut a reply it is reading: that only as the
    // call starts; a change later only starts the phone's engine, and takes
    // effect with the next reply.
    if (next.source != CompanionVoiceSource.deepseek) {
      final speaker = _container.read(speechSpeakerProvider);
      unawaited(warm ? speaker.ready(next) : speaker.warmPhone());
    }
    current = next;
  }
}

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
  }

  @override
  void dispose() {
    _stopSnap();
    _snap.dispose();
    _host.removeListener(_onHost);
    _cardOffset.dispose();
    super.dispose();
  }

  /// Positioned 同时给 left/right：卡片的宽度恒为屏幕宽减去 2×[_cardInset]。
  /// 它不是能到处跑的小浮窗，是一条横贯屏幕的横幅。
  static const double _cardInset = 16;
  static const double _screenMargin = 8;
  static const double _dragGive = 24;

  /// 松手后必须停住的范围。left = inset + dx、right = inset - dx，
  /// 两边都要留 [_screenMargin]，所以 dx 只剩 ±(inset - margin)。
  /// 真正能大幅挪动的是上下（让开输入框和正文），不是左右。
  Offset _clampRest(Offset offset, Size size) {
    final side = math.max(0.0, _cardInset - _screenMargin);
    final up = math.max(0.0, size.height - 96);
    return Offset(
      offset.dx.clamp(-side, side).toDouble(),
      offset.dy.clamp(-up, 20.0).toDouble(),
    );
  }

  /// 按住时多给一点弹性，手上有跟手的反馈；但只多 [_dragGive]，
  /// 不再按「屏幕宽/2 - 40」放行 —— 那个半径会把整条卡片推出屏幕。
  Offset _clampDrag(Offset offset, Size size) {
    final rest = _clampRest(offset, size);
    final side = math.max(0.0, _cardInset - _screenMargin) + _dragGive;
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

  void _onHost() {
    if (!mounted) return;
    if (_host.call == null) {
      _stopSnap();
      _cardOffset.value = Offset.zero;
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
          unawaited(_host.expand(context));
        }
      });
    }
  }

  /// 收起状态按返回：进画中画，而不是让系统把 App 裸送进后台（麦克风会
  /// 被掐、回来后每一句都发不出去）。小窗用不了就退回通话页。
  Future<void> _leaveToPip(BuildContext context) async {
    final entered = await enterPictureInPicture();
    if (entered || !context.mounted) return;
    if (_host.collapsed && !_host.pageUp) await _host.expand(context);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: pictureInPictureMode,
      builder: (context, pip, _) {
        final call = _host.call;
        final collapsed = _host.collapsed && !_host.pageUp;
        final small = pip && collapsed && call != null;
        // 恒定结构：PopScope → Stack → [页面, 覆盖层]。状态切换只改属性，
        // 下面的页面树永远不卸载。发起通话的聊天页持有会话绑定，拆了它，
        // 回来后每一句都「没发出去，再说一次」。
        return PopScope(
          // 收起状态按返回不退出 App：交给画中画，通话继续。
          canPop: !collapsed,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_leaveToPip(context));
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Offstage(offstage: small, child: widget.child),
              if (small)
                Positioned.fill(child: callPipView(l10n: context.l10n, theme: Theme.of(context), call: call))
              else if (collapsed && call != null)
                ValueListenableBuilder<Offset>(
                  valueListenable: _cardOffset,
                  // 布局位置真的跟着拖，命中区域也跟着走。用 Transform 只挪
                  // 绘制、不挪布局盒子，卡片拖走后按钮就点不到了。
                  builder: (_, offset, child) => Positioned(
                    left: _cardInset + offset.dx,
                    right: _cardInset - offset.dx,
                    bottom: 20 - offset.dy,
                    child: child!,
                  ),
                  child: RepaintBoundary(
                    child: Align(alignment: Alignment.center, child: _card(context, call)),
                  ),
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
        onExpand: () => unawaited(_host.expand(context)),
        onPip: enterPictureInPicture,
        onHangUp: () {
          HapticFeedback.heavyImpact();
          call.hangUp();
        },
      ),
    );
  }
}
