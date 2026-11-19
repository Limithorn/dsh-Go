// 设置 › 语音: whose voice reads replies aloud (the same choices as her voice
// in 伙伴小屋, DeepSeek's first), the cloud recognizer for 语音输入 when it
// isn't DeepSeek's, and how a 语音通话 behaves.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../companion/companion_voice_source.dart';
import '../secrets/secure_storage.dart';
import '../state/android_features.dart';
import 'speech_audio.dart';

const speechVoiceKeys = VoiceSettingsKeys(
  on: 'speech_voice_enabled',
  plain: 'speech_voice_v1',
  openaiKey: 'speech_voice_openai_key',
  headers: 'speech_voice_custom_headers',
  presetKeys: 'speech_voice_preset_keys',
);

/// The 朗读 voice: DeepSeek's until the person picks another. Its `on` is
/// unused (reading aloud is a button, not a switch).
class SpeechVoiceSettingsController extends VoiceOutputSettingsController {
  @override
  VoiceSettingsKeys get keys => speechVoiceKeys;

  @override
  CompanionVoiceSettings get defaults => const CompanionVoiceSettings(source: CompanionVoiceSource.deepseek);
}

final speechVoiceSettingsProvider = NotifierProvider<SpeechVoiceSettingsController, CompanionVoiceSettings?>(
  SpeechVoiceSettingsController.new,
);

/// Her voice as it is used: her own settings, or 朗读's when she follows them
/// (still only when she is switched on, and never cloned). On HarmonyOS the
/// room's speaker plays only the phone's own voice: an external one would be
/// fetched (and paid for) and then have no player.
final companionEffectiveVoiceProvider = Provider<CompanionVoiceSettings?>((ref) {
  final own = ref.watch(companionVoiceSettingsProvider);
  if (own != null && ref.watch(operatingSystemProvider) == 'ohos') {
    return own.copyWith(source: CompanionVoiceSource.system, follow: false, cloneOn: false);
  }
  if (own == null || !own.follow) return own;
  final shared = ref.watch(speechVoiceSettingsProvider);
  if (shared == null) return null;
  return shared.copyWith(on: own.on, follow: true, cloneOn: false);
});

// ── Cloud recognizer ───────────────────────────────────────────────────────

/// An OpenAI-compatible `/audio/transcriptions` service (OpenAI's Whisper,
/// SiliconFlow's SenseVoice, Groq, most self-hosted Whisper servers).
class CloudAsrSettings {
  const CloudAsrSettings({this.base = '', this.key = '', this.model = ''});

  final String base;
  final String key;
  final String model;

  bool get configured => base.trim().isNotEmpty && model.trim().isNotEmpty;

  CloudAsrSettings copyWith({String? base, String? key, String? model}) =>
      CloudAsrSettings(base: base ?? this.base, key: key ?? this.key, model: model ?? this.model);
}

class CloudAsrController extends Notifier<CloudAsrSettings> {
  static const _plainKey = 'speech_asr_cloud_v1';
  static const _secretKey = 'speech_asr_cloud_key';
  static const _secure = AppSecureStorage();
  late Future<void> _loaded;

  @override
  CloudAsrSettings build() {
    _loaded = _load();
    return const CloudAsrSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_plainKey);
      final json = raw == null ? null : jsonDecode(raw);
      var next = CloudAsrSettings(
        base: json is Map && json['base'] is String ? json['base'] as String : '',
        model: json is Map && json['model'] is String ? json['model'] as String : '',
      );
      try {
        next = next.copyWith(key: await _secure.read(key: _secretKey) ?? '');
      } on Object {
        // No keystore here: no key, nothing else lost.
      }
      if (ref.mounted) state = next;
    } on Object {
      // Unreadable: empty for this run.
    }
  }

  Future<CloudAsrSettings> ready() async {
    await _loaded;
    return state;
  }

  Future<void> update(CloudAsrSettings next) async {
    await _loaded;
    if (!ref.mounted) return;
    final before = state;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_plainKey, jsonEncode({'base': next.base.trim(), 'model': next.model.trim()}));
    if (before.key != next.key) {
      try {
        await _secure.write(key: _secretKey, value: next.key.trim());
      } on Object {
        // Kept for this run only.
      }
    }
  }
}

final cloudAsrProvider = NotifierProvider<CloudAsrController, CloudAsrSettings>(CloudAsrController.new);

// ── Calls ──────────────────────────────────────────────────────────────────

/// What a call shows behind its light: deep water, the person's own picture,
/// or her (伙伴小屋's character, speaking with the call's voice).
enum CallBackdrop { sea, image, companion }

/// The light in the middle of a call: the glass orb (the default), or
/// Libraries.dev's voice ring (a glassy ribbon in the theme's colours) or its single grey line.
enum CallVisual { ring, mono, glass }

class CallSettings {
  const CallSettings({
    this.bargeIn = true,
    this.spoken = true,
    this.speaker = true,
    this.backdrop = CallBackdrop.sea,
    this.image = '',
    this.cue = true,
    this.visual = CallVisual.glass,
    this.pause = CallPause.normal,
    this.sensitivity = CallBargeSensitivity.normal,
    this.voiceprint = false,
    this.voiceprintOthers = true,
    this.voiceprintLevel = VoiceprintLevel.normal,
    this.voiceprintBias = 0,
    this.voiceprintMic = VoiceprintMic.normal,
    this.voiceprintWake = false,
  });

  /// Speaking over her stops her (else what is said while she talks is ignored).
  final bool bargeIn;

  /// Each message of a call asks for a short, spoken answer without formatting.
  final bool spoken;

  /// Starts on the loudspeaker (a headset always wins).
  final bool speaker;
  final CallBackdrop backdrop;

  /// The picture for [CallBackdrop.image]: a copy this app keeps ('' for none).
  final String image;

  /// A soft chime when an answer is slow to start.
  final bool cue;

  /// The light in the middle.
  final CallVisual visual;

  /// How long a pause ends what the person says.
  final CallPause pause;

  /// How easily a sound while she talks is taken as an interruption; 防误触
  /// raises the bar so her own echo is less likely to stop her.
  final CallBargeSensitivity sensitivity;

  /// 只认这几个人的声音：播放期间旁人说话不打断播报。
  final bool voiceprint;

  /// 声纹开着时，白名单外的人能不能也打断（只是她反应会慢一拍）。
  ///
  /// 默认开：刚打开声纹时行为最接近以前，不会让人觉得"功能坏了"。
  final bool voiceprintOthers;

  /// 唤醒也认声音。
  ///
  /// 默认关：唤醒是常开的被动监听，判定次数远多于通话，误判的代价（没反应、
  /// 或被旁人唤醒）比通话里大。唤醒词本身已经是一道门槛，声纹是第二道。
  final bool voiceprintWake;

  /// 认得松还是严。
  final VoiceprintLevel voiceprintLevel;

  /// 在自己这台机器上再微调多少。
  ///
  /// [voiceprintLevel] 那三档是按"正常手机"定的，可 AEC 削掉多少分跟机型、
  /// 麦克风、外壳都有关。同一句"是我"，有的机器能到 0.7、有的只有 0.5。
  /// 这里让人按实测把线挪一点，不用去改代码里那张表。
  ///
  /// 单位就是余弦分：−0.20 ~ +0.20。0 表示完全按档位算。
  final double voiceprintBias;

  /// 这台机器收进来的声音有多大。
  ///
  /// 通话采集走 VOICE_COMMUNICATION + AEC——这是对的，声纹要和通话同分布——
  /// 但 AEC 削掉多少跟机型、麦克风、外壳都有关。正常手机说话 RMS 约 −25dBFS，
  /// 有的机器只有 −60dBFS，差 35dB。差这么多时，按正常电平定的"有没有人在说"
  /// 会把每一帧都判成静默，声纹直接失效（表现：谁都打断不了）。
  ///
  /// 与其写死一套数换台机器就坏，不如让人选"我这台机器收得小"。
  final VoiceprintMic voiceprintMic;

  CallSettings copyWith({
    bool? bargeIn,
    bool? spoken,
    bool? speaker,
    CallBackdrop? backdrop,
    String? image,
    bool? cue,
    CallVisual? visual,
    CallPause? pause,
    CallBargeSensitivity? sensitivity,
    bool? voiceprint,
    bool? voiceprintOthers,
    bool? voiceprintWake,
    VoiceprintLevel? voiceprintLevel,
    double? voiceprintBias,
    VoiceprintMic? voiceprintMic,
  }) => CallSettings(
    bargeIn: bargeIn ?? this.bargeIn,
    spoken: spoken ?? this.spoken,
    speaker: speaker ?? this.speaker,
    backdrop: backdrop ?? this.backdrop,
    image: image ?? this.image,
    cue: cue ?? this.cue,
    visual: visual ?? this.visual,
    pause: pause ?? this.pause,
    sensitivity: sensitivity ?? this.sensitivity,
    voiceprint: voiceprint ?? this.voiceprint,
    voiceprintOthers: voiceprintOthers ?? this.voiceprintOthers,
    voiceprintWake: voiceprintWake ?? this.voiceprintWake,
    voiceprintLevel: voiceprintLevel ?? this.voiceprintLevel,
    voiceprintBias: voiceprintBias ?? this.voiceprintBias,
    voiceprintMic: voiceprintMic ?? this.voiceprintMic,
  );
}

class CallSettingsController extends Notifier<CallSettings> {
  static const _key = 'speech_call_v1';
  late Future<void> _loaded;

  /// 声纹设置变了要通知谁。
  ///
  /// 用钩子而不是直接 import VoiceCallHost：那边已经 import 了本文件，
  /// 反过来再 import 会绕成环。这里只留一个口子，由 App 启动时填上。
  ///
  /// 为什么要有：声纹的配置只在"通话开始那一刻"推给原生，设置页改完不进
  /// 通话就永远送不到——诊断页上显示"设置 0.40 / 原生 0.50"，看着像开关
  /// 坏了，实际是压根没推。这是实测踩过的。
  static void Function(CallSettings previous, CallSettings next)? onVoiceprintChanged;

  @override
  CallSettings build() {
    _loaded = _load();
    return const CallSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final json = raw == null ? null : jsonDecode(raw);
      if (json is! Map || !ref.mounted) return;
      state = CallSettings(
        bargeIn: json['bargeIn'] != false,
        spoken: json['spoken'] != false,
        speaker: json['speaker'] != false,
        backdrop: CallBackdrop.values.asNameMap()[json['backdrop']] ?? CallBackdrop.sea,
        image: json['image'] is String ? json['image'] as String : '',
        cue: json['cue'] != false,
        visual: CallVisual.values.asNameMap()[json['visual']] ?? CallVisual.glass,
        pause: CallPause.values.asNameMap()[json['pause']] ?? CallPause.normal,
        sensitivity: CallBargeSensitivity.values.asNameMap()[json['sensitivity']] ?? CallBargeSensitivity.normal,
        voiceprint: json['voiceprint'] == true,
        voiceprintOthers: json['voiceprintOthers'] != false,
        voiceprintWake: json['voiceprintWake'] == true,
        voiceprintLevel: VoiceprintLevel.values.firstWhere(
          (l) => l.wire == json['voiceprintLevel'],
          orElse: () => VoiceprintLevel.normal,
        ),
        voiceprintBias: ((json['voiceprintBias'] as num?)?.toDouble() ?? 0).clamp(-0.20, 0.20),
        voiceprintMic: VoiceprintMic.values.firstWhere(
          (m) => m.wire == json['voiceprintMic'],
          orElse: () => VoiceprintMic.normal,
        ),
      );
    } on Object {
      // Defaults for this run.
    }
  }

  /// The settings once the saved ones have been read.
  Future<CallSettings> ready() async {
    await _loaded;
    return state;
  }

  /// [change] applied to the saved settings once they are in (not to the
  /// defaults shown before then).
  Future<void> edit(CallSettings Function(CallSettings saved) change) async {
    await _loaded;
    // Applied and taken in at once: another edit waiting too sees this one.
    if (ref.mounted) await _keep(change(state));
  }

  Future<void> update(CallSettings next) async {
    // After the saved settings are in: they never overwrite a change made meanwhile.
    await _loaded;
    if (ref.mounted) await _keep(next);
  }

  Future<void> _keep(CallSettings next) async {
    final previous = state;
    state = next;
    // 只在这几个字段真的变了时才通知：别的一个改动也常常走到这里。
    if (previous.voiceprint != next.voiceprint ||
        previous.voiceprintOthers != next.voiceprintOthers ||
        previous.voiceprintWake != next.voiceprintWake ||
        previous.voiceprintLevel != next.voiceprintLevel ||
        previous.voiceprintBias != next.voiceprintBias ||
        previous.voiceprintMic != next.voiceprintMic) {
      onVoiceprintChanged?.call(previous, next);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'bargeIn': next.bargeIn,
        'spoken': next.spoken,
        'speaker': next.speaker,
        'backdrop': next.backdrop.name,
        'image': next.image,
        'cue': next.cue,
        'visual': next.visual.name,
        'pause': next.pause.name,
        'sensitivity': next.sensitivity.name,
        'voiceprint': next.voiceprint,
        'voiceprintOthers': next.voiceprintOthers,
        'voiceprintWake': next.voiceprintWake,
        'voiceprintLevel': next.voiceprintLevel.wire,
        'voiceprintBias': next.voiceprintBias,
        'voiceprintMic': next.voiceprintMic.wire,
      }),
    );
  }
}

final callSettingsProvider = NotifierProvider<CallSettingsController, CallSettings>(CallSettingsController.new);
