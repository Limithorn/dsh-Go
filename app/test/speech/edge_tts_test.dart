// The Edge read-aloud protocol, offline: the websocket frame reader, the
// audio frame's header, the HTTP upgrade head, and the Sec-MS-GEC signature
// the handshake must carry. Nothing here opens a socket.

import 'dart:convert';

import 'package:dsh_app/speech/edge_tts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('edgeParseFrame', () {
    test('a small unmasked text frame: the opcode, the payload, the buffer drained', () {
      final buffer = <int>[0x81, 0x05, ...'hello'.codeUnits];
      final frame = edgeParseFrame(buffer);
      expect(frame!.opcode, 1);
      expect(utf8.decode(frame.payload), 'hello');
      expect(buffer, isEmpty);
    });

    test('a masked binary frame comes back unmasked', () {
      const payload = [1, 2, 3, 4, 5];
      const mask = [0x0f, 0x00, 0xff, 0x55];
      final bytes = <int>[
        0x82, 0x80 | payload.length,
        ...mask,
        for (var i = 0; i < payload.length; i++) payload[i] ^ mask[i % 4],
      ];
      final frame = edgeParseFrame(bytes);
      expect(frame!.opcode, 2);
      expect(frame.payload, payload);
    });

    test('lengths past 125 take the 16-bit form, past 65535 the 64-bit one', () {
      final medium = List<int>.filled(200, 7);
      var bytes = <int>[0x82, 126, (200 >> 8) & 0xff, 200 & 0xff, ...medium];
      var frame = edgeParseFrame(bytes);
      expect(frame!.opcode, 2);
      expect(frame.payload.length, 200);
      expect(frame.payload.every((b) => b == 7), isTrue);

      final long = List<int>.filled(70000, 1);
      bytes = [
        0x81, 127,
        for (var shift = 56; shift >= 0; shift -= 8) (70000 >> shift) & 0xff,
        ...long,
      ];
      frame = edgeParseFrame(bytes);
      expect(frame!.opcode, 1);
      expect(frame.payload.length, 70000);
    });

    test('a frame still arriving is null until its last byte: header, then payload', () {
      final bytes = <int>[0x82, 126, 0x01, 0x00]; // claims 256 bytes
      expect(edgeParseFrame(bytes), isNull);
      bytes.addAll(List<int>.filled(255, 9));
      expect(edgeParseFrame(bytes), isNull); // one short
      bytes.add(9);
      final frame = edgeParseFrame(bytes);
      expect(frame!.payload.length, 256);
      expect(bytes, isEmpty);
    });

    test('two frames in one buffer come off in order', () {
      final buffer = <int>[0x81, 0x02, 0x41, 0x42, 0x82, 0x01, 0xff];
      final first = edgeParseFrame(buffer);
      final second = edgeParseFrame(buffer);
      expect(utf8.decode(first!.payload), 'AB');
      expect(second!.opcode, 2);
      expect(second.payload, [0xff]);
      expect(buffer, isEmpty);
    });
  });

  group('edgeAudioOf', () {
    test('two header bytes and that header come off; what is left is sound', () {
      expect(edgeAudioOf([0x00, 0x03, 65, 66, 67, 1, 2, 3]), [1, 2, 3]);
      expect(edgeAudioOf([0x00, 0x00, 9, 9]), [9, 9]);
    });

    test('nothing to play when the header is all there is', () {
      expect(edgeAudioOf([0x00, 0x04, 65]), isEmpty);
      expect(edgeAudioOf([0x00, 0x02]), isEmpty);
      expect(edgeAudioOf([]), isEmpty);
    });
  });

  group('edgeHeadEndAt', () {
    test('just past the CRLFCRLF that ends the 101 head', () {
      final head = utf8.encode('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n');
      final buffer = <int>[...head, 0x82, 0x01, 0x00];
      final end = edgeHeadEndAt(buffer);
      expect(utf8.decode(buffer.sublist(0, end)), 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket');
      expect(buffer[end], 13); // the \r of the empty line: frames start at end + 4
    });

    test('no empty line yet: -1, also when only part of it arrived', () {
      expect(edgeHeadEndAt(utf8.encode('HTTP/1.1 101\r\nUpgrade: websocket\r\n')), -1);
      expect(edgeHeadEndAt(utf8.encode('HTTP/1.1 101\r\n\r')), -1);
      expect(edgeHeadEndAt(<int>[]), -1);
    });
  });

  group('edgeSecMsGecAt', () {
    // 11644473600, the Windows epoch in seconds, is a whole number of 300s,
    // so the signature's buckets line up with UTC's own five-minute marks.
    // Base sits 50 seconds inside one.
    final base = DateTime.fromMillisecondsSinceEpoch(300 * 1000 * 1234567 + 50 * 1000, isUtc: true);

    test('the shape the service asks for: 8 hex of checksum, a dash, 64 of digest', () {
      expect(
        RegExp(r'^[0-9A-F]{16}-[0-9A-F]{64}$').hasMatch(edgeSecMsGecAt(Duration.zero, base)),
        isTrue,
      );
    });

    test('the same bucket signs the same; the buckets are five minutes wide', () {
      expect(
        edgeSecMsGecAt(Duration.zero, base),
        edgeSecMsGecAt(Duration.zero, base.add(const Duration(seconds: 100))),
      );
      expect(
        edgeSecMsGecAt(Duration.zero, base),
        isNot(edgeSecMsGecAt(Duration.zero, base.add(const Duration(seconds: 251)))),
      );
    });

    test('a server clock offset signs like a clock that much later', () {
      expect(
        edgeSecMsGecAt(const Duration(seconds: 10), base),
        edgeSecMsGecAt(Duration.zero, base.add(const Duration(seconds: 10))),
      );
      // Still inside the same bucket, so the phone's minutes-off clock and the
      // server's own agree once the offset is applied.
      expect(
        edgeSecMsGecAt(const Duration(minutes: -3), base),
        edgeSecMsGecAt(Duration.zero, base.subtract(const Duration(minutes: 3))),
      );
    });
  });

  group('edgeSpeak', () {
    test('nothing to say is refused before any socket is opened', () async {
      await expectLater(
        edgeSpeak('   '),
        throwsA(
          isA<EdgeTtsError>().having((e) => e.reason, 'reason', 'nothing to say'),
        ),
      );
      await expectLater(edgeSpeak(''), throwsA(isA<EdgeTtsError>()));
    });
  });

  group('edgeVoices', () {
    test('the eight worth offering, the default among them, ids unique', () {
      expect(edgeVoices.length, 8);
      expect(edgeVoices.map((v) => v.id).toSet().length, edgeVoices.length);
      expect(edgeVoices.map((v) => v.id), contains(edgeDefaultVoice));
      expect(edgeDefaultVoice, 'zh-CN-XiaoyiNeural');
      expect(edgeVoices.where((v) => v.lang.startsWith('zh-')).length, 6);
      expect(edgeVoices.where((v) => v.lang.startsWith('en-')).length, 2);
    });
  });
}
