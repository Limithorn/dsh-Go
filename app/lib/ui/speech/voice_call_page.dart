// 语音通话: one page over the conversation, lit like Siri but quieter: a
// sphere of clear glass with soft colour drifting inside, the same colour
// running faintly round the screen's edge, all of it made from the theme's
// colour and following its light or dark (call/call_visuals.dart). Behind it a dark field, the person's own picture,
// or 伙伴小屋's character mouthing the reply (call/call_backdrop.dart). What was
// heard and what she says arrive underneath; mute, hang up and loudspeaker sit
// at the bottom; an approval or question the conversation waits on comes up
// above them and is answered right here.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_call.dart';
import '../../companion/companion_state.dart' show companionSessionsProvider;
import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../../performance/performance_state.dart';
import '../../speech/call/chat_call.dart';
import '../../speech/call/thinking_cue.dart';
import '../../speech/call/voice_call.dart';
import '../../speech/deepseek_speech.dart';
import '../../speech/read_aloud.dart';
import '../../speech/speech_audio.dart';
import '../../speech/speech_out.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voice_cloud.dart';
import '../../state/account_state.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
import '../../state/app_notes.dart';
import '../../state/picture_in_picture.dart';
import '../../state/streaming_asr_state.dart';
import '../../state/streaming_pcm_state.dart';
import '../../state/voice_call_host.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../chat/voice/voice_bridge.dart';
import '../companion/companion_ask.dart';
import '../companion/companion_stage.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../../usage/usage_stats.dart';
import '../../voice/live_words.dart';
import '../../voice/live_words_model.dart';
import '../../voice/streaming_pcm.dart';
import 'call/call_backdrop.dart';
import 'call/call_card.dart';
import 'call/call_parts.dart';
import 'call/call_pip.dart';
import 'call/call_transcript.dart';
import 'call/call_visuals.dart';
import 'speech_ui.dart';

/// Opens a call with the main chat's conversation. [session] gives its id,
/// creating it for a new chat; [title] heads the page. [conversation] stands
/// in for the real one in tests.
///
/// The call lives in the host (state/voice_call_host.dart), not in the page:
/// 收起 pops the route and the card takes over; this page is only the view.
Future<void> openChatCall(
  BuildContext context, {
  required String title,
  required Future<String?> Function() session,
  CallConversation? conversation,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final host = VoiceCallHost.instance;
  if (host.call != null) {
    // 已在通话里：不另开一通，把页面带回来。
    await reexpandHostedCall(context);
    return;
  }
  container.read(readAloudProvider.notifier).stop();
  await host.openCall(
    container: container,
    title: title,
    conversation: conversation ?? ChatCallConversation(container, session),
    push: () => pushVoiceCallPage(context, call: host.call!, title: title, onCollapse: host.collapse),
  );
}

/// 已有通话收着（卡片或小窗里）：把整页带回来，复用宿主里同一个控制器。
/// 宿主只搬状态（[VoiceCallHost.expanding]），这条路由在这里推、收起时
/// 由谁展开就由谁负责——见 call_card_layer.dart 的同款装配。
Future<void> reexpandHostedCall(BuildContext context) async {
  final host = VoiceCallHost.instance;
  final call = host.call;
  if (call == null || host.pageUp || !host.collapsed) return;
  host.expanding();
  try {
    await pushVoiceCallPage(
      context,
      call: call,
      title: host.title,
      onCollapse: host.collapse,
      backdrop: host.backdrop,
    );
  } finally {
    host.pageDown();
  }
}

/// Opens a call with [conversation]; [backdrop] is the picture behind it
/// whatever the call settings say (her room's call shows her).
/// 走 host 托管，收起/PiP 与聊天通话一致。
Future<void> openVoiceCall(
  BuildContext context, {
  required String title,
  required CallConversation conversation,
  CallBackdrop? backdrop,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final host = VoiceCallHost.instance;
  if (host.call != null) {
    await reexpandHostedCall(context);
    return;
  }
  container.read(readAloudProvider.notifier).stop();
  await host.openCall(
    container: container,
    title: title,
    conversation: conversation,
    backdrop: backdrop,
    push: () => pushVoiceCallPage(
      context,
      call: host.call!,
      title: title,
      onCollapse: host.collapse,
      backdrop: backdrop,
    ),
  );
}

/// The call page as one route: transparent, without a barrier (a barrier on a
/// transparent route eats the whole screen's touches), rising out of the dark.
/// [call] is the controller the page shows — the host (state/voice_call_host.dart)
/// makes it before pushing, so 收起 can pop this route and push it back with
/// the same call; [onCollapse] tells the host the page is going away for 收起.
// fork(call): 宿主架构的推页入口；收起/展开复用同一控制器。
Future<void> pushVoiceCallPage(
  BuildContext context, {
  required VoiceCallController call,
  required String title,
  void Function(BuildContext pageContext)? onCollapse,
  CallBackdrop? backdrop,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      barrierDismissible: false,
      opaque: false,
      fullscreenDialog: true,
      transitionDuration: AppMotion.of(context, const Duration(milliseconds: 520)),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.collapse),
      pageBuilder: (_, _, _) => VoiceCallPage(
        title: title,
        conversation: call.conversation,
        controller: call,
        onCollapse: onCollapse,
        backdrop: backdrop,
      ),
      transitionsBuilder: (_, animation, _, child) {
        final curve = CurvedAnimation(parent: animation, curve: AppMotion.enter, reverseCurve: AppMotion.exit);
        // Opening: the page rises out of the dark.
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(curve), child: child),
        );
      },
    ),
  );
}

class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({
    super.key,
    required this.title,
    required this.conversation,
    this.controller,
    this.onCollapse,
    this.backdrop,
  });

  final String title;
  final CallConversation conversation;

  /// The call this page shows. Given when [openChatCall] pushes it: the call
  /// lives in the host (state/voice_call_host.dart), out of any page, so 收起
  /// can pop this route and the call carries on. Without one the page makes
  /// its own — a page that owns its call (tests) folds itself into a card
  /// instead of popping.
  final VoiceCallController? controller;

  /// 收起 for a hosted call: tell the host (its card takes over) and pop this
  /// route. Null (the page owns the call): the page only folds itself.
  final void Function(BuildContext pageContext)? onCollapse;

  /// The picture behind the call instead of the one in the call settings.
  /// Her room's call passes her own backdrop so it shows her.
  final CallBackdrop? backdrop;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final VoiceCallController _call;

  /// The page made its own controller (no [VoiceCallPage.controller] given)
  /// and ends it by going away.
  bool _mine = false;

  /// The hosted call is being 收起: this route is popping, the call stays.
  bool _collapsing = false;

  final _scene = CallScene();
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? _leave;

  /// The clock counts from when the call began listening, which the call
  /// itself keeps: 收起 pops this page, and 展开 pushes a new one that must
  /// carry on from the same moment rather than start at --:--.
  DateTime? get _since => _call.startedAt;

  /// The first 在听 of this call has already been taken: its touch and its
  /// one count per call happen once, even if the page is pushed again.
  bool _rang = false;
  CallPhase _shown = CallPhase.starting;
  void Function(UsageOutcome, {UsageOperation? actual})? _callConnect;
  void Function(UsageOutcome, {UsageOperation? actual})? _callSession;

  /// What [build] shows of the call. Not the audio levels: the light reads those
  /// itself each frame, so they alone (some 25 updates a second) leave the page
  /// as it is (voice_call_page_test pins this).
  Object _shows() => (
    _call.phase,
    _call.ended,
    _call.muted,
    _call.speaker,
    _call.heard,
    _call.caption,
    _call.error,
    _call.turns.isEmpty,
    _call.ended == CallEnd.noRecognizer && ref.read(accountProvider).signedIn,
    switch (widget.conversation) {
      final ChatCallConversation chat => chat.sessionId,
      final CompanionCallConversation room => room.sessionId,
      _ => null,
    },
  );

  /// [_shows] as of the last build.
  Object? _built;

  // Her, when she is the backdrop.
  final _stage = CompanionStageController();
  bool _stageReady = false;
  bool _stageFailed = false;
  String? _imageChecked;
  bool _imageExists = false;
  double _mouthAt = 0;
  bool _mouthOpen = false;

  /// A finger on the light: it gives a little.
  bool _pressed = false;

  /// 收起: the call as one card. A hosted call pops this route instead and the
  /// host's card shows (CallCardLayer); this fold is only for a page that owns
  /// its call, and the page stays alive, so the microphone and the turn under
  /// way carry on.
  bool _collapsed = false;

  /// The system asks for less motion (read each build): the light holds still
  /// and the page comes in without its staggered rise.
  bool _still = false;

  @override
  void initState() {
    super.initState();
    _mine = widget.controller == null;
    WidgetsBinding.instance.addObserver(this);
    // fork(call): 通话期间告诉原生：按 home 不要退到后台，直接缩成小窗，麦克风才不被挖。
    unawaited(setCallActive(true));
    unawaited(setCallScreen(true));
    // A hosted call keeps the channel watched by its host: 收起 pops this
    // page, and its dispose must not take the picture-in-picture events away.
    if (_mine) watchPictureInPicture();
    pictureInPictureMode.addListener(_onPipChanged);
    if (_mine) {
      final callSettings = ref.read(callSettingsProvider.notifier);
      final voices = ref.read(speechVoiceSettingsProvider.notifier);
      // The chosen voice, as soon as the settings have been read (the first reply comes later).
      _voice = ref.read(speechVoiceSettingsProvider) ?? voices.defaults;
      final speaker = ref.read(speechSpeakerProvider);
      final audio = ref.read(speechAudioProvider);
      final deepseek = ref.read(deepSeekSpeechProvider);
      final bridge = ref.read(voiceBridgeProvider);
      _call = VoiceCallController(
        audio: audio,
        conversation: widget.conversation,
        verbatimInput: switch (widget.conversation) {
          final CompanionCallConversation room => room.fullMode,
          _ => null,
        },
        recognizer: () async {
          // The phone's own voice warms up while the call starts, not when changed mid-reply.
          await _settleVoice(warm: _call.phase == CallPhase.starting);
          if (!mounted) return null;
          return ref.read(callRecognizerProvider)();
        },
        voice: () => speechOutFor(
          _voice,
          deepseek: deepseek,
          audio: audio,
          speaker: speaker,
          call: true,
          levels: true,
          gap: ref.read(deepSeekSpeechGapProvider),
        ),
        // The saved ones, not the defaults shown while they load (a first call after launch).
        choices: () async {
          final saved = await callSettings.ready();
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
          if ((await callSettings.ready()).cue && _call.cueStill) await playThinkingCue(audio);
        },
      )..addListener(_changed);
      // Changed in 通话设置 (or anywhere) during the call: from the next sentence on.
      ref.listenManual(speechVoiceSettingsProvider, (_, _) => unawaited(_settleVoice()));
      ref.listenManual(voiceSettingsProvider, (_, _) => unawaited(_call.refreshRecognizer()));
      ref.listenManual(cloudAsrProvider, (_, _) => unawaited(_call.refreshRecognizer()));
      ref.listenManual(callSettingsProvider.select((s) => s.pause), (_, pause) => _call.setPause(pause));
    } else {
      // The host's call: the settings are listened there (they must outlive
      // this page — 收起 pops it); here the page is only the view.
      _call = widget.controller!;
      _call.addListener(_changed);
      // An ended call pushed back (it ended while 收起): the reason shows a
      // moment, then the route goes as usual.
      if (_call.phase == CallPhase.ended) _scheduleLeave();
    }
    _shown = _call.phase;
    _rang = _call.startedAt != null;
    HapticFeedback.mediumImpact();
    _enter.forward();
    unawaited(_start(start: _mine));
  }

  /// Live captions, once the call listens, when the streaming model is on the phone.
  LiveWords? _live;

  /// Her voice for the next reply.
  late CompanionVoiceSettings _voice;

  /// The hosted call is already started (the host did, before pushing): only
  /// the live captions are set up here.
  Future<void> _start({bool start = true}) async {
    final pcm = ref.read(streamingPcmCaptureProvider);
    final asr = ref.read(streamingAsrProvider);
    final found = liveWordsModel(ref);
    _callConnect = ref.read(usageStatsProvider.notifier).beginOperation(UsageOperation.callConnect);
    if (start) await _call.start();
    try {
      final chosen = await found;
      if (chosen == null || !mounted || _call.phase == CallPhase.ended) return;
      final live = _live = LiveWords(
        pcm,
        asr,
        chosen.model,
        StreamingPcmSource.call,
        _call.live,
        trial: chosen.trial,
        // Captions that stop mid-call leave the call itself going.
        onFailure: (_) => _live = null,
      );
      await live.start();
    } on Object {
      // Without live captions the call goes on as before.
      _live = null;
    }
  }

  /// [_voice] from the settings: DeepSeek's with nobody to pay for it here
  /// becomes the phone's own; the phone's own warms up.
  Future<void> _settleVoice({bool warm = false}) async {
    final mine = ++_settling;
    var next = await ref.read(speechVoiceSettingsProvider.notifier).ready();
    if (!mounted) return;
    if (next.source == CompanionVoiceSource.deepseek) {
      final speech = await ref.read(deepSeekSpeechProvider)();
      if (speech == null) {
        next = next.copyWith(source: CompanionVoiceSource.system);
      } else {
        speech.close();
      }
    }
    // A later choice has the last word, whichever answer comes back first.
    if (!mounted || mine != _settling) return;
    // Setting the speaker up would cut a reply it is reading: that only as the
    // call starts; a change later only starts the phone's engine, and takes
    // effect with the next reply.
    if (next.source != CompanionVoiceSource.deepseek) {
      final speaker = ref.read(speechSpeakerProvider);
      unawaited(warm ? speaker.ready(next) : speaker.warmPhone());
    }
    _voice = next;
  }

  int _settling = 0;

  void _changed() {
    if (!mounted) return;
    final phase = _call.phase;
    // 上游的用量统计（接通/挂断时上报）和我们的"收起态挂断要展开"互不
    // 矛盾，两段都留：前者结束一通电话的记账，后者保证用户能看到挂断原因。
    // Listening only proves the microphone opened. A received assistant
    // reply proves the call's conversation path actually worked.
    if (_callConnect != null && phase == CallPhase.speaking) {
      _callConnect?.call(UsageOutcome.ready);
      _callConnect = null;
      _callSession = ref.read(usageStatsProvider.notifier).beginOperation(UsageOperation.callSession);
    }
    if (phase == CallPhase.ended) {
      final why = _call.ended;
      _callConnect?.call(switch (why) {
        CallEnd.permission || CallEnd.microphone || CallEnd.noRecognizer || CallEnd.failed => UsageOutcome.failed,
        _ => UsageOutcome.unknown,
      });
      _callConnect = null;
      _callSession?.call(why == CallEnd.failed ? UsageOutcome.failed : UsageOutcome.ready);
      _callSession = null;
    }
    // Hung up while shrunk: open up again so the reason can be read.
    if (phase == CallPhase.ended && _collapsed) _collapsed = false;
    if (phase != _shown) {
      _arrived(phase);
      _shown = phase;
    }
    if (phase == CallPhase.ended) _scheduleLeave();
    // The microphone's levels alone leave the page as it was built: the light
    // reads them itself each frame (see [_shows]).
    if (_shows() != _built) setState(() {});
  }

  /// The call has ended while its page is up: the light sinks away first;
  /// ended for a reason, the reason stays a moment, then the route goes.
  void _scheduleLeave() {
    _leave ??= Timer(
      _call.ended == CallEnd.hungUp ? const Duration(milliseconds: 380) : const Duration(milliseconds: 2600),
      () {
        if (!mounted) return;
        // The call page itself, not a sheet open over it (字幕, 背景).
        final route = ModalRoute.of(context);
        // Already left (Back just before this): nothing of anyone else's is closed.
        if (route == null || !route.isActive) return;
        final navigator = Navigator.of(context);
        if (!route.isCurrent) navigator.popUntil((r) => r == route);
        unawaited(navigator.maybePop());
      },
    );
  }

  /// A new phase: a touch under the finger, and her mood when she is there.
  void _arrived(CallPhase phase) {
    switch (phase) {
      case CallPhase.listening when !_rang:
        _rang = true;
        HapticFeedback.lightImpact();
        // Anonymous usage statistics: a call got through (the microphone is on).
        ref.read(usageStatsProvider.notifier).count(UsageCount.call);
      case CallPhase.hearing:
        HapticFeedback.selectionClick();
      case CallPhase.speaking:
        HapticFeedback.lightImpact();
      case CallPhase.ended:
        HapticFeedback.mediumImpact();
      default:
        break;
    }
    if (_stageReady) {
      _stage.command('mood', {
        'mood': switch (phase) {
          CallPhase.thinking || CallPhase.starting => 'thinking',
          CallPhase.speaking => 'speaking',
          CallPhase.ended => 'idle',
          _ => 'listening',
        },
      });
      if (phase != CallPhase.speaking) _stage.command('quiet');
    }
  }

  /// 缩成系统窗口（画中画），通话继续，人可以去做别的事。
  Future<void> _enterPip() async {
    await enterPictureInPicture(dismiss: _closeSheets);
  }

  /// 把挂在这一页上面的弹层（背景设置那种）都收掉，等它们真的走完。
  ///
  /// 那些弹层是 `showModalBottomSheet`，走的是 **root Navigator**——它在
  /// [CallCardLayer] 外面，比小窗那一层还高。小窗只画 CallCardLayer，管不到
  /// 它，所以不收掉就会一起被画进小窗（"小窗里怎么是设置页"就是这么来的）。
  /// 一定要用 rootNavigatorOf，用普通的 Navigator.of 找的是页面自己那层，
  /// 根本看不见弹层。
  Future<void> _closeSheets() async {
    if (!mounted) return;
    final root = Navigator.of(context, rootNavigator: true);
    if (!root.canPop()) return;
    // 弹到这一页为止：这页之上的（弹层）都收掉，下面的（对话页）不动。
    final route = ModalRoute.of(context);
    if (route == null) return;
    var closed = false;
    root.popUntil((r) {
      if (identical(r, route)) return true;
      closed = true;
      return false;
    });
    if (!closed) return;
    // 收下去的动画要走完：不然原生抓到的还是正在消失的那一帧。
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// 收起. A hosted call: tell the host and pop this route — the card takes
  /// over on the RootGate and the call carries on. A page that owns its call
  /// (tests): fold itself into a card in place, as before.
  // fork(call): 整页收起的唯一入口；锁屏场景先问原生（leaveCallToLock）。
  void _collapse() {
    // 锁屏亮屏时整页浮在 keyguard 之上；收起前先让原生判断"现在锁着屏吗"，
    // 是就撤掉 showWhenLocked，keyguard 立刻盖上来——一次返回直接回锁屏，
    // 解锁后看到的是已收起的对话页，而不是先闪一下对话页再按一次才锁屏。
    // 非锁屏时原生什么都不做，照常收成卡片继续聊。
    unawaited(leaveCallToLock());
    if (widget.onCollapse case final hosted?) {
      _collapsing = true;
      hosted(context);
      return;
    }
    setState(() => _collapsed = true);
  }

  /// The call as a card at the bottom, over whatever is below the route (a
  /// page that owns its call and folds itself; a hosted call pops instead and
  /// the host's card shows — CallCardLayer).
  Widget _collapsedCard(L10n l10n, ThemeData theme) {
    final (status, _) = _status(l10n);
    return PopScope(
      // 收起状态按返回：展开回去，而不是把整通电话丢掉。
      // 之前返回键直接 pop 掉通话页，通话就没了，这是用户报的那一条。
      canPop: _call.phase != CallPhase.ended,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _collapsed = false);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 这一层把整个屏幕占住但不收任何指针事件：收起时下面的对话页、输入框
          // 都还要能点。之前用 Align 直接把卡片摆在全屏里，整页看着是空的却把
          // 所有触摸吃掉了——点哪都没反应就是这么来的。
          const IgnorePointer(child: SizedBox.expand()),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: RepaintBoundary(
              child: Align(
                alignment: Alignment.center,
                child: CollapsedCallCard(
                  status: status,
                  ended: _call.phase == CallPhase.ended,
                  l10n: l10n,
                  theme: theme,
                  muted: _call.muted,
                  onMute: () => _call.setMuted(!_call.muted),
                  onExpand: () => setState(() => _collapsed = false),
                  onPip: _enterPip,
                  onHangUp: _hangUp,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _tick(double seconds) {
    _scene.tick(
      seconds,
      phase: _call.phase,
      mic: _call.micLevel,
      voice: _call.voiceLevel,
      isMuted: _call.muted,
      still: _still,
    );
    // Her mouth follows the voice, twenty times a second at most.
    if (_stageReady && seconds - _mouthAt > 0.05) {
      final speaking = _call.phase == CallPhase.speaking;
      final open = speaking ? (_scene.level * 1.3).clamp(0.0, 1.0) : 0.0;
      if (speaking || _mouthOpen) {
        _stage.command('mouth', {'value': open});
        _mouthOpen = open > 0;
        _mouthAt = seconds;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // fork(call): 不再因「切到后台」主动结束通话。
    //
    // 之前锁屏叫醒后一秒就退：锁屏时 Flutter 报 paused，而这里的背景判断
    // 比原生那条「这是锁屏」的消息先到，总是先把通话收了。麦克风在画中画和
    // 锁屏下都还活（前台服务撑着），所以交给系统去决定，不再自己判。
    // 真正不可用时，采集会报 mic_busy，那条路会如实结束。
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pictureInPictureMode.removeListener(_onPipChanged);
    if (_mine) stopWatchingPictureInPicture();
    unawaited(_live?.stop());
    _leave?.cancel();
    _enter.dispose();
    // 页面先走了但记账还没结：按"结果未知"上报，别把一通电话的统计漏掉。
    _callConnect?.call(UsageOutcome.unknown);
    _callSession?.call(UsageOutcome.unknown);
    _call.removeListener(_changed);
    if (_mine) {
      // This page owns the call: it ends by the page going away.
      unawaited(setCallActive(false));
      unawaited(setCallScreen(false));
      _call.dispose();
    } else if (!_collapsing && _call.phase != CallPhase.ended) {
      // fork(call): A hosted call only loses its page by 收起 (which says so
      // first) or by ending; anything else (back on the full page) ends it,
      // as before.
      _call.hangUp();
    }
    _scene.dispose();
    super.dispose();
  }

  void _hangUp() {
    HapticFeedback.heavyImpact();
    _call.hangUp();
  }

  (String, bool) _status(L10n l10n) {
    return callStatus(l10n, _call, signedIn: () => ref.read(accountProvider).signedIn);
  }

  /// The light in the middle: 整页和小窗共用 [CallOrb]（玻璃球 / 声波环），
  /// 都由 [_scene] 每帧驱动 —— 听人说话、她在说、思考时各有自己的节奏。
  Widget _light(CallVisual visual, CallPalette palette, bool dark, double size) => CallOrb(
        key: ValueKey(visual),
        scene: _scene,
        call: _call,
        visual: visual,
        palette: palette,
        dark: dark,
        size: size,
      );

  /// [child] coming in with the page: a fade and a short rise, starting at [from] (0–1).
  Widget _rise(double from, Widget child, {double distance = 18}) {
    if (_still) return child;
    final curve = CurvedAnimation(
      parent: _enter,
      curve: Interval(from, math.min(1, from + 0.5), curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) => Opacity(
        opacity: curve.value,
        child: Transform.translate(offset: Offset(0, (1 - curve.value) * distance), child: child),
      ),
      child: child,
    );
  }

  /// The light, which gives a little under the finger; tapped while she speaks, she skips ahead.
  Widget _lightKey(L10n l10n, String status, CallVisual visual, CallPalette palette, bool dark, double size) {
    return Semantics(
      button: _call.phase == CallPhase.speaking,
      label: status,
      hint: _call.phase == CallPhase.speaking ? l10n.speechCallSkipHint : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _call.phase == CallPhase.speaking
            ? () {
                HapticFeedback.lightImpact();
                _call.skip();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1,
          duration: AppMotion.of(context, _pressed ? AppMotion.press : const Duration(milliseconds: 420)),
          curve: _pressed ? Curves.easeOut : Curves.elasticOut,
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.slow),
            child: _light(visual, palette, dark, size),
          ),
        ),
      ),
    );
  }

  /// [child] growing and shrinking smoothly as its words come and go (at once with less motion).
  Widget _grow(Widget child) => _still
      ? child
      : AnimatedSize(
          duration: AppMotion.of(context, AppMotion.emphasized),
          curve: AppMotion.std,
          alignment: Alignment.bottomCenter,
          child: child,
        );

  void _openTranscript() {
    HapticFeedback.selectionClick();
    unawaited(showCallTranscript(context, _call));
  }

  /// 小窗进出时重画（简版布局和整页是两套）。
  void _onPipChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 整页按返回：收起成卡片，通话继续。之前返回键直接 pop 掉这条路由，
      // 宿主的 collapsed 没置位 → 卡片不显示，看着就是「语音界面直接退出」。
      // 挂断之后 canPop 放开，_scheduleLeave 才能自己把页面收掉。
      canPop: _call.phase == CallPhase.ended,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_collapsed && _call.phase != CallPhase.ended) _collapse();
      },
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    _built = _shows();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = ref.watch(callSettingsProvider);
    // fork(call): 画中画只有巴掌大，塞整页会把球、字幕、一排按钮挤成一团；
    // 小窗里只留球和一句状态。
    // 这一条要在收起之前：先收起再按 home 时，小窗里显示的应该是小窗自己的样子，
    // 而不是那张底部卡片。
    if (pictureInPictureMode.value) {
      return callPipView(
        l10n: l10n,
        theme: theme,
        call: _call,
        signedIn: ref.read(accountProvider).signedIn,
        visual: settings.visual,
      );
    }
    if (_collapsed) return _collapsedCard(l10n, theme);
    _still = AppMotion.reduced(context);
    final performance = ref.watch(performanceDefaultsProvider);
    final blur = performance.blur;
    // The keys sit over a field that moves every frame, so their frosting is redone every
    // frame too: more than HarmonyOS's renderer, or the light mode, can spare.
    final keyBlur = blur && !performance.lightweight && ref.watch(operatingSystemProvider) != 'ohos';
    final ended = _call.phase == CallPhase.ended;
    // Looked up once per picture, not on each of the 25 level updates a second.
    if (settings.image != _imageChecked) {
      _imageChecked = settings.image;
      _imageExists = settings.image.isNotEmpty && File(settings.image).existsSync();
    }
    // 伙伴房间通话用自己的背景，否则听设置里的。
    final backdrop = widget.backdrop ?? settings.backdrop;
    final image = backdrop == CallBackdrop.image && _imageExists ? settings.image : null;
    final her = backdrop == CallBackdrop.companion && !_stageFailed;
    // 海：默认那片深蓝，也是"没有别的底"时的底。它够深，字要浅。
    final sea = backdrop == CallBackdrop.sea;
    final (status, dots) = _status(l10n);
    final error = _call.error;
    if (widget.conversation is CompanionCallConversation) ref.watch(companionSessionsProvider);
    final sessionId = switch (widget.conversation) {
      final ChatCallConversation chat => chat.sessionId,
      final CompanionCallConversation room => room.sessionId,
      _ => null,
    };
    final width = MediaQuery.sizeOf(context).width;
    final lightSize = math.min(340.0, width * 0.86);
    final hearing = _call.phase == CallPhase.hearing;
    final heard = ended ? '' : _call.heard;
    // While the person speaks, her last words step aside for theirs.
    final reply = hearing ? '' : speakable(_call.caption).replaceAll('\n', ' ');
    final failing = ended ? null : error;
    // 有底片就是深色画面：海是 #10265A→#02050D 那片深蓝，图片和她更不用说。
    // 只有什么都没有（纯色场）时才跟着主题走。
    final dark = theme.brightness == Brightness.dark || image != null || her || sea;
    final palette = CallPalette.of(theme.colorScheme, light: !dark);
    final ink = CallInk(dark: dark, child: const SizedBox());

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: CallInk(
        dark: dark,
        child: Scaffold(
          backgroundColor: palette.field,
          body: CallClock(
            onTick: _tick,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CallField(scene: _scene, palette: palette, center: her ? 0.66 : 0.4),
                // A new backdrop fades in over the old one.
                AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.slow),
                  switchInCurve: AppMotion.enter,
                  switchOutCurve: AppMotion.exit,
                  child: switch ((image, her)) {
                    (final path?, _) => ImageBackdrop(key: ValueKey(path), path: path, blur: blur),
                    (_, true) => CompanionBackdrop(
                      key: const ValueKey('her'),
                      controller: _stage,
                      onReady: () {
                        if (!mounted) return;
                        setState(() => _stageReady = true);
                        _arrived(_call.phase);
                      },
                      onFailed: () {
                        if (mounted) {
                          setState(() {
                            _stageFailed = true;
                            _stageReady = false;
                          });
                        }
                      },
                    ),
                    _ => const SizedBox.expand(key: ValueKey('sea')),
                  },
                ),
                // The screen's edge glows only with the glass orb; the ring is light enough on its own.
                if (settings.visual == CallVisual.glass) CallEdgeGlow(scene: _scene, palette: palette),
                if (her)
                  // Her feet fade into the water so the words below stay readable.
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00030712), Color(0x00030712), Color(0xD9030712), Color(0xF2030712)],
                          stops: [0, 0.46, 0.7, 1],
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  child: Column(
                    children: [
                      _rise(
                        0.05,
                        _TopBar(
                          title: widget.title,
                          since: _since,
                          live: !ended && _since != null,
                          blur: keyBlur,
                          onTranscript: _openTranscript,
                          onCollapse: ended ? null : _collapse,
                          onBackdrop: ended
                              ? null
                              // Trying voices out plays on her speaker: she stops this reply first.
                              : () => unawaited(showCallBackdropSheet(context, inCall: true, beforeVoice: _call.skip)),
                        ),
                        distance: -14,
                      ),
                      Expanded(
                        child: her
                            ? const SizedBox.expand()
                            : LayoutBuilder(
                                // The words below take the room they need; the light gives way (to 56 % at least).
                                builder: (context, box) => Center(
                                  child: Transform.scale(
                                    scale: (box.maxHeight / (lightSize * 1.04)).clamp(0.56, 1.0),
                                    child: OverflowBox(
                                      maxWidth: lightSize,
                                      maxHeight: lightSize,
                                      child: _lightKey(l10n, status, settings.visual, palette, dark, lightSize),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      _rise(
                        0.3,
                        CallStatus(
                          text: status,
                          dots: dots,
                          color: ended && _call.ended != CallEnd.hungUp ? ink.warn : null,
                        ),
                      ),
                      const SizedBox(height: 14),
                      // What is being said, as much of it as fits; a tap opens all of it.
                      Semantics(
                        button: _call.turns.isNotEmpty,
                        hint: _call.turns.isNotEmpty ? l10n.speechCallTranscriptHint : null,
                        child: GestureDetector(
                          key: const ValueKey('call-captions'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _call.turns.isEmpty ? null : _openTranscript,
                          child: _grow(
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 28),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 560),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    HeardLine(text: heard, speaking: hearing),
                                    if (heard.isNotEmpty && (reply.isNotEmpty || failing != null))
                                      const SizedBox(height: 12),
                                    if (failing != null)
                                      Text(
                                        speechErrorText(l10n, failing, listening: true),
                                        key: const ValueKey('call-error'),
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodyMedium?.copyWith(color: ink.warn),
                                      )
                                    else
                                      RevealText(
                                        key: const ValueKey('call-reply'),
                                        text: reply,
                                        done: _call.phase != CallPhase.speaking,
                                        style: theme.textTheme.bodyLarge?.copyWith(
                                          color: ink.fg.withValues(alpha: 0.94),
                                          height: 1.6,
                                          fontSize: 18,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (sessionId != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: CompanionAsk(sessionId: sessionId),
                        ),
                      const SizedBox(height: 26),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _rise(
                            0.4,
                            CallKey(
                              key: const ValueKey('call-mute'),
                              icon: _call.muted ? AppIcons.micMuted : AppIcons.voice,
                              label: _call.muted ? l10n.speechCallUnmute : l10n.speechCallMute,
                              on: _call.muted,
                              blur: keyBlur,
                              onTap: ended ? null : () => _call.setMuted(!_call.muted),
                            ),
                            distance: 28,
                          ),
                          _rise(
                            0.48,
                            HangUpKey(
                              key: const ValueKey('call-hang-up'),
                              icon: AppIcons.hangUp,
                              label: l10n.speechCallHangUp,
                              onTap: ended ? null : _hangUp,
                            ),
                            distance: 34,
                          ),
                          _rise(
                            0.56,
                            CallKey(
                              key: const ValueKey('call-speaker'),
                              icon: _call.speaker ? AppIcons.readAloud : AppIcons.earpiece,
                              label: _call.speaker ? l10n.speechCallSpeakerOn : l10n.speechCallEarpiece,
                              on: _call.speaker,
                              blur: keyBlur,
                              onTap: ended ? null : () => unawaited(_call.setSpeaker(!_call.speaker)),
                            ),
                            distance: 28,
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The top bar: the clock and the conversation's name in one frosted capsule,
/// between two frosted round keys, 字幕 and 背景, all three the same height.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.since,
    required this.live,
    required this.blur,
    required this.onTranscript,
    required this.onCollapse,
    required this.onBackdrop,
  });

  final String title;
  final DateTime? since;
  final bool live;
  final bool blur;
  final VoidCallback onTranscript;
  final VoidCallback? onCollapse;
  final VoidCallback? onBackdrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final ink = CallInk.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          _RoundKey(
            key: const ValueKey('call-transcript'),
            icon: AppIcons.callTranscript,
            label: l10n.speechCallTranscriptHint,
            blur: blur,
            onTap: onTranscript,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Center(
              child: _Frosted(
                blur: blur,
                shape: const StadiumBorder(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CallTimer(since: since, live: live),
                      Container(
                        width: 1,
                        height: 14,
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        color: ink.glassBorder,
                      ),
                      Flexible(
                        child: Text(
                          title,
                          key: const ValueKey('call-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: ink.fg,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // fork(call): 整页的收起键——pop 路由、卡片接管，通话不停。
          _RoundKey(
            key: const ValueKey('call-collapse'),
            icon: Icons.keyboard_arrow_down,
            label: l10n.speechCallCollapse,
            blur: blur,
            onTap: onCollapse,
          ),
          const SizedBox(width: 10),
          _RoundKey(
            key: const ValueKey('call-backdrop'),
            icon: AppIcons.settings,
            label: l10n.speechCallSettings,
            blur: blur,
            onTap: onBackdrop,
          ),
        ],
      ),
    );
  }
}

/// Frosted glass 40 high in [shape]: the call's glass tint and hairline over a
/// blur of what is behind ([blur], as the performance setting allows).
class _Frosted extends StatelessWidget {
  const _Frosted({required this.shape, required this.blur, required this.child, this.width});

  final OutlinedBorder shape;
  final bool blur;
  final double? width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ink = CallInk.of(context);
    final glass = Container(
      width: width,
      height: 40,
      decoration: ShapeDecoration(
        color: ink.glass,
        shape: shape.copyWith(side: BorderSide(color: ink.glassBorder)),
      ),
      child: child,
    );
    if (!blur) return glass;
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: glass),
    );
  }
}

/// A small round glass key in the top bar; gives a little under the finger.
class _RoundKey extends StatefulWidget {
  const _RoundKey({super.key, required this.icon, required this.label, required this.blur, required this.onTap});

  final IconData icon;
  final String label;
  final bool blur;
  final VoidCallback? onTap;

  @override
  State<_RoundKey> createState() => _RoundKeyState();
}

class _RoundKeyState extends State<_RoundKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final ink = CallInk.of(context);
    final onTap = widget.onTap;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onTap == null ? null : (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
        child: AnimatedScale(
          scale: _down ? 0.9 : 1,
          duration: AppMotion.of(context, _down ? AppMotion.press : AppMotion.standard),
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: _Frosted(
            width: 40,
            shape: const CircleBorder(),
            blur: widget.blur,
            child: Icon(widget.icon, size: 18, color: ink.fg.withValues(alpha: onTap == null ? 0.35 : 0.8)),
          ),
        ),
      ),
    );
  }
}
