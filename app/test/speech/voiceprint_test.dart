// 声纹白名单：三态、取最大、去重、阈值随人数补偿。
//
//   flutter test test/speech/voiceprint_test.dart

import 'dart:typed_data';

import 'package:dsh_app/speech/voiceprint_store.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List vec(List<double> values) {
  final v = Float32List(values.length);
  for (var i = 0; i < values.length; i++) {
    v[i] = values[i];
  }
  return v;
}

/// 单位向量：给一个小角度，用来造"同一个人"和"另一个人"。
Float32List unit(double x, double y) {
  final n = (x * x + y * y);
  final d = n == 0 ? 1.0 : _sqrt(n);
  return vec([x / d, y / d]);
}

double _sqrt(double v) {
  var x = v;
  for (var i = 0; i < 40; i++) {
    x = 0.5 * (x + v / x);
  }
  return x;
}

VoiceProfile profile(String id, Float32List v) =>
    VoiceProfile(id: id, createdAt: DateTime(2026, 11, 18), vector: v);

void main() {
  group('余弦', () {
    test('同一个向量是 1', () {
      final v = unit(1, 1);
      expect(VoiceprintStore.cosine(v, v), closeTo(1.0, 1e-9));
    });

    test('垂直是 0，相反是 -1', () {
      expect(VoiceprintStore.cosine(vec([1, 0]), vec([0, 1])), closeTo(0.0, 1e-9));
      expect(VoiceprintStore.cosine(vec([1, 0]), vec([-1, 0])), closeTo(-1.0, 1e-9));
    });

    test('长度不等返回 -1，当作没法比', () {
      expect(VoiceprintStore.cosine(vec([1, 0]), vec([1, 0, 0])), -1);
    });

    test('全零向量返回 -1，不能除零', () {
      expect(VoiceprintStore.cosine(vec([0, 0]), vec([1, 0])), -1);
    });
  });

  group('取最大（多模板）', () {
    test('三个人里有一个像，就算像', () {
      final a = profile('a', unit(1, 0));
      final b = profile('b', unit(0, 1));
      final c = profile('c', unit(-1, 0));
      // 和 b 同向：只有 b 分数高。
      final sample = unit(0, 1);
      final closest = VoiceprintStore.closest([a, b, c], sample);
      expect(closest.match?.id, 'b');
      expect(closest.score, closeTo(1.0, 1e-9));
    });

    test('都不像时取最高的那个，分数仍然低', () {
      final a = profile('a', unit(1, 0));
      final b = profile('b', unit(0, 1));
      final sample = unit(-1, -0.1);
      final closest = VoiceprintStore.closest([a, b], sample);
      expect(closest.score, lessThan(0.1), reason: '两个都不该像');
    });

    test('空名单不会崩，分数是 -1', () {
      final closest = VoiceprintStore.closest(const [], unit(1, 0));
      expect(closest.match, isNull);
      expect(closest.score, -1);
    });
  });

  group('去重', () {
    test('同一个人录两次会被拦下', () {
      // 同一个方向，细微抖动：真实场景里两次录音不会逐位相同。
      final first = profile('first', unit(1, 0.02));
      final again = unit(1, 0.04);
      final closest = VoiceprintStore.closest([first], again);
      expect(closest.score, greaterThan(VoiceprintStore.duplicateAt),
          reason: '同一个人的两次录入必须超过去重线');
    });

    test('不同的人不会被误判成重复', () {
      final first = profile('first', unit(1, 0));
      final other = unit(0.2, 1);
      final closest = VoiceprintStore.closest([first], other);
      expect(closest.score, lessThan(VoiceprintStore.duplicateAt),
          reason: '差得多的人要能录进来，否则白名单永远只有一个人');
    });

    test('去重线是 0.85', () {
      expect(VoiceprintStore.duplicateAt, 0.85);
    });
  });

  group('序列化', () {
    test('存进去再读出来，向量一位不差', () {
      final original = profile('p1', vec([0.1, -0.25, 0.5, 0.75]));
      final restored = VoiceProfile.fromJson(original.toJson());
      expect(restored, isNotNull);
      expect(restored!.id, 'p1');
      expect(restored.vector.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(restored.vector[i], closeTo(original.vector[i], 1e-6));
      }
    });

    test('坏数据不算一条，返回 null 而不是抛', () {
      expect(VoiceProfile.fromJson(null), isNull);
      expect(VoiceProfile.fromJson(<String, Object?>{}), isNull);
      expect(VoiceProfile.fromJson({'id': 'x', 'createdAt': 1, 'vector': 'not-base64!!'}), isNull);
    });

    test('备注可以不填', () {
      final p = profile('p2', vec([1, 0]));
      expect(p.label, isEmpty);
      expect(p.copyWith(label: '我').label, '我');
    });
  });

  group('上限', () {
    test('最多 5 个', () {
      expect(VoiceprintStore.maxProfiles, 5);
    });
  });
}
