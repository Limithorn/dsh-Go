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

import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../../performance/performance_state.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
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
import '../../state/app_notes.dart';
import '../../state/call_surface_state.dart';
import '../../state/notify_state.dart';
import '../../state/picture_in_picture.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../chat/voice/voice_bridge.dart';
import '../companion/companion_ask.dart';
import '../companion/companion_stage.dart';
import '../fx/voice_ring/voice_ring.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../../state/streaming_asr_state.dart';
import '../../state/streaming_pcm_state.dart';
import '../../usage/usage_stats.dart';
import '../../voice/live_words.dart';
import '../../voice/live_words_model.dart';
import '../../voice/streaming_pcm.dart';
import 'call/call_backdrop.dart';
import 'call/call_parts.dart';
import 'call/call_transcript.dart';
import 'call/call_visuals.dart';
import 'speech_ui.dart';

/// Opens a call with the main chat's conversation. [session] gives its id,
/// creating it for a new chat; [title] heads the page.
Future<void> openChatCall(
  BuildContext context, {
  required String title,
  required Future<String?> Function() session,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(readAloudProvider.notifier).stop();
  // The call is shown whole while this page is up (state/call_surface_state.dart).
  // Set here, not in the page's own lifecycle: a provider is not to be written
  // from a widget that is being disposed.
  container.read(callSurfaceProvider.notifier).set(CallSurface.full);
  await Navigator.of(context).push(
    PageRouteBuilder<void>(
      // Transparent so a call can shrink to a card over the conversation
      // instead of holding the whole screen (the page paints its own field).
      opaque: false,
      fullscreenDialog: true,
      transitionDuration: AppMotion.of(context, const Duration(milliseconds: 520)),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.collapse),
      pageBuilder: (_, _, _) => VoiceCallPage(title: title, conversation: ChatCallConversation(container, session)),
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
  // Off the call: its conversation is no longer the one being heard (ChatCallConversation set it).
  container.read(callChatProvider.notifier).set(null);
  container.read(callSurfaceProvider.notifier).set(CallSurface.none);
}

class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({super.key, required this.title, required this.conversation});

  final String title;
  final CallConversation conversation;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final VoiceCallController _call;
  final _scene = CallScene();
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? _leave;
  DateTime? _since;
  CallPhase _shown = CallPhase.starting;
  void Function(UsageOutcome, {UsageOperation? actual})? _callConnect;
  void Function(UsageOutcome, {UsageOperation? actual})? _callSession;

  // Her, when she is the backdrop.
  final _stage = CompanionStageController();
  bool _stageReady = false;
  bool _stageFailed = false;
  double _mouthAt = 0;
  bool _mouthOpen = false;

  /// A finger on the light: it gives a little.
  bool _pressed = false;

  /// 收起: the call as one card over the conversation. The page stays alive, so
  /// the microphone and the turn under way carry on.
  bool _collapsed = false;

  /// 收起卡片的拖动位置现由卡片自己持有（_CollapsedCallCard），
  /// 页面不再参与（drag）。 

  /// The system asks for less motion (read each build): the light holds still
  /// and the page comes in without its staggered rise.
  bool _still = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 通话期间告诉原生：按 home 不要退到后台，直接缩成小窗，麦克风才不被挖。
    unawaited(setCallActive(true));
    unawaited(setCallScreen(true));
    watchPictureInPicture();
    pictureInPictureMode.addListener(_onPipChanged);
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
    HapticFeedback.mediumImpact();
    _enter.forward();
    unawaited(_start());
  }

  /// Live captions, once the call listens, when the streaming model is on the phone.
  LiveWords? _live;

  /// Her voice for the next reply.
  late CompanionVoiceSettings _voice;

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

  Future<void> _start() async {
    final pcm = ref.read(streamingPcmCaptureProvider);
    final asr = ref.read(streamingAsrProvider);
    final found = liveWordsModel(ref);
    _callConnect = ref.read(usageStatsProvider.notifier).beginOperation(UsageOperation.callConnect);
    await _call.start();
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
    if (phase == CallPhase.ended && _leave == null) {
      // Hung up: the light sinks away first. Ended for a reason: the reason stays a moment.
      _leave = Timer(
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
    setState(() {});
  }

  /// A new phase: a touch under the finger, and her mood when she is there.
  void _arrived(CallPhase phase) {
    switch (phase) {
      case CallPhase.listening when _since == null:
        _since = DateTime.now();
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
    await enterPictureInPicture();
  }

  /// The call as a card at the bottom, over whatever is below the route.
  Widget _collapsedCard(L10n l10n, ThemeData theme) {
    final (status, _) = _status(l10n);
    return _CollapsedCallCard(
      status: status,
      ended: _call.phase == CallPhase.ended,
      l10n: l10n,
      theme: theme,
      onExpand: () => setState(() => _collapsed = false),
      onPip: _enterPip,
      onHangUp: _hangUp,
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
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _call.backgrounded();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(setCallActive(false));
    unawaited(setCallScreen(false));
    pictureInPictureMode.removeListener(_onPipChanged);
    stopWatchingPictureInPicture();
    unawaited(_live?.stop());
    _leave?.cancel();
    _enter.dispose();
    _callConnect?.call(UsageOutcome.unknown);
    _callSession?.call(UsageOutcome.unknown);
    _call
      ..removeListener(_changed)
      ..dispose();
    _scene.dispose();
    super.dispose();
  }

  void _hangUp() {
    HapticFeedback.heavyImpact();
    _call.hangUp();
  }

  (String, bool) _status(L10n l10n) {
    if (_call.phase == CallPhase.ended) {
      return (
        switch (_call.ended) {
          CallEnd.permission => l10n.speechCallEndPermission,
          CallEnd.microphone => l10n.speechCallEndMicrophone,
          CallEnd.noRecognizer =>
            wordsForIos
                ? (ref.read(accountProvider).signedIn
                      ? l10n.iosSpeechCallEndNoRecognizerSignedIn
                      : l10n.iosSpeechCallEndNoRecognizer)
                : (ref.read(accountProvider).signedIn
                      ? l10n.speechCallEndNoRecognizerSignedIn
                      : l10n.speechCallEndNoRecognizer),
          CallEnd.background => l10n.speechCallEndBackground,
          CallEnd.failed => l10n.speechCallEndFailed,
          CallEnd.hungUp || null => l10n.speechCallEnded,
        },
        false,
      );
    }
    if (_call.muted && _call.phase != CallPhase.speaking && _call.phase != CallPhase.thinking) {
      return (l10n.speechCallMuted, false);
    }
    return switch (_call.phase) {
      CallPhase.starting => (l10n.speechCallStarting, true),
      CallPhase.listening => (l10n.speechCallListening, true),
      CallPhase.hearing => (l10n.speechCallHearing, false),
      CallPhase.thinking => (l10n.speechCallThinking, true),
      CallPhase.speaking => (l10n.speechCallSpeaking, false),
      CallPhase.ended => (l10n.speechCallEnded, false),
    };
  }

  /// The light in the middle: Libraries.dev's voice ring (its ribbon or its single line),
  /// listening to the person, speaking with her voice, turning while it thinks; or the glass orb.
  Widget _light(CallVisual visual, CallPalette palette, bool dark, double size) {
    if (visual == CallVisual.glass) {
      return CallLight(key: const ValueKey('glass'), scene: _scene, palette: palette, size: size);
    }
    final phase = _call.phase;
    return VoiceRing(
      key: ValueKey(visual),
      type: visual == CallVisual.mono ? VoiceRingType.mono : VoiceRingType.ring,
      state: switch (phase) {
        CallPhase.starting || CallPhase.thinking => VoiceRingState.processing,
        CallPhase.listening || CallPhase.hearing => VoiceRingState.listening,
        CallPhase.speaking => VoiceRingState.speaking,
        CallPhase.ended => VoiceRingState.idle,
      },
      size: size * 0.82,
      theme: dark ? VoiceRingTheme.dark : VoiceRingTheme.light,
      paused: phase == CallPhase.ended,
      level: () => switch (_call.phase) {
        CallPhase.hearing when !_call.muted => VoiceRingLevel.mic(_call.micLevel),
        CallPhase.speaking => VoiceRingLevel.playback(_call.voiceLevel),
        _ => 0,
      },
    );
  }

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

  /// 画中画小窗里的样子：一球、一句状态、一个挂断。
  ///
  /// 小窗是方的、宽度只有屏幕的三分之一，整页缩进去会挤成一片，所以单独排：
  /// 球占上方，状态压在它下面，挂断固定在底部中央，Grand 手势和点击区域都留够。
  Widget _pipView(L10n l10n, ThemeData theme) {
    final (status, _) = _status(l10n);
    final ink = theme.colorScheme;
    // 小窗里不做可点的控件：Android 把小窗里的单击拿去展开系统控制，双击才回 App，
    // 按钮画得再好也点不到。所以小窗只负责「让人一眼看出还在通话」：
    // 宠物 + 一句状态，想操作就双击回 App。
    return ColoredBox(
      color: ink.surface,
      child: SafeArea(
        minimum: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Center(
                // idle.png 是一张 13 帧的横向精灵条（676x49，每帧 52x49），
                // 直接当图片画出来就是“一排小人”。只取第一帧：Align 的
                // widthFactor 把宽度压到 1/13，外面再 ClipRect 剪掉其余。
                child: ClipRect(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1 / 13,
                    child: Image.asset(
                      'assets/pets/whale-girl/idle.png',
                      width: 52 * 1.6,
                      height: 49 * 1.6,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
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
                style: theme.textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// 小窗进出时重画（简版布局和整页是两套）。
  void _onPipChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // 画中画只有巴掌大，塞整页会把球、字幕、一排按钮挤成一团；
    // 小窗里只留球、一句状态和一个挂断。
    // 这一条要在收起之前：先收起再按 home 时，小窗里显示的应该是小窗自己的样子，
    // 而不是那张底部卡片。
    if (pictureInPictureMode.value) return _pipView(l10n, theme);
    if (_collapsed) return _collapsedCard(l10n, theme);
    _still = AppMotion.reduced(context);
    final settings = ref.watch(callSettingsProvider);
    final performance = ref.watch(performanceDefaultsProvider);
    final blur = performance.blur;
    // The keys sit over a field that moves every frame, so their frosting is redone every
    // frame too: more than HarmonyOS's renderer, or the light mode, can spare.
    final keyBlur = blur && !performance.lightweight && ref.watch(operatingSystemProvider) != 'ohos';
    final ended = _call.phase == CallPhase.ended;
    final image =
        settings.backdrop == CallBackdrop.image && settings.image.isNotEmpty && File(settings.image).existsSync()
        ? settings.image
        : null;
    final her = settings.backdrop == CallBackdrop.companion && !_stageFailed;
    final (status, dots) = _status(l10n);
    final error = _call.error;
    final sessionId = switch (widget.conversation) {
      final ChatCallConversation chat => chat.sessionId,
      _ => null,
    };
    final width = MediaQuery.sizeOf(context).width;
    final lightSize = math.min(340.0, width * 0.86);
    final hearing = _call.phase == CallPhase.hearing;
    final heard = ended ? '' : _call.heard;
    // While the person speaks, her last words step aside for theirs.
    final reply = hearing ? '' : speakable(_call.caption).replaceAll('\n', ' ');
    final failing = ended ? null : error;
    // Light or dark as the theme is; a picture or her behind always reads as dark.
    final dark = theme.brightness == Brightness.dark || image != null || her;
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
                          onCollapse: ended ? null : () => setState(() => _collapsed = true),
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

/// 收起后的通话卡片。
///
/// 自己拿着位置，自己 setState：拖动只重建这一小棵树，不碰后面那页（那页有整片
/// 流动的光，重建一次就是压死主线程的代价）。之前把它写在页面里、靠页面的 state
/// 或外层通知器去推，拖一次就卡住——因为每次重建都新建 GestureDetector，手势
/// 识别器跟着被销毁重建，拖动就断在那里。
class _CollapsedCallCard extends StatefulWidget {
  const _CollapsedCallCard({
    required this.status,
    required this.ended,
    required this.l10n,
    required this.theme,
    required this.onExpand,
    required this.onPip,
    required this.onHangUp,
  });

  final String status;
  final bool ended;
  final L10n l10n;
  final ThemeData theme;
  final VoidCallback onExpand;
  final Future<void> Function() onPip;
  final VoidCallback onHangUp;

  @override
  State<_CollapsedCallCard> createState() => _CollapsedCallCardState();
}

class _CollapsedCallCardState extends State<_CollapsedCallCard> {
  Offset _drag = Offset.zero;

  /// 长按开始时的位置；拖动过程中按增量算，不累积误差。
  Offset _origin = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final ink = widget.theme.colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final card = Material(
      key: const ValueKey('call-collapsed'),
      elevation: 10,
      borderRadius: BorderRadius.circular(22),
      color: ink.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.voice, size: 18, color: ink.primary),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                widget.status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.theme.textTheme.bodyMedium,
              ),
            ),
            IconButton(
              key: const ValueKey('call-expand'),
              tooltip: widget.l10n.speechCallExpand,
              icon: const Icon(Icons.open_in_full, size: 18),
              onPressed: widget.onExpand,
            ),
            IconButton(
              key: const ValueKey('call-picture-in-picture'),
              tooltip: widget.l10n.speechCallPictureInPicture,
              icon: const Icon(Icons.picture_in_picture_alt, size: 18),
              onPressed: widget.ended ? null : widget.onPip,
            ),
            IconButton(
              key: const ValueKey('call-collapsed-hang-up'),
              tooltip: widget.l10n.speechCallHangUp,
              icon: Icon(AppIcons.hangUp, size: 20, color: ink.error),
              onPressed: widget.ended ? null : widget.onHangUp,
            ),
          ],
        ),
      ),
    );
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Transform.translate(
          offset: _drag,
          child: GestureDetector(
            // 长按才拖，短按照常点按钮。
            //
            // 之前用 onPanUpdate：拖完松手就僵。手指按住时不卡、一松手才卡，
            // 说明问题在手势结束那一步——pan 和卡片上的 IconButton 的 tap
            // 在竞技场里结算，松手那一帧才真正分出胜负。改成只认长按移动，
            // 两条手势从一开始就分开，不会在结束时撞在一起。
            onLongPressStart: (_) => _origin = _drag,
            onLongPressMoveUpdate: (details) {
              final half = screen.width / 2 - 150;
              final up = screen.height - 180;
              final next = _origin + details.offsetFromOrigin;
              setState(() {
                _drag = Offset(
                  next.dx.clamp(-half, half),
                  next.dy.clamp(-up, 0),
                );
              });
            },
            child: card,
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
