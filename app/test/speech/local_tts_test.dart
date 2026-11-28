import 'dart:typed_data';

import 'package:dsh_app/speech/local_tts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('speakableForTts', () {
    test('English punctuation becomes the marks eSpeak reads', () {
      expect(speakableForTts('Hello, world. 你好。'), 'Hello，world。你好。');
      expect(speakableForTts('One, two. Three'), 'One，two。Three');
    });

    test('letters and digits survive; every other mark does not', () {
      expect(speakableForTts('第2版 v1.5'), '第2版 v1。5');
      expect(speakableForTts('你好😊世界'), '你好，世界');
    });

    test('runs of marks collapse, and a comma never sits next to a full stop', () {
      expect(speakableForTts('**重要**：明天 10:30 开会…'), '，重要，明天 10，30 开会，');
      expect(speakableForTts('好了. , 下一个'), '好了。下一个');
    });

    test('nothing eSpeak cannot read ever reaches it', () {
      final hostile = ['？？？？？', '“引号”《书名》', '∑∞ →done', 'a\tb\nc', '   '];
      final allowed = RegExp(r'^[\p{L}\p{N}，。\s]*$', unicode: true);
      for (final said in hostile) {
        expect(allowed.hasMatch(speakableForTts(said)), isTrue, reason: said);
      }
      expect(speakableForTts('   '), '');
    });
  });

  group('wavOf', () {
    test('float samples as a 16-bit mono WAV', () {
      final wav = wavOf(Float32List.fromList([0, 0.5, -0.5]), 16000);
      expect(wav.length, 44 + 6);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      final header = ByteData.sublistView(wav);
      expect(header.getUint32(4, Endian.little), 36 + 6);
      expect(header.getUint32(24, Endian.little), 16000); // the sample rate asked of it
      expect(header.getUint32(28, Endian.little), 32000); // byte rate: 16-bit mono
      expect(header.getUint16(32, Endian.little), 2); // one 16-bit sample at a time
      expect(header.getUint32(40, Endian.little), 6);
      final data = ByteData.sublistView(wav, 44);
      expect(data.getInt16(0, Endian.little), 0);
      expect(data.getInt16(2, Endian.little), 16384); // 0.5 → just over half
      expect(data.getInt16(4, Endian.little), -16384);
    });

    test('out-of-range floats clamp instead of wrapping', () {
      final wav = wavOf(Float32List.fromList([2, -2]), 24000);
      final data = ByteData.sublistView(wav, 44);
      expect(data.getInt16(0, Endian.little), 32767);
      expect(data.getInt16(2, Endian.little), -32767);
      expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 24000);
    });
  });

  group('LocalTtsPack', () {
    test('the pinned four-piece: URL, size, SHA-256, the unquantised model', () {
      expect(
        LocalTtsPack.url,
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2',
      );
      expect(LocalTtsPack.bytes, greaterThan(300 * 1024 * 1024)); // ~334 MB, downloaded once
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(LocalTtsPack.sha256), isTrue);
      expect(LocalTtsPack.model, 'model.onnx'); // not int8: a third of the size and metallic
      expect(LocalTtsPack.lexicon, 'lexicon-zh.txt'); // with the English one, or Chinese reads English phonemes
      expect(LocalTtsPack.chineseFemale, inInclusiveRange(45, 48)); // the Mandarin female sids
      expect(LocalTtsPack.chineseFemale, lessThan(LocalTtsPack.voiceCount));
    });
  });
}
