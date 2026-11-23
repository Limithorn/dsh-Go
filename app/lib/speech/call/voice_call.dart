// 语音通话: talking with a conversation, hands free. The microphone is cut into
// utterances on the phone (speech/call capture: echo cancellation, a speech
// gate, 300 ms kept before each start); each utterance is recognized whole
// (DeepSeek's recognizer by default) and sent as an ordinary message; the reply
// is read aloud while it is still being written.
//
// Speaking over the reply (插话打断, on by default) goes in two steps, as voice
// agents do it: she steps back at once (quieter), and what was said decides —
// agreement (嗯、对、好的) and noise let her carry on, 停 / 等一下 stop her, and
// anything else, or talking on past [VoiceCallController.confirmAfter] (1.6 s), is the
// person taking the turn: she stops, the turn behind her too, and the next
// message tells the model where she was cut off.
//
// The controller knows nothing of widgets or of where messages go: a
// [CallConversation] sends and reports the reply, a [VoiceCloud] recognizes,
// [voice] makes a fresh [SpeechOut] for each reply.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../diagnostics/diagnostics_channel.dart';
import '../speech_audio.dart';
import '../speech_out.dart';
import '../voice_cloud.dart';
import 'turn_words.dart';

enum CallPhase {
  /// Getting the microphone.
  starting,

  /// Waiting for the person to speak.
  listening,

  /// The person is speaking.
  hearing,

  /// Recognizing what was said, then waiting for the reply's first words.
  thinking,

  /// The reply is being read aloud.
  speaking,

  ended,
}

enum CallEnd { hungUp, permission, microphone, noRecognizer, background, failed }

/// The reply to what was last sent, so far.
class CallReply {
  const CallReply(this.text, {required this.done});

  /// Everything said so far (it only grows while [done] is false).
  final String text;

  /// The turn ended.
  final bool done;
}

/// Where a call's messages go and its replies come from.
abstract class CallConversation {
  /// Sends what the person said; false when it could not go.
  Future<bool> send(String text);

  /// The reply to the last [send], as it grows.
  Stream<CallReply> get replies;

  /// Stops the turn under way (the person spoke over it).
  Future<void> interrupt();

  /// Waiting on the person (an approval, a question): the call page shows it.
  bool get waiting;

  void dispose();
}

/// The person's choices for a call: speaking over her stops her; the
/// loudspeaker or the earpiece; [spokenHint] goes before the first message.
typedef CallChoices = ({
  bool bargeIn,
  bool speaker,
  String? spokenHint,
  CallPause pause,
  CallBargeSensitivity sensitivity,
  bool voiceprint,
  bool voiceprintOthers,
  CallMicSource callMicSource,
});

/// One exchange of the call as it reads: what the person said, and her reply
/// as far as it is known (all of it, or, [cut], as far as she got).
@immutable
class CallTurn {
  const CallTurn(this.you, {this.her = '', this.cut = false});

  final String you;
  final String her;
  final bool cut;
}

class VoiceCallController extends ChangeNotifier {
  VoiceCallController({
    required this.audio,
    required this.conversation,
    required this.recognizer,
    required this.voice,
    required this.choices,
    this.permission,
    this.cutNote,
    this.thinkingCue,
    this.confirmAfter = const Duration(milliseconds: 1600),
    this.cueAfter = const Duration(milliseconds: 1200),
  });

  /// Talking on over her this long is taking the turn, whatever the words.
  final Duration confirmAfter;

  /// No reply yet this long after the person finished: the thinking cue, once a turn.
  final Duration cueAfter;

  /// The line telling the model where the person cut its reply off ([heard]:
  /// the end of what they heard, '' when they cut in before a word).
  final String Function(String heard)? cutNote;

  /// Plays the soft "still thinking" sound.
  final Future<void> Function()? thinkingCue;

  final SpeechAudio audio;
  final CallConversation conversation;

  /// The recognizer for this call; null when none can be had (the call ends).
  final Future<VoiceCloud?> Function() recognizer;

  /// A voice for one reply.
  final SpeechOut Function() voice;

  /// The saved choices, read as the call starts (they may still be loading
  /// when the page opens).
  final Future<CallChoices> Function() choices;
  bool _bargeIn = true;
  CallPause _pause = CallPause.normal;
  CallBargeSensitivity _sensitivity = CallBargeSensitivity.normal;

  /// 通话采集走哪一路声音，见 [CallMicSource]。
  CallMicSource _micSource = CallMicSource.auto;

  /// 只认这几个人的声音。关着时下面三个字段都不参与判定，行为与以前逐字节一致。
  bool _voiceprint = false;

  /// Put before the call's first message: asks for short spoken answers.
  String? _spokenHint;

  /// Asks for the microphone (the system dialog); false when refused.
  final Future<bool> Function()? permission;

  /// The microphone is being asked for: the dialog may pause the app.
  bool get asking => _asking;
  bool _asking = false;

  CallPhase _phase = CallPhase.starting;

  /// When the person could first talk: the clock on the page counts from here,
  /// not from when the page was pushed, so 收起 and 展开 keep counting.
  DateTime? _startedAt;
  DateTime? get startedAt => _startedAt;
  CallEnd? _ended;
  bool _muted = false;
  bool _speaker = true;
  double _micLevel = 0;
  double _voiceLevel = 0;
  String _heard = '';
  String _reply = '';
  Object? _error;
  bool _hinted = false;

  /// A sentence the conversation did not take yet. Kept verbatim: the person
  /// should not have to say it again just because the conversation was not
  /// ready for it (a new chat still being made, the opening page gone).
  ({String text, int token})? _pendingSend;

  /// The person began speaking over her: she is quieter until it is known what they said.
  bool _over = false;
  Timer? _overTimer;

  /// Since the person began talking over her (for [_overTimer]'s deadline).
  final _overFor = Stopwatch();

  /// What the person had heard of a reply they cut off, for their next message.
  String? _cutAt;

  /// The person's words as the phone hears them while they speak (live captions,
  /// when the streaming recognizer is there); the message still goes from [recognizer].
  String _live = '';

  /// 声纹开着时，这一次"插话"还在等身份。
  ///
  /// 有个真问题：`speechStart` 必须立刻发（duck 不能等），而声纹要 600ms 才判得出来。
  /// 所以这段时间她先降音、**不启动 1.6s 计时**，等 `speechJudge` 到了再决定。
  /// 声纹关着时这个字段恒为 false，一切照旧。
  bool _awaitingJudge = false;

  /// 这一次插话是被判成"外人"的（字幕提示用，也用于丢弃后续整句）。
  bool _judgedOther = false;

  /// 白名单外的人也能打断时，外人只是"慢一拍"：不启动计时，但保留整句识别，
  /// 说了实词才断。开关关掉时，外人一律不打断。
  bool _othersMayInterrupt = true;

  /// 最近一次声纹判定，供调测页显示；没有时为 null。
  ///
  /// 只读给界面看，不参与任何判定逻辑。
  ({VoiceprintKind kind, double score, String? matched, bool over})? get lastJudge => _lastJudge;
  ({VoiceprintKind kind, double score, String? matched, bool over})? _lastJudge;

  /// What she has said of the reply so far, while her voice carries it.
  String _said = '';
  bool _voiced = false;
  Timer? _cueTimer;
  bool _cued = false;

  /// 进了「想一想」之后，等她的声音真的响起来的兜底计时器。
  ///
  /// 阶段前进靠 `SpeechOutStarted`，而那是系统 TTS 真的开始播才发的。手机
  /// 没装中文语音包、或系统 TTS 被设成别的语言时，`speak()` 不报错、事件
  /// 也永远不来——界面就停在「想一想」不动，看着像卡死。
  ///
  /// 这里等不到就把阶段退回去，并留一句错误说明，至少让人知道往哪查。
  Timer? _voiceWatch;

  VoiceCloud? _cloud;
  StreamSubscription<SpeechAudioEvent>? _audioSub;
  StreamSubscription<CallReply>? _replySub;
  SpeechOut? _out;
  StreamSubscription<SpeechOutEvent>? _outSub;
  int _spoken = 0;
  bool _replyDone = true;
  int _turn = 0;
  int _recognizing = 0;

  /// The recognition under way when she was skipped before speaking.
  int _hushed = 0;
  bool _disposed = false;

  final _turns = <CallTurn>[];

  /// The call so far, oldest first.
  List<CallTurn> get turns => List.unmodifiable(_turns);

  CallPhase get phase => _phase;
  CallEnd? get ended => _ended;
  bool get muted => _muted;
  bool get speaker => _speaker;
  double get micLevel => _micLevel;
  double get voiceLevel => _voiceLevel;

  /// What the person is saying now (live), else what they said last (recognized).
  String get heard => (_phase == CallPhase.hearing || _over) && _live.isNotEmpty ? _live : _heard;

  /// Words heard live by the phone's own recognizer. Over her voice, a few real
  /// words (not agreement) are enough: the person is taking the turn.
  void live(String text) {
    if (_phase == CallPhase.ended) return;
    _live = text.trim();
    if (_over && _live.runes.length >= 4 && overWords(_live) == OverWords.speech) _cutIn();
    notifyListeners();
  }

  /// The reply being read (so far).
  String get reply => _reply;

  /// The reply as far as she has said it (nothing yet while her voice gets
  /// ready); all of it when there is no voice.
  String get caption => _voiced || _out != null ? _said : _reply;

  /// The thinking cue may still play: nothing of the reply has a voice yet.
  bool get cueStill => _phase == CallPhase.thinking && _out == null;

  /// The last thing that went wrong without ending the call (recognition,
  /// sending, the voice); cleared when the next turn starts.
  Object? get error => _error;

  /// The recognition setting changed: what is said next goes to what it names
  /// now (if that can listen; else to the one already in use).
  Future<void> refreshRecognizer() async {
    if (_phase == CallPhase.ended) return;
    final mine = ++_refreshing;
    // Still starting: start() looks again with the new setting.
    if (_cloud == null) return;
    final next = await recognizer();
    // A later change has the last word, whichever answer comes back first.
    if (next != null && mine == _refreshing && _phase != CallPhase.ended) _cloud = next;
  }

  int _refreshing = 0;

  Future<void> start() async {
    unawaited(const DiagnosticsChannel().recordVoiceStage('call_started'));
    _replySub = conversation.replies.listen(_onReply);
    _audioSub = audio.events.listen(_onAudio);
    final chosen = await choices();
    if (_disposed || _phase == CallPhase.ended) return;
    _bargeIn = chosen.bargeIn;
    _pause = chosen.pause;
    _sensitivity = chosen.sensitivity;
    _micSource = chosen.callMicSource;
    _voiceprint = chosen.voiceprint;
    _othersMayInterrupt = chosen.voiceprintOthers;
    _speaker = chosen.speaker;
    _spokenHint = chosen.spokenHint;
    notifyListeners();
    VoiceCloud? cloud;
    int mine;
    do {
      // Changed while this looked (refreshRecognizer during start): look again.
      mine = ++_refreshing;
      cloud = await recognizer();
      if (_disposed || _phase == CallPhase.ended) return;
    } while (mine != _refreshing);
    if (cloud == null) {
      _end(CallEnd.noRecognizer);
      return;
    }
    _cloud = cloud;
    final ask = permission;
    if (ask != null) {
      _asking = true;
      final granted = await ask().catchError((Object _) => false);
      _asking = false;
      if (_disposed || _phase == CallPhase.ended) return;
      if (!granted) {
        _end(CallEnd.permission);
        return;
      }
    }
    unawaited(const DiagnosticsChannel().recordVoiceStage('preparing'));
    final started = await audio.startCall(
      bargeIn: _bargeIn,
      pause: _pause,
      sensitivity: _sensitivity,
      micSource: _micSource,
    );
    if (_disposed || _phase == CallPhase.ended) {
      if (started == CallStart.ok) unawaited(audio.stopCall());
      return;
    }
    switch (started) {
      case CallStart.ok:
        unawaited(const DiagnosticsChannel().recordVoiceStage('capture_started'));
        _speaker = await audio.speaker(_speaker);
        _set(CallPhase.listening);
      case CallStart.permission:
        _end(CallEnd.permission);
      case CallStart.microphone || CallStart.unavailable:
        _end(CallEnd.microphone);
    }
  }

  void _onAudio(SpeechAudioEvent event) {
    if (_phase == CallPhase.ended) return;
    switch (event) {
      case MicLevel(:final value):
        _micLevel = value;
        notifyListeners();
      case SpeechStart(:final over):
        _live = '';
        final out = _out;
        if ((over || _phase == CallPhase.speaking) && out != null) {
          _over = true;
          // The system voice cannot be turned down: she stops at once.
          if (!out.canDuck) {
            _cutIn();
            return;
          }
          // Over her voice: quieter (the native side already turned her down)
          // until what was said is known, or the person keeps talking.
          out.duck(true);
          _overTimer?.cancel();
          // The chosen pause's extra quiet doesn't count as talking on: a short
          // 嗯嗯 still arrives as an utterance before this confirms.
          _overFor
            ..reset()
            ..start();
          // 声纹开着：先只降音，不启动计时。等 speechJudge 说了"是谁"再决定，
          // 否则旁人随便一声就会在 1.6s 后把她切断——那正是要修的事。
          if (_voiceprint) {
            _awaitingJudge = true;
            _judgedOther = false;
            return;
          }
          _overTimer = Timer(confirmAfter + _pause.longer, _cutIn);
          return;
        }
        _set(CallPhase.hearing);
      case SpeechJudge(:final kind, :final score, :final matched):
        _onJudge(kind, score, matched);
      case Utterance(:final wav, :final duration):
        unawaited(const DiagnosticsChannel().recordVoiceStage('utterance_ready'));
        // Finished before [confirmAfter]: the words decide.
        _overTimer?.cancel();
        // The live words stand in until the recognizer's come back.
        if (_live.isNotEmpty) _heard = _live;
        _live = '';
        unawaited(_recognize(wav, duration));
      case CallError():
        _end(CallEnd.failed);
      case PlayEvent() || PlayLevel():
        break;
    }
  }

  Future<void> _recognize(Uint8List wav, Duration duration) async {
    final cloud = _cloud;
    if (cloud == null || _muted) return;
    // 声纹判成外人、又不许外人插话：这一段整个丢掉，识别都不必跑。
    // 她已经在 _onJudge 里恢复音量继续了，这也是"只降音不切断"的落点。
    if (_voiceprint && _judgedOther && !_othersMayInterrupt) {
      _judgedOther = false;
      unawaited(const DiagnosticsChannel().recordVoiceStage('voiceprint_dropped'));
      return;
    }
    // Said over her (she may already have stopped, if they talked on).
    final over = _over || _cutAt != null;
    // Too short to be words (a cough, a knock).
    if (duration < const Duration(milliseconds: 350)) {
      if (_over) {
        _carryOn();
      } else if (_phase == CallPhase.hearing) {
        _set(CallPhase.listening);
      }
      return;
    }
    final mine = ++_recognizing;
    _error = null;
    if (!_over) _set(CallPhase.thinking);
    String text;
    try {
      unawaited(const DiagnosticsChannel().recordVoiceStage('recognizing', backend: 'cloud'));
      text = await cloud.transcribe(wav);
      unawaited(const DiagnosticsChannel().recordVoiceStage('recognized', backend: 'cloud'));
    } catch (error) {
      unawaited(const DiagnosticsChannel().recordVoiceStage('failed', backend: 'cloud'));
      if (_phase == CallPhase.ended || mine != _recognizing) return;
      if (_over) {
        // Could not make it out: she carries on.
        _carryOn();
        return;
      }
      _error = error;
      _set(CallPhase.listening);
      return;
    }
    if (_phase == CallPhase.ended || mine != _recognizing) return;
    final taken = over ? overWords(text) : OverWords.speech;
    if (taken == OverWords.backchannel && _over) {
      _carryOn();
      return;
    }
    if (_over) _cutIn();
    if (taken != OverWords.speech || text.trim().isEmpty) {
      // 停, agreement after she stopped, or nothing at all: nothing to send (where
      // she was cut off still goes with the next message).
      _set(_out == null ? CallPhase.listening : CallPhase.speaking);
      return;
    }
    _heard = text.trim();
    _turns.add(CallTurn(_heard));
    _reply = '';
    _said = '';
    _voiced = false;
    _spoken = 0;
    _turn++;
    // Skipped while this was being made out: it still goes, its reply is not read.
    final hushed = mine == _hushed;
    _replyDone = hushed;
    final hint = _spokenHint;
    final cut = _cutAt;
    _cutAt = null;
    final note = cut == null ? null : cutNote?.call(cut.length > 30 ? '…${cut.substring(cut.length - 30)}' : cut);
    final message = [if (!_hinted && hint != null) hint, ?note, _heard].join('\n');
    _hinted = true;
    _cued = false;
    _cueTimer?.cancel();
    if (hushed) {
      if (!_disposed) notifyListeners();
    } else {
      _cueTimer = Timer(cueAfter, _cue);
      _set(CallPhase.thinking);
      _watchVoice();
    }
    final sent = await conversation.send(message);
    if (_phase == CallPhase.ended || _disposed) return;
    if (!sent) {
      // 「没发出去，再说一次」 used to be said at once, and then again for
      // every bit of noise the microphone picked up. The words are already
      // here: hold them and offer them to the conversation again. Only a
      // long string of refusals is a real failure worth saying out loud.
      _pendingSend = (text: message, token: mine);
      _replyDone = true;
      _set(CallPhase.listening);
      unawaited(_retrySend());
      return;
    }
  }

  /// Offers a held sentence again while the conversation settles (a new chat
  /// being created, a sync still running, the page that opened the call gone).
  /// Stops as soon as it is taken, the call ends, or the person says something
  /// new — never two copies of one turn, never a stale reply.
  Future<void> _retrySend() async {
    for (var attempt = 0; attempt < 12; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final pending = _pendingSend;
      if (pending == null || _disposed || _phase == CallPhase.ended || pending.token != _recognizing) return;
      _replyDone = false;
      final ok = await conversation.send(pending.text);
      if (pending != _pendingSend || _disposed || _phase == CallPhase.ended) return;
      if (ok) {
        _pendingSend = null;
        return;
      }
    }
    if (_pendingSend != null && !_disposed && _phase != CallPhase.ended) {
      _pendingSend = null;
      _replyDone = true;
      _error = const CallSendFailed();
      _set(CallPhase.listening);
    }
  }

  void _onReply(CallReply reply) {
    if (_phase == CallPhase.ended || _replyDone) return;
    final text = reply.text;
    if (text.length > _spoken) {
      if (_spoken == 0) unawaited(const DiagnosticsChannel().recordVoiceStage('reply_received'));
      final out = _out ??= _newVoice();
      out.add(text.substring(_spoken));
      _spoken = text.length;
      _reply = text;
      if (_turns.isNotEmpty) _turns.last = CallTurn(_turns.last.you, her: text);
      notifyListeners();
    }
    if (reply.done) {
      _replyDone = true;
      final out = _out;
      if (out == null) {
        // Nothing to say (the turn only ran tools, or was stopped).
        if (_phase == CallPhase.thinking) _set(CallPhase.listening);
      } else {
        out.finish();
      }
    }
  }

  /// The person takes the turn over her: she stops where they cut in, and so
  /// does the turn behind her.
  void _cutIn() {
    _overTimer?.cancel();
    if (!_over) return;
    unawaited(const DiagnosticsChannel().recordVoiceStage('interrupted'));
    _over = false;
    final out = _out;
    if (out != null) {
      _cutAt = out.heard;
      if (_turns.isNotEmpty && _turns.last.her.isNotEmpty) {
        _turns.last = CallTurn(_turns.last.you, her: out.heard, cut: true);
      }
      _stopVoice();
    }
    if (!_replyDone) unawaited(conversation.interrupt());
    _replyDone = true;
    _set(CallPhase.hearing);
  }

  /// It was agreement or noise: she comes back up and carries on.
  void _carryOn() {
    _overTimer?.cancel();
    _over = false;
    _awaitingJudge = false;
    _judgedOther = false;
    final out = _out;
    if (out == null) {
      if (_phase != CallPhase.thinking) _set(CallPhase.listening);
      return;
    }
    out.duck(false);
    _set(CallPhase.speaking);
  }

  /// 声纹说了"刚开口的是谁"。
  ///
  /// 三态：
  ///  - you：自己人，恢复原有逻辑（1.6s 计时 + 词表），与没开声纹时完全一样；
  ///  - other + 允许外人插话：不启动计时，但保留整句识别——说了实词才断，
  ///    "嗯""好的"这类不算。她反应慢一拍，但不会漏掉真正的插话；
  ///  - other + 不允许：她继续，这段丢掉，不切断；
  ///  - unknown：认不准就不动，等下一段判定（原生会继续判）。她维持降音。
  void _onJudge(VoiceprintKind kind, double score, String? matched) {
    if (!_voiceprint) return;
    // 记下来给调测页看：不管后面走哪条分支，这一次的分数都值得留下。
    _lastJudge = (kind: kind, score: score, matched: matched, over: _over);
    notifyListeners();
    // 不是"她正在说话时有人开口"的那种判定，与插话无关。
    if (!_over || !_awaitingJudge) return;
    _awaitingJudge = false;

    switch (kind) {
      case VoiceprintKind.you:
        _judgedOther = false;
        // 恢复原有节奏：确认时长 + 停顿档位，之后词表照旧。
        _overTimer?.cancel();
        _overTimer = Timer(confirmAfter + _pause.longer, _cutIn);
      case VoiceprintKind.other:
        _judgedOther = true;
        if (_othersMayInterrupt) {
          // 慢一拍：不启动计时，把决定权交给整句识别（_recognize 里的 _cutIn）。
          _overTimer?.cancel();
        } else {
          // 完全不让插：她继续，这段话之后由 _recognize 丢弃。
          _overTimer?.cancel();
          _carryOn();
        }
      case VoiceprintKind.unknown:
        // 认不准：维持降音，等下一段分。给一个兜底，避免一直降着不恢复。
        _overTimer?.cancel();
        _overTimer = Timer(confirmAfter + _pause.longer, _carryOn);
    }
  }

  /// 进入「想一想」后盯着声音有没有响起来，超时就退回并说明原因。
  static const voiceStartTimeout = Duration(seconds: 8);

  void _watchVoice() {
    _voiceWatch?.cancel();
    final turn = _turn;
    _voiceWatch = Timer(voiceStartTimeout, () {
      // 已经离开这个回合了就别再插手。
      if (_phase != CallPhase.thinking || turn != _turn) return;
      if (_voiced) return;
      _error = '语音没能播放出来。检查手机的「文字转语音」是否装了中文语音包';
      _replyDone = true;
      _set(CallPhase.listening);
    });
  }

  void _cue() {
    // Only before any reply text: the cue's stream would take the place of her voice's.
    if (_cued || !cueStill) return;
    _cued = true;
    unawaited(thinkingCue?.call());
  }

  SpeechOut _newVoice() {
    final out = voice();
    final turn = _turn;
    _outSub = out.events.listen((event) {
      if (!identical(_out, out) || _phase == CallPhase.ended) return;
      switch (event) {
        case SpeechOutStarted():
          _voiced = true;
          _cueTimer?.cancel();
          _voiceWatch?.cancel();
          if (_phase == CallPhase.thinking || _phase == CallPhase.listening) _set(CallPhase.speaking);
        case SpeechOutLevel(:final value):
          _voiceLevel = value;
          _said = out.heard;
          notifyListeners();
        case SpeechOutDone():
          _said = out.heard;
          _clearVoice(out);
          if (_phase == CallPhase.speaking || (_phase == CallPhase.thinking && turn == _turn && _replyDone)) {
            _set(CallPhase.listening);
          }
        case SpeechOutFailed(:final error):
          _clearVoice(out);
          _voiced = false;
          _error = error;
          if (_phase == CallPhase.speaking || _phase == CallPhase.thinking) _set(CallPhase.listening);
      }
    });
    return out;
  }

  void _clearVoice(SpeechOut out) {
    if (!identical(_out, out)) return;
    _out = null;
    unawaited(_outSub?.cancel());
    _outSub = null;
    _voiceLevel = 0;
  }

  void _stopVoice() {
    final out = _out;
    if (out == null) return;
    _clearVoice(out);
    out.stop();
  }

  /// The microphone hears nothing (and nothing is recorded) while muted.
  void setMuted(bool on) {
    if (_phase == CallPhase.ended) return;
    _muted = on;
    _micLevel = 0;
    unawaited(audio.mute(on));
    if (on && _phase == CallPhase.hearing) _set(CallPhase.listening);
    notifyListeners();
  }

  /// Changed in 通话设置: the next pause is judged by it (the one under way too).
  void setPause(CallPause pause) {
    if (_phase == CallPhase.ended || pause == _pause) return;
    _pause = pause;
    // Talking over her right now: the deadline moves with the pause, from when they began.
    if (_overTimer?.isActive ?? false) {
      _overTimer!.cancel();
      final left = confirmAfter + pause.longer - _overFor.elapsed;
      _overTimer = Timer(left.isNegative ? Duration.zero : left, _cutIn);
    }
    // Before the microphone is open this changes nothing there; startCall takes [_pause].
    unawaited(audio.callPause(pause));
  }

  Future<void> setSpeaker(bool on) async {
    if (_phase == CallPhase.ended) return;
    _speaker = await audio.speaker(on);
    notifyListeners();
  }

  /// Tapped while she speaks: she stops, the reply goes on in the conversation.
  /// Before she has begun (her voice about to be tried out on the same
  /// speaker), she won't read this reply at all.
  void skip() {
    if (_phase != CallPhase.speaking && _phase != CallPhase.thinking) return;
    // Thinking may still be making out what was said: that reply stays quiet too.
    if (_phase == CallPhase.thinking) _hushed = _recognizing;
    _cueTimer?.cancel();
    _stopVoice();
    // The rest is there to read.
    _voiced = false;
    _replyDone = true;
    _set(CallPhase.listening);
  }

  void hangUp() => _end(CallEnd.hungUp);

  /// The app went to the background: Android gives a backgrounded app no
  /// microphone, so the call ends rather than listen to silence.
  void backgrounded() {
    if (!_asking) _end(CallEnd.background);
  }

  void _end(CallEnd why) {
    if (_phase == CallPhase.ended) return;
    unawaited(const DiagnosticsChannel().recordVoiceStage('call_ended', code: why.index));
    _ended = why;
    _overTimer?.cancel();
    _cueTimer?.cancel();
    _voiceWatch?.cancel();
    _stopVoice();
    unawaited(audio.stopCall());
    unawaited(_replySub?.cancel());
    unawaited(_audioSub?.cancel());
    _set(CallPhase.ended);
  }

  void _set(CallPhase phase) {
    if (_phase != phase && phase == CallPhase.listening) {
      _startedAt ??= DateTime.now();
      unawaited(const DiagnosticsChannel().recordVoiceStage('listening'));
    }
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    // Quiet first: the page is going away and listens no more.
    _disposed = true;
    _end(CallEnd.hungUp);
    conversation.dispose();
    super.dispose();
  }
}

/// What was said could not be sent (no engine, the conversation is busy elsewhere).
class CallSendFailed implements Exception {
  const CallSendFailed();
}
