// 语音通话的宿主：通话在页面之外。
//
// 收起这件事，路由做不到（test/speech/collapsed_card_hit_test.dart 钉死的结论：
// 只要通话页是 push 上去的一条路由，收起后下面的页面就一定点不到——透明只是
// 看得见，不是摸得到）。所以把 [VoiceCallController] 从页面里拿出来：
//
//   openChatCall → host.openCall（造控制器、启动、push 页面）
//   收起        → host.collapse：pop 掉全屏路由，卡片挂到 RootGate 的
//                 [CallCardLayer] 上；通话不动
//   点卡片      → 卡片那层把页面重新 push（host.expanding 只搬状态），
//                 复用同一个控制器
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
//
// 本文件只有状态，没有界面：推页面这类事由 ui 层做（卡片层
// ui/speech/call/call_card_layer.dart、页面 ui/speech/voice_call_page.dart），
// 宿主不 import ui/（test/arch/import_direction_test.dart 的方向约定）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_call.dart';
import '../companion/companion_voice.dart' show speechSpeakerProvider;
import '../companion/companion_voice_source.dart';
import '../l10n/l10n.dart';
import '../speech/call/thinking_cue.dart';
import '../speech/call/voice_call.dart';
import '../speech/deepseek_speech.dart';
import '../speech/speech_out.dart';
import '../speech/speech_settings.dart';
import '../speech/voice_cloud.dart';
import '../state/app_notes.dart';
import '../state/call_surface_state.dart';
import '../state/notify_state.dart' show callChatProvider;
import '../state/picture_in_picture.dart';
import '../state/voice_settings.dart';
import '../state/voice_state.dart' show VoicePermissionGranted, voiceBridgeProvider;
import '../speech/speech_audio.dart';

/// The call out of any page: [openChatCall] makes the controller and hands it
/// here; the page shows it; 收起 pops the page and the card takes over.
class VoiceCallHost extends ChangeNotifier {
  VoiceCallHost._();

  /// One call at a time, app-wide.
  static final VoiceCallHost instance = VoiceCallHost._();

  VoiceCallController? _call;
  CallVoiceBook? _book;
  ProviderContainer? _container;

  /// 伙伴房间通话指定的背景；收起再展开仍要显示她。
  CallBackdrop? _backdrop;
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

  /// The backdrop her room's call passed in, if any.
  CallBackdrop? get backdrop => _backdrop;

  /// Opens a call: the controller is made here (its settings and its voice
  /// wired to the container, not to any page) and started before the page is
  /// pushed, so the call outlives the page. [push] shows the page over
  /// whatever is open; the caller owns the route (ui), the host owns the call.
  Future<void> openCall({
    required ProviderContainer container,
    required String title,
    required CallConversation conversation,
    required Future<void> Function() push,
    CallBackdrop? backdrop,
  }) async {
    _container = container;
    _title = title;
    _backdrop = backdrop;
    final book = _book = CallVoiceBook(container);
    final made = makeChatCallController(
      container,
      conversation,
      book,
      verbatimInput: switch (conversation) {
        final CompanionCallConversation room => room.fullMode,
        _ => null,
      },
    );
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
    // 收起的动作可能接着进小窗（返回键那条路）：先把挂在这页上面的弹层
    // 收掉，别让它跟着被画进小窗里。
    final route = ModalRoute.of(pageContext);
    if (route != null && !route.isCurrent) {
      Navigator.of(pageContext).popUntil((r) => identical(r, route));
    }
    Navigator.of(pageContext).pop();
  }

  /// The card was tapped and the page is going back up: this only moves the
  /// host's state; the layer that shows the card pushes the page and reports
  /// back through [pageDown] when its route goes away. The call was never gone.
  void expanding() {
    if (_call == null || _pageUp || !_collapsed) return;
    _collapsed = false;
    _pageUp = true;
    _container?.read(callSurfaceProvider.notifier).set(CallSurface.full);
    notifyListeners();
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
    if (call.phase == CallPhase.ended) {
      // 通话一结束就把原生标志关掉，不等页面收尾：页面可能因为异常没 pop，
      // close() 那条 380ms 的路就走不到，标志会一直留着「还在通话」。
      // 没通话时按返回/按 home 都不该再被自动缩成小窗。
      unawaited(setCallActive(false));
    }
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
  CallVoiceBook book, {
  bool Function()? verbatimInput,
}) {
  VoiceCallController? made;
  final audio = container.read(speechAudioProvider);
  final deepseek = container.read(deepSeekSpeechProvider);
  final bridge = container.read(voiceBridgeProvider);
  final speaker = container.read(speechSpeakerProvider);
  made = VoiceCallController(
    audio: audio,
    conversation: conversation,
    verbatimInput: verbatimInput,
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
    permission: () async => (await bridge.requestPermission()).granted,
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
