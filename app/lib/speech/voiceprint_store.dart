import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../nativemedia/speaker_gate_bridge.dart';

/// 白名单里的一位：一条录入的声纹。
///
/// 只存本机、加密存；不写进 [SharedPreferences]（那是明文，声纹是生物特征）。
/// 这份声纹是用哪种音源录的。
///
/// 三档对应原生 `VoiceprintRecorder.Source`。选哪个不影响录入本身，
/// 只影响"这份模板将来在哪种场景下认得最准"：
///
/// - [call] 通话（AEC + 降噪）——打断判定用的就是这一路
/// - [wake] 唤醒（不降噪、不消回声）——叫名字时用的是这一路
/// - [raw] 原始麦克风——不经任何处理，电平最高，留给对照用
enum VoiceProfileSource {
  call('call', '通话（有降噪）'),
  wake('wake', '唤醒（不降噪）'),
  raw('raw', '原始麦克风'),
  unprocessed('unprocessed', '未处理（绕过系统音效）');

  const VoiceProfileSource(this.wire, this.label);

  /// 给原生和存储用的名字。
  final String wire;

  /// 界面上显示的名字。
  final String label;

  /// 老数据没有这个字段，按通话算——那是之前唯一的采集方式。
  static VoiceProfileSource of(String? wire) => switch (wire) {
    'wake' => VoiceProfileSource.wake,
    'raw' => VoiceProfileSource.raw,
    _ => VoiceProfileSource.call,
  };
}

class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.createdAt,
    required this.vector,
    this.label = '',
    this.source = VoiceProfileSource.call,
    this.clipPath = '',
  });

  /// 稳定 id：录入那一刻生成，删除/覆盖都认它。
  final String id;

  /// 用户给的备注，可为空（界面上回落到「#1」这种编号）。
  final String label;

  final DateTime createdAt;

  /// 192 维、已 L2 归一化。
  final Float32List vector;

  /// 录入那一刻的原始录音（wav 路径），可回放。
  ///
  /// 空串表示这份是旧版本录的、当时还没存音频——那种就放不了。
  /// 存这个的理由：排查"为什么认不出来"时，最需要知道的是"当时到底
  /// 录到了什么"。实测就遇到过录进去一半是空白、向量照算不误的情况。
  final String clipPath;

  /// 这份模板是用哪种音源录的。
  ///
  /// 同一句话，通话里（AEC + 降噪）和唤醒时（不处理）拿到的是两段电平差
  /// 十几 dB 的音频，向量自然对不上。录的时候选哪个音源，就决定这份模板
  /// 在哪种场景下认得更准——两种场景各录一份，才都认得出来。
  ///
  /// 旧数据没有这个字段，按 [VoiceProfileSource.call] 读——那是之前唯一的
  /// 采集方式，语义正好对上。
  final VoiceProfileSource source;

  VoiceProfile copyWith({String? label, VoiceProfileSource? source, String? clipPath}) => VoiceProfile(
    id: id,
    label: label ?? this.label,
    createdAt: createdAt,
    vector: vector,
    source: source ?? this.source,
    clipPath: clipPath ?? this.clipPath,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'vector': base64Encode(_bytesOf(vector)),
    'clip': clipPath,
    'source': source.wire,
  };

  static VoiceProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final at = raw['createdAt'];
    final vector = raw['vector'];
    if (id is! String || id.isEmpty || at is! int || vector is! String) return null;
    try {
      final bytes = base64Decode(vector);
      final floats = _floatsOf(bytes);
      if (floats.isEmpty) return null;
      return VoiceProfile(
        id: id,
        label: raw['label'] is String ? raw['label'] as String : '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(at),
        vector: floats,
        source: VoiceProfileSource.of(raw['source'] as String?),
        clipPath: raw['clip'] is String ? raw['clip'] as String : '',
      );
    } on Object {
      return null;
    }
  }

  static Uint8List _bytesOf(Float32List values) {
    final view = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      view.setFloat32(i * 4, values[i], Endian.little);
    }
    return view.buffer.asUint8List();
  }

  static Float32List _floatsOf(Uint8List bytes) {
    final count = bytes.length ~/ 4;
    final view = ByteData.sublistView(bytes);
    final out = Float32List(count);
    for (var i = 0; i < count; i++) {
      out[i] = view.getFloat32(i * 4, Endian.little);
    }
    return out;
  }
}

/// 白名单：最多 [maxProfiles] 条，加密存在本机。
///
/// 为什么不用 SharedPreferences：那里是明文 JSON，别人拿到设备或备份就能读走
/// 声纹。走 [FlutterSecureStorage]，键由系统 keystore 保护。这里沿用
/// CloudAsrController 存 API key 的同一套。
class VoiceprintStore {
  VoiceprintStore({FlutterSecureStorage? secure}) : _secure = secure ?? const FlutterSecureStorage();

  static const maxProfiles = 5;
  static const _key = 'speech_voiceprint_v1';

  /// 去重线：两条模板余弦高于它，就认为「这好像已经录过了」。
  static const duplicateAt = 0.85;

  final FlutterSecureStorage _secure;

  /// 上一次读取失败的原因；null 表示没失败过。
  ///
  /// 界面上要和"确实还没录"区分开：同样是空列表，一种是用户没录过，
  /// 一种是加密存储读不出来（换签名重装、keystore 失效）。后者静默返回
  /// 空列表会让人以为模板丢了、反复重录——所以把原因留在这里给诊断页看。
  String? lastReadError;

  Future<List<VoiceProfile>> read() async {
    lastReadError = null;
    try {
      final raw = await _secure.read(key: _key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        lastReadError = '存的不是列表';
        return const [];
      }
      final out = decoded.map(VoiceProfile.fromJson).whereType<VoiceProfile>().take(maxProfiles).toList();
      if (out.isEmpty && decoded.isNotEmpty) lastReadError = '${decoded.length} 条都解析失败了';
      return out;
    } on Object catch (e) {
      // 读不出来（换机、keystore 失效）：当作还没有，不影响通话。
      lastReadError = e.toString().split('\n').first;
      return const [];
    }
  }

  Future<void> write(List<VoiceProfile> profiles) async {
    final trimmed = profiles.take(maxProfiles).toList();
    await _secure.write(key: _key, value: jsonEncode(trimmed.map((p) => p.toJson()).toList()));
  }

  Future<List<VoiceProfile>> add(VoiceProfile profile) async {
    final all = await read();
    if (all.length >= maxProfiles) return all;
    final next = [...all, profile];
    await write(next);
    return next;
  }

  Future<List<VoiceProfile>> remove(String id) async {
    final next = (await read()).where((p) => p.id != id).toList();
    await write(next);
    return next;
  }

  Future<List<VoiceProfile>> replace(String id, VoiceProfile profile) async {
    final next = [
      for (final p in await read()) p.id == id ? profile : p,
    ];
    await write(next);
    return next;
  }

  Future<void> clear() async {
    // 删就是删干净，不留副本（钥匙串里那条也一并清掉）。
    await _secure.delete(key: _key);
  }

  /// 和已有模板比一次：返回最像的那条与相似度。去重、自检都用它。
  static ({VoiceProfile? match, double score}) closest(List<VoiceProfile> profiles, Float32List candidate) {
    VoiceProfile? best;
    var bestScore = -1.0;
    for (final p in profiles) {
      final cos = cosine(candidate, p.vector);
      if (cos > bestScore) {
        bestScore = cos;
        best = p;
      }
    }
    return (match: best, score: bestScore);
  }

  static double cosine(Float32List a, Float32List b) {
    if (a.isEmpty || a.length != b.length) return -1;
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    final d = na * nb;
    if (d <= 0) return -1;
    return dot / math.sqrt(d);
  }

  /// 把已存的模板转成原生要的形状（id + 归一化向量）。
  static List<GateProfile> toGate(List<VoiceProfile> profiles) =>
      [for (final p in profiles) GateProfile(id: p.id, vector: p.vector)];
}

/// 白名单的响应式来源：设置页改完自动 reload，通话侧读同一份。
class VoiceprintListController extends AsyncNotifier<List<VoiceProfile>> {
  VoiceprintStore get _store => ref.watch(voiceprintStoreProvider);

  @override
  Future<List<VoiceProfile>> build() => _store.read();

  /// 模板读不出来时的原因（null = 没读失败过，空列表就是真没录）。
  String? get readError => _store.lastReadError;

  Future<void> add(VoiceProfile profile) async {
    state = AsyncData(await _store.add(profile));
  }

  Future<void> remove(String id) async {
    state = AsyncData(await _store.remove(id));
  }

  Future<void> rename(String id, String label) async {
    final all = await _store.read();
    final target = all.where((p) => p.id == id).firstOrNull;
    if (target == null) return;
    state = AsyncData(await _store.replace(id, target.copyWith(label: label)));
  }

  Future<void> clear() async {
    await _store.clear();
    state = const AsyncData([]);
  }
}

final voiceprintStoreProvider = Provider<VoiceprintStore>((_) => VoiceprintStore());

final voiceprintProfilesProvider =
    AsyncNotifierProvider<VoiceprintListController, List<VoiceProfile>>(VoiceprintListController.new);

/// 本机能不能跑声纹（模型加载成功、ONNX Runtime 没在别处崩过）。
///
/// 不能跑时设置页要把开关置灰并说明，**不能假开**：开了却始终判不出来，
/// 用户会以为"这功能没用"。
final voiceprintSupportProvider = FutureProvider<bool>((ref) => VoiceprintChannel().available());
