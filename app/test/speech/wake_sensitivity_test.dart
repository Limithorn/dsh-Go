import 'package:dsh_app/speech/speech_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the three wake levels raise the bar in order', () {
    // sherpa 的 keywordsThreshold：分数要到这个值才算命中。
    expect(WakeSensitivity.sensitive.threshold, lessThan(WakeSensitivity.normal.threshold));
    expect(WakeSensitivity.normal.threshold, lessThan(WakeSensitivity.strict.threshold));
  });

  test('normal is the sherpa default, so nothing changes for people who never look', () {
    expect(WakeSensitivity.normal.threshold, 0.25);
  });

  test('every level stays inside what sherpa accepts', () {
    for (final level in WakeSensitivity.values) {
      expect(level.threshold, inInclusiveRange(0.01, 0.99), reason: '${level.name} out of range');
    }
  });
}
