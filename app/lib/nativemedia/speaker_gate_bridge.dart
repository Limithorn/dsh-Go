import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../speech/sherpa_speaker_embedder.dart';

import '../speech/voiceprint_store.dart' show VoiceProfile;

/// 白名单条目，送到原生做比对用：id 这里是 VoiceProfile.id，向量已归一化。
class GateProfile {
  const GateProfile({required this.id, required this.vector});

  final String id;
  final Float32List vector;
}

/// 原生声纹判定的一次结论（[VoiceprintKind] 定义在 speech_audio，语音事件那一层）。

/// 录入时录到的一段音频，连同它的几个质量指标。
class RecordedAudio {
  const RecordedAudio({
    required this.samples,
    required this.milliseconds,
    required this.loudness,
    required this.noisiness,
    required this.floor,
  });

  /// 16k mono，-1..1。
  final Float32List samples;
  final int milliseconds;

  /// RMS 的 dBFS；低于 -38 算太小声。
  final double loudness;

  /// 能量抖动比；高于 1.2 算有点吵。
  final double noisiness;

  /// 这段录音的环境底噪（dBFS），开头几百毫秒学到的。
  final double floor;

  /// 说话时比环境高多少分贝。安静房间说正常音量，这个值通常 15–25。
  double get snr => loudness - floor;
}

/// 声纹的原生侧：下发白名单与门槛、读回判定。
///
/// 通道复用 `dsh/speech`（同一支 MethodChannel，通话已经在用）。
/// 判定结果不走这里，而是和别的语音事件一样从 `event` 通道来（见 SpeechJudge）。
class VoiceprintChannel {
  VoiceprintChannel([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/speech');

  final MethodChannel _channel;

  /// 把白名单和门槛交给原生。功能关掉时传 enabled=false，原生立刻回到直通。
  Future<void> configure({
    required bool enabled,
    required bool allowOthers,
    required String level,
    required List<VoiceProfile> profiles,
    bool wake = false,
  }) async {
    final accept = acceptFor(level, profiles.length);
    final reject = accept - _band;
    try {
      await _channel.invokeMethod<void>('voiceprintConfigure', {
        'enabled': enabled && profiles.isNotEmpty,
        'allowOthers': allowOthers,
        // 唤醒是否也认声音：与通话分开，因为唤醒判定频繁、误判代价不同。
        'wake': wake,
        'accept': accept,
        'reject': reject,
        'profiles': [
          for (final p in profiles)
            {'id': p.id, 'vector': Float32List.fromList(p.vector)},
        ],
      });
    } on PlatformException {
      // 没有原生侧（桌面、测试）：什么都不做，Dart 走原路径。
    } on MissingPluginException {
      // 同上。
    }
  }

  /// 只更新开关，不动白名单（通话中改设置时用）。
  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('voiceprintEnabled', {'enabled': enabled});
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  /// 引擎：sherpa-onnx 的 SpeakerEmbeddingExtractor。加载一次常驻。
  static SherpaSpeakerEmbedder? _embedder;
  static Future<SherpaSpeakerEmbedder?>? _loading;

  /// 预热（幂等）。用之前调一次，或让 [embed] 自己懒加载。
  static Future<SherpaSpeakerEmbedder?> prepare() {
    return _loading ??= () async {
      final base = await getApplicationSupportDirectory();
      final loaded = await SherpaSpeakerEmbedder.load('${base.path}/speaker');
      _embedder = loaded;
      return loaded;
    }();
  }

  /// 一段音频（16k mono，-1..1）→ 归一化声纹向量。
  ///
  /// **走 sherpa 而不是自己算 fbank**：上游的 fbank 和模型训练时完全一致，
  /// 自己写一份只要有一处偏差，输出就退化成噪声（实测：两个人得分几乎相同）。
  /// 真拿不到才退回原生那份，保证功能不至于整个不可用。
  Future<Float32List?> embed(Float32List samples) async {
    final sherpa = _embedder ?? await prepare();
    if (sherpa != null) {
      final v = sherpa.embed(samples);
      if (v != null) return v;
    }
    try {
      return await _channel.invokeMethod<Float32List>('voiceprintEmbed', {'samples': samples});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 开始录一段（与通话同一套采集配置）。返回 false 表示麦克风打不开。
  Future<bool> startRecording() async {
    try {
      return await _channel.invokeMethod<bool>('voiceprintRecordStart') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 结束录音并取回这一段。
  Future<RecordedAudio?> stopRecording() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('voiceprintRecordStop');
      if (raw == null) return null;
      final samples = raw['samples'];
      if (samples is! Float32List || samples.isEmpty) return null;
      return RecordedAudio(
        samples: samples,
        milliseconds: (raw['ms'] as num?)?.toInt() ?? 0,
        loudness: (raw['loudness'] as num?)?.toDouble() ?? -120,
        noisiness: (raw['noisiness'] as num?)?.toDouble() ?? 0,
        floor: (raw['floor'] as num?)?.toDouble() ?? -120,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 这一段是不是录过的人（唤醒用）。
  ///
  /// 判定放在原生：那边已经有模型和模板，锥度也按 [Thresholds.Gate.WAKE] 算好了。
  /// 算不出来、没开功能、音频太短——一律返回 true，宁可答应也不让人叫不应。
  Future<bool> isKnownVoice(Float32List samples) async {
    try {
      return await _channel.invokeMethod<bool>('voiceprintIsKnown', {
            'samples': samples,
          }) ??
          true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// 录音进行中的实时电平与底噪（都是 dBFS）。录音没在跑时读到的是旧值。
  Future<({double db, double floor})> level() async {
    const silent = (db: -120.0, floor: -120.0);
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('voiceprintLevel');
      if (raw == null) return silent;
      return (
        db: (raw['db'] as num?)?.toDouble() ?? -120,
        floor: (raw['floor'] as num?)?.toDouble() ?? -120,
      );
    } on PlatformException {
      return silent;
    } on MissingPluginException {
      return silent;
    }
  }

  /// 原生是否真的能跑声纹（模型加载成功且没被 NativeTrial 拦）。
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('voiceprintAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static const _band = 0.08;

  /// 与 Kotlin 侧 `Thresholds.accept` 同一条曲线，两边必须一致。
  ///
  /// 原生其实会自己按人数再算一遍；这里算一份是为了把值随配置一起送过去，
  /// 让「设置页改完立刻生效」不必等一次 round-trip。
  static double acceptFor(String level, int count) {
    final base = switch (level) {
      'loose' => 0.40,
      'strict' => 0.60,
      _ => 0.50,
    };
    final n = count < 1 ? 1 : count;
    final raised = base + 0.045 * math.log(n);
    return raised > 0.97 ? 0.97 : raised;
  }
}
