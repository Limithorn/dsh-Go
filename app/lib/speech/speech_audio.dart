// Dart side of `dsh/speech` (android/.../speech/SpeechPlugin.kt): PCM streams
// played as they arrive, and the microphone during a voice call cut into
// utterances. One stream plays at a time; opening one stops the one before.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';

sealed class SpeechAudioEvent {
  const SpeechAudioEvent();
}

enum PlayPhase { start, done, stopped, error }

/// A stream started, played to its end, was stopped, or failed.
final class PlayEvent extends SpeechAudioEvent {
  const PlayEvent(this.id, this.phase);
  final String id;
  final PlayPhase phase;
}

/// How loud the stream [id] is right now (0–1), timed to what is heard.
final class PlayLevel extends SpeechAudioEvent {
  const PlayLevel(this.id, this.value);
  final String id;
  final double value;
}

/// The person started speaking; [over] the app's own voice (which, with
/// barge-in on, has already stopped).
final class SpeechStart extends SpeechAudioEvent {
  const SpeechStart({required this.over});
  final bool over;
}

/// 声纹对"开口的这个人"的结论。
enum VoiceprintKind {
  /// 白名单里的人。
  you,

  /// 明确不是白名单里的人。
  other,

  /// 分不出（落在不确定带里，或算得太少）。
  unknown;

  static VoiceprintKind parse(Object? raw) => switch (raw) {
    'you' => you,
    'other' => other,
    _ => unknown,
  };
}

/// 声纹对「刚开口的这个人」的判断，与 [SpeechStart] 分开到。
///
/// 为什么不是合在一起：speechStart 要立刻发（duck 不能等），而声纹要一段音频
/// 才算得出。所以先告诉 Dart「有人说话了」，再补一句「是谁」。
///
/// 功能关着、没有白名单、模型加载不了时**根本不会有这个事件**，Dart 走原路径。
final class SpeechJudge extends SpeechAudioEvent {
  const SpeechJudge({
    required this.over,
    required this.kind,
    required this.score,
    this.matched,
  });

  final bool over;
  final VoiceprintKind kind;
  final double score;
  final String? matched;
}

/// One utterance, as a 16 kHz mono WAV, once the person paused.
final class Utterance extends SpeechAudioEvent {
  const Utterance(this.wav, this.duration);
  final Uint8List wav;
  final Duration duration;
}

/// The microphone's level (0–1) during a call.
final class MicLevel extends SpeechAudioEvent {
  const MicLevel(this.value);
  final double value;
}

final class CallError extends SpeechAudioEvent {
  const CallError(this.reason);
  final String reason;
}

/// How long the person may pause before what they said counts as finished
/// (通话设置 → 停顿多久算说完): 快 is how calls were before it was a choice.
/// 插话灵敏度：只调「AI 正在说话」时把声音当成插话的门槛。
/// 防误触把门槛抬高，最不容易被 AI 自己的回声打断（代价是真插话要更明显）。
enum CallBargeSensitivity {
  sensitive(-6),
  normal(0),
  guarded(8),

  /// 更防误触：再抬高 6dB。适合外放、麦克风离扬声器近的机器。
  ///
  /// 这两档是为"被自己打断"补的：回声消不干净的手机上，光靠 AEC 的余量不够，
  /// 只能把"多响才算有人插话"抬得更高。代价是真要插话时得说得更清楚。
  resistant(14),

  /// 最防误触：几乎只认"明显压过自己声音"的插话。
  stubborn(20);

  const CallBargeSensitivity(this.offset);

  /// 传给原生 gate 的播放态门槛偏移（dB 档位，负=灵敏，正=迟钝）。
  final double offset;
}

/// 声纹认人的宽严：只影响「和白名单像不像」这条线，不碰任何现有的门控阈值。
///
/// 宽松更容易把你的声音认成自己人（也可能把旁人放进来），严格更不容易认错
/// （代价是你自己偶尔也会被挡在外面，要说得久一点）。
enum VoiceprintLevel {
  loose('loose'),
  normal('normal'),
  strict('strict'),

  /// 最严：只认"非常像"的。
  ///
  /// 给多人共用一台机器、或旁人声音和自己接近的场景。代价是本人说轻一点、
  /// 隔远一点就会被挡在外面。
  veryStrict('veryStrict');

  const VoiceprintLevel(this.wire);

  /// 传给原生的档位名，与 Kotlin 侧 Thresholds.Level 对应。
  final String wire;
}

/// 这台机器收进来的声音有多大——决定"有没有人在说"那条线画在哪。
///
/// 为什么需要这个：通话采集走 VOICE_COMMUNICATION + AEC（对的，声纹要和通话
/// 同分布），但 AEC 削掉多少跟机型、麦克风、外壳都有关。正常手机说话 RMS 约
/// −25dBFS，实测有的机器只有 −60dBFS，差 35dB。差这么多时，一条按正常电平
/// 定的绝对门限会把每一帧都判成静默，embed 返回 null，声纹根本没机会判。
///
/// 三档对应原生 `KaldiFbank.Silence` 的四组参数：
/// - [percentile] 取第几分位当"这段的底"
/// - [multiple] 比底高多少倍才算有人声（4.0 ≈ +6dB）
/// - [absoluteFloor] 只在底趋近 0 时兜底，正常不干预
/// - [voicedFraction] 要求多少比例的帧有声
///
/// 默认档 [normal] 就是原来的 0.20 / 4.0 / 1e-10 / 0.20，没换设备的人不受影响。
/// 通话时用哪一路声音来听人说话。
///
/// 两难：VOICE_COMMUNICATION 带 AEC（自己播的声音不会漏回来），但有些机器的
/// 这条通路降噪过狠。实测 Sony Xperia：通话峰值 −74.1 dBFS，而同一个麦克风
/// 走 VOICE_RECOGNITION 是 −20.8——差 53 dB，等于完全听不见人说话。
///
/// 那种机器上宁可不要 AEC 也得能听见人说话：代价是自己播放的声音会漏进来，
/// 靠「播放时抬线」和插话灵敏度去挡。
enum CallMicSource {
  /// 自动：启动时量两种音源，通话那路低太多就换掉。
  auto('auto', '自动'),
  communication('communication', '通话（带降噪）'),
  recognition('recognition', '识别（不降噪）');

  const CallMicSource(this.wire, this.label);

  final String wire;
  final String label;

  static CallMicSource of(String? wire) => switch (wire) {
    'communication' => CallMicSource.communication,
    'recognition' => CallMicSource.recognition,
    _ => CallMicSource.auto,
  };
}

enum VoiceprintMic {
  /// 正常手机：说话能到 −25dBFS 上下。
  normal('normal', percentile: 0.20, multiple: 4.0, absoluteFloor: 1e-10, voicedFraction: 0.20),

  /// 收得偏小：说话只有 −45dBFS 上下（旧手机的窄麦、厚壳、贴脸说的膜）。
  quiet('quiet', percentile: 0.30, multiple: 3.0, absoluteFloor: 1e-11, voicedFraction: 0.15),

  /// 收得极小：说话只有 −60dBFS 上下（AEC 削得狠的机器，就是实测那台）。
  ///
  /// 门限压到 1e-12：实测这种机器的静默底在 1.2e-10 ~ 3.3e-10，
  /// 而人声帧能到 1.4e-9 以上，绝对下限只要不高于底就完全交给相对判断。
  faint('faint', percentile: 0.30, multiple: 2.5, absoluteFloor: 1e-12, voicedFraction: 0.12);

  const VoiceprintMic(
    this.wire, {
    required this.percentile,
    required this.multiple,
    required this.absoluteFloor,
    required this.voicedFraction,
  });

  /// 传给原生的档位名。
  final String wire;

  /// 取第几分位当"这段的底"。
  final double percentile;

  /// 比底高多少倍才算有人声。
  final double multiple;

  /// 绝对下限，只防底趋近 0。
  final double absoluteFloor;

  /// 要有多少比例的帧有声，才算"这段真有人在说"。
  final double voicedFraction;

  /// 交给原生的那张表。
  Map<String, Object?> get wireArgs => {
    'percentile': percentile,
    'multiple': multiple,
    'absoluteFloor': absoluteFloor,
    'voicedFraction': voicedFraction,
  };
}

enum CallPause {
  quick(Duration.zero),
  normal(Duration(milliseconds: 400)),
  patient(Duration(milliseconds: 1000));

  const CallPause(this.longer);

  /// How much longer than 快 a finished utterance takes to come through
  /// (its trailing quiet: TurnPause.doneMs on the native side).
  final Duration longer;
}

/// 唤醒词灵敏度：直接改 sherpa KeywordSpotter 的 keywordsThreshold。
/// 低一点更容易被叫醒，但也更容易被相似音误唤醒；高一点要说得准，误唤醒少。
enum WakeSensitivity {
  sensitive(0.15),
  normal(0.25),
  strict(0.40);

  const WakeSensitivity(this.threshold);

  /// 判定命中的分数门槛（sherpa 的 keywordsThreshold，越高越难叫醒）。
  final double threshold;
}

enum CallStart { ok, permission, microphone, unavailable }

class SpeechAudio {
  SpeechAudio([MethodChannel? channel]) : this._(channel, false);
  SpeechAudio.ohos([MethodChannel? channel]) : this._(channel, true);

  SpeechAudio._(MethodChannel? channel, this.requiresSpeakerAck)
    : _channel = channel ?? const MethodChannel('dsh/speech') {
    _channel.setMethodCallHandler(_heard);
  }

  final MethodChannel _channel;
  final _events = StreamController<SpeechAudioEvent>.broadcast();

  /// OH rejects a retired or unavailable route. Its caller must retain that
  /// failure and commit only a current native acknowledgement.
  final bool requiresSpeakerAck;

  Stream<SpeechAudioEvent> get events => _events.stream;

  Future<void> _heard(MethodCall call) async {
    if (call.method != 'event') return;
    final args = call.arguments;
    if (args is! Map) return;
    double value() => ((args['value'] as num?) ?? 0).toDouble().clamp(0.0, 1.0);
    final event = switch (args['type']) {
      'play' => switch (PlayPhase.values.asNameMap()[args['what']]) {
        final phase? when args['id'] is String => PlayEvent(args['id'] as String, phase),
        _ => null,
      },
      'playLevel' when args['id'] is String => PlayLevel(args['id'] as String, value()),
      'speechStart' => SpeechStart(over: args['over'] == true),
      'speechJudge' => SpeechJudge(
        over: args['over'] == true,
        kind: VoiceprintKind.parse(args['verdict']),
        score: (args['score'] as num?)?.toDouble() ?? 0,
        matched: args['matched'] as String?,
      ),
      'utterance' when args['wav'] is Uint8List => Utterance(
        args['wav'] as Uint8List,
        Duration(milliseconds: (args['ms'] as num?)?.toInt() ?? 0),
      ),
      'micLevel' => MicLevel(value()),
      'callError' => CallError('${args['reason']}'),
      _ => null,
    };
    if (event != null && !_events.isClosed) _events.add(event);
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens stream [id] of PCM16 mono at [rate]; [call] plays it as the voice
  /// of a call, [levels] reports its loudness. False when it can't play.
  Future<bool> open(String id, {int rate = 24000, bool call = false, bool levels = false}) async =>
      await _invoke<bool>('open', {'id': id, 'rate': rate, 'call': call, 'levels': levels}) ?? false;

  /// Queues [bytes] on stream [id]; the bytes now waiting to play, or -1 when
  /// the stream is gone.
  Future<int> write(String id, Uint8List bytes) async => await _invoke<int>('write', {'id': id, 'bytes': bytes}) ?? -1;

  /// The bytes waiting to play on stream [id], or -1 when it is gone.
  Future<int> waiting(String id) async => await _invoke<int>('waiting', {'id': id}) ?? -1;

  /// Nothing more for [id]: it reports done once the last sample is heard.
  Future<void> end(String id) => _invoke<void>('end', {'id': id});

  Future<void> stop() => _invoke<void>('stop');

  /// OH's owned coordinator must observe a failed native retirement or EOF
  /// handoff. These use the existing channel protocol without swallowing errors.
  Future<void> stopChecked() => _channel.invokeMethod<void>('stop');
  Future<void> endChecked(String id) => _channel.invokeMethod<void>('end', {'id': id});

  /// Stream [id] quieter while the person may be speaking over it, or back to full.
  Future<void> duck(String id, bool on) => _invoke<void>('duck', {'id': id, 'on': on});

  Future<CallStart> startCall({
    required bool bargeIn,
    CallPause pause = CallPause.normal,
    CallBargeSensitivity sensitivity = CallBargeSensitivity.normal,
    CallMicSource micSource = CallMicSource.auto,
  }) async =>
      switch (await _invoke<String>('callStart', {
        'bargeIn': bargeIn,
        'pause': pause.name,
        'offset': sensitivity.offset,
        'micSource': micSource.wire,
      })) {
        'ok' => CallStart.ok,
        'permission' => CallStart.permission,
        'microphone' => CallStart.microphone,
        _ => CallStart.unavailable,
      };

  /// OH's call starts with the current mute choice before publishing any audio.
  /// Keeping this separate preserves existing startCall overrides and payloads.
  Future<CallStart> startCallMuted({
    required bool bargeIn,
    required bool muted,
    CallPause pause = CallPause.normal,
    CallBargeSensitivity sensitivity = CallBargeSensitivity.normal,
    CallMicSource micSource = CallMicSource.auto,
  }) async => switch (await _invoke<String>('callStart', {
    'bargeIn': bargeIn,
    'pause': pause.name,
    'muted': muted,
    'offset': sensitivity.offset,
    'micSource': micSource.wire,
  })) {
    'ok' => CallStart.ok,
    'permission' => CallStart.permission,
    'microphone' => CallStart.microphone,
    _ => CallStart.unavailable,
  };

  Future<void> stopCall() => _invoke<void>('callStop');
  Future<void> mute(bool on) => _invoke<void>('callMute', {'on': on});
  Future<void> bargeIn(bool on) => _invoke<void>('callBargeIn', {'on': on});

  /// How long a pause ends what the person says, from now on in this call.
  Future<void> callPause(CallPause pause) => _invoke<void>('callPause', {'pause': pause.name});

  /// Another player of the app's voice (the phone's own text-to-speech, a
  /// fetched file) started or stopped: the call listens more strictly meanwhile.
  Future<void> playing(bool on) => _invoke<void>('callPlaying', {'on': on});

  /// Loudspeaker or not; the answer is what is in effect.
  Future<bool> speaker(bool on) async {
    if (!requiresSpeakerAck) return await _invoke<bool>('callSpeaker', {'on': on}) ?? on;
    final accepted = await _channel.invokeMethod<bool>('callSpeaker', {'on': on});
    if (accepted == null) {
      throw PlatformException(code: 'speech-output', message: 'speaker acknowledgement missing');
    }
    return accepted;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }
}

final speechAudioProvider = Provider<SpeechAudio>((ref) {
  final audio = ref.watch(operatingSystemProvider) == 'ohos' ? SpeechAudio.ohos() : SpeechAudio();
  ref.onDispose(audio.dispose);
  return audio;
});
