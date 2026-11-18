import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../nativemedia/speaker_gate_bridge.dart';

/// 白名单里的一位：一条录入的声纹。
///
/// 只存本机、加密存；不写进 [SharedPreferences]（那是明文，声纹是生物特征）。
class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.createdAt,
    required this.vector,
    this.label = '',
  });

  /// 稳定 id：录入那一刻生成，删除/覆盖都认它。
  final String id;

  /// 用户给的备注，可为空（界面上回落到「#1」这种编号）。
  final String label;

  final DateTime createdAt;

  /// 192 维、已 L2 归一化。
  final Float32List vector;

  VoiceProfile copyWith({String? label}) =>
      VoiceProfile(id: id, label: label ?? this.label, createdAt: createdAt, vector: vector);

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'vector': base64Encode(_bytesOf(vector)),
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

  Future<List<VoiceProfile>> read() async {
    try {
      final raw = await _secure.read(key: _key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map(VoiceProfile.fromJson).whereType<VoiceProfile>().take(maxProfiles).toList();
    } on Object {
      // 读不出来（换机、keystore 失效）：当作还没有，不影响通话。
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
