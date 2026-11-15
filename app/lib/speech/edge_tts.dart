// Speaking with Microsoft's Edge voice: the same free service the browser's
// read-aloud uses, reached over the websocket it exposes to its own extension.
// No key, no account; the audio is 24 kHz mono mp3 and arrives in chunks while
// the sentence is still being synthesized.
//
// This speaks the websocket protocol itself instead of using dart:io's
// WebSocket: HttpClient treats Connection and Upgrade as protected headers and
// silently drops them, so the service answered every upgrade with 403
// "Invalid Request". A raw socket sends exactly the bytes a browser would.
//
// Nothing here is documented by Microsoft, so it is pinned to what the Edge
// extension sends. If they close it, this stops working; other sources are
// unaffected.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// One voice of the service, as it names them.
class EdgeVoice {
  const EdgeVoice(this.id, this.label, this.lang);
  final String id;
  final String label;
  final String lang;
}

/// The Chinese and English voices worth offering; the service has many more.
const edgeVoices = <EdgeVoice>[
  EdgeVoice('zh-CN-XiaoxiaoNeural', 'Xiaoxiao', 'zh-CN'),
  EdgeVoice('zh-CN-XiaoyiNeural', 'Xiaoyi', 'zh-CN'),
  EdgeVoice('zh-CN-YunxiNeural', 'Yunxi', 'zh-CN'),
  EdgeVoice('zh-CN-YunyangNeural', 'Yunyang', 'zh-CN'),
  EdgeVoice('zh-CN-liaoning-XiaobeiNeural', 'Xiaobei', 'zh-CN'),
  EdgeVoice('zh-TW-HsiaoChenNeural', 'HsiaoChen', 'zh-TW'),
  EdgeVoice('en-US-AriaNeural', 'Aria', 'en-US'),
  EdgeVoice('en-US-GuyNeural', 'Guy', 'en-US'),
];

const edgeDefaultVoice = 'zh-CN-XiaoyiNeural';

class EdgeTtsError implements Exception {
  const EdgeTtsError(this.reason);
  final String reason;

  @override
  String toString() => 'EdgeTtsError($reason)';
}

const _host = 'speech.platform.bing.com';
const _basePath = '/consumer/speech/synthesize/readaloud/edge/v1';
const _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const _origin = 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';

/// The service signs every request with a token derived from the clock; without
/// it the upgrade is answered 403. Pinned to msedge-tts 2.1.1, which is the
/// client that works.
///
/// The phone's clock can be minutes off (one here was 30 minutes fast), and a
/// signature from the wrong minute is refused, so the offset is read from the
/// server's own Date header once per run.
Duration? _clockOffset;

Future<Duration> _serverOffset() async {
  final known = _clockOffset;
  if (known != null) return known;
  try {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('https://$_host$_basePath'));
    final response = await request.close();
    await response.drain<void>();
    final date = response.headers.value(HttpHeaders.dateHeader);
    client.close(force: true);
    if (date != null) {
      final server = HttpDate.parse(date);
      return _clockOffset = server.difference(DateTime.now().toUtc());
    }
  } on Object {
    // No header to trust: keep the phone's own clock.
  }
  return _clockOffset = Duration.zero;
}

String _secMsGec(Duration offset) {
  final now = DateTime.now().toUtc().add(offset);
  final seconds = now.millisecondsSinceEpoch ~/ 1000 + 11644473600;
  final rounded = seconds - seconds % 300;
  final ticks = rounded * 10000000;
  final message = utf8.encode('Copyright (C) Microsoft Corporation. All rights reserved.$ticks$_token');
  final digest = crypto.sha256.convert(message).bytes;
  final cs = _cs64(message, digest);
  return '${_hex(cs)}-${_hex(digest)}';
}

const _swapFirstWord = [4010109435, 1995771700, 3287280279];
const _swapSecondWord = [3273069531, 411160124, 901586633];
const _mixFirstWord = [3482890513, 2265471903, 315537773, 629022083];
const _mixSecondWord = [2725517045, 3548616447, 2090019721, 3215236969];

/// Eight bytes of checksum, little endian (msedge-tts SecMsGec.cs64).
Uint8List _cs64(List<int> message, List<int> digest) {
  final digestView = ByteData.sublistView(Uint8List.fromList(digest));
  final firstKey = digestView.getUint32(0, Endian.little) | 1;
  final secondKey = digestView.getUint32(4, Endian.little) | 1;

  final padded = Uint8List(((message.length + 7) ~/ 8) * 8)..setAll(0, message);
  final words = ByteData.sublistView(padded);

  var swapSum = 0;
  var lastSwap = 0;
  var mix = 0;
  var mixSum = 0;

  for (var offset = 0; offset < padded.length; offset += 8) {
    final firstWord = words.getUint32(offset, Endian.little);
    final secondWord = words.getUint32(offset + 4, Endian.little);
    final firstSwap = _swapTerm(firstWord, firstKey, _swapFirstWord);
    lastSwap = _swapTerm(secondWord, secondKey, _swapSecondWord);
    swapSum = (swapSum + firstSwap + lastSwap) & _u32;

    mix = _swapAndMultiply(_mul(mix + firstWord, firstKey), _mixFirstWord);
    mixSum = (mixSum + mix) & _u32;
    mix = _swapAndMultiply(_mul(mix + secondWord, secondKey), _mixSecondWord);
    mixSum = (mixSum + mix) & _u32;
  }

  final out = ByteData(8);
  out.setUint32(0, (lastSwap ^ mix) & _u32, Endian.little);
  out.setUint32(4, (swapSum ^ mixSum) & _u32, Endian.little);
  return out.buffer.asUint8List();
}

int _swapTerm(int word, int key, List<int> multipliers) {
  final sum = (_mul(word, key) + _mul(_swapHalves(word), multipliers[0])) & _u32;
  final product = _mul(_swapHalves(sum), multipliers[1]);
  return (_mul(_swapHalves(product), multipliers[2]) + product) & _u32;
}

int _swapAndMultiply(int value, List<int> multipliers) {
  var out = value;
  for (final multiplier in multipliers) {
    out = _mul(_swapHalves(out), multiplier);
  }
  return out;
}

int _swapHalves(int value) => ((value << 16) | (value >> 16)) & _u32;

/// 32-bit multiply, as Math.imul does it in the client this follows.
int _mul(int a, int b) => (a * b) & _u32;

const _u32 = 0xFFFFFFFF;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// Speaks [text] in [voice] and returns an mp3.
///
/// [rate] and [pitch] are the strings the service takes, such as '+10%' and
/// '-2Hz'.
Future<Uint8List> edgeSpeak(
  String text, {
  String voice = edgeDefaultVoice,
  String rate = '+10%',
  String pitch = '+0Hz',
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clean = text.trim();
  if (clean.isEmpty) throw const EdgeTtsError('nothing to say');

  final SecureSocket socket;
  try {
    socket = await SecureSocket.connect(_host, 443, timeout: const Duration(seconds: 15));
  } on Object catch (error) {
    throw EdgeTtsError('connect $error');
  }

  final audio = BytesBuilder(copy: false);
  final upgraded = Completer<void>();
  final finished = Completer<void>();
  final failure = Completer<String>();
  final buffer = <int>[];
  var handshakeDone = false;

  void handleFrame(_Frame frame) {
    switch (frame.opcode) {
      case 1:
        final message = utf8.decode(frame.payload, allowMalformed: true);
        if (message.contains('Path:turn.end')) {
          if (!finished.isCompleted) finished.complete();
        } else if (message.contains('Path:error')) {
          if (!failure.isCompleted) failure.complete(message);
        }
      case 2:
        final chunk = _audioOf(frame.payload);
        if (chunk.isNotEmpty) audio.add(chunk);
      case 8:
        if (!finished.isCompleted) finished.complete();
      case 9:
        _send(socket, 10, frame.payload);
    }
  }

  final subscription = socket.listen(
    (chunk) {
      buffer.addAll(chunk);
      if (!handshakeDone) {
        final end = _indexOfHeadEnd(buffer);
        if (end < 0) return;
        final head = latin1.decode(buffer.sublist(0, end));
        buffer.removeRange(0, end + 4);
        handshakeDone = true;
        if (!head.startsWith('HTTP/1.1 101')) {
          final status = head.split('\r\n').first;
          if (!upgraded.isCompleted) upgraded.completeError(EdgeTtsError('handshake $status'));
          return;
        }
        if (!upgraded.isCompleted) upgraded.complete();
      }
      while (true) {
        final frame = _readFrame(buffer);
        if (frame == null) break;
        handleFrame(frame);
      }
    },
    onError: (Object error) {
      if (!upgraded.isCompleted) {
        upgraded.completeError(EdgeTtsError('$error'));
      } else if (!failure.isCompleted) {
        failure.complete('$error');
      }
    },
    onDone: () {
      if (!upgraded.isCompleted) {
        upgraded.completeError(const EdgeTtsError('closed during handshake'));
      } else if (!finished.isCompleted && !failure.isCompleted) {
        finished.complete();
      }
    },
    cancelOnError: false,
  );

  try {
    final key = base64.encode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
    final connectionId = _uuid().replaceAll('-', '');
    final offset = await _serverOffset();
    final path =
        '$_basePath?TrustedClientToken=$_token'
        '&Sec-MS-GEC=${_secMsGec(offset)}'
        '&Sec-MS-GEC-Version=2-143.0.3650.96'
        '&ConnectionId=$connectionId';
    socket.write(
      'GET $path HTTP/1.1\r\n'
      'Host: $_host\r\n'
      'Connection: Upgrade\r\n'
      'Upgrade: websocket\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Pragma: no-cache\r\n'
      'Cache-Control: no-cache\r\n'
      'Origin: $_origin\r\n'
      'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0\r\n'
      'Accept-Language: en-US,en;q=0.9\r\n'
      'Accept-Encoding: gzip, deflate, br\r\n'
      '\r\n',
    );
    await socket.flush();
    await upgraded.future.timeout(const Duration(seconds: 15));

    final stamp = DateTime.now().toUtc().toIso8601String();
    _sendText(
      socket,
      'X-Timestamp:$stamp\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":'
      '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
    );

    final lang = edgeVoices.firstWhere((v) => v.id == voice, orElse: () => edgeVoices.first).lang;
    final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(clean);
    _sendText(
      socket,
      'X-RequestId:${_uuid()}\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:${stamp}Z\r\n'
      'Path:ssml\r\n\r\n'
      "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$lang'>"
      "<voice name='$voice'><prosody pitch='$pitch' rate='$rate' volume='+0%'>"
      '$escaped'
      '</prosody></voice></speak>',
    );

    final result = await Future.any<Object>([
      finished.future.then((_) => 'done'),
      failure.future,
      Future<Object>.delayed(timeout, () => 'timeout'),
    ]);
    if (result != 'done') throw EdgeTtsError('$result');
    final bytes = audio.takeBytes();
    if (bytes.isEmpty) throw const EdgeTtsError('empty reply');
    return bytes;
  } finally {
    await subscription.cancel();
    try {
      await socket.close();
    } on Object {
      // Already gone.
    }
  }
}

/// Offset just past the CRLFCRLF that ends the response head, or -1.
int _indexOfHeadEnd(List<int> buffer) {
  for (var i = 0; i + 3 < buffer.length; i++) {
    if (buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// A binary frame of this service: two bytes of header length, that header,
/// then the audio.
Uint8List _audioOf(List<int> payload) {
  if (payload.length < 2) return Uint8List(0);
  final headerLength = (payload[0] << 8) | payload[1];
  final start = 2 + headerLength;
  if (start >= payload.length) return Uint8List(0);
  return Uint8List.fromList(payload.sublist(start));
}

class _Frame {
  const _Frame(this.opcode, this.payload);
  final int opcode;
  final List<int> payload;
}

/// One frame off the wire, or null while it is still arriving.
_Frame? _readFrame(List<int> buffer) {
  if (buffer.length < 2) return null;
  final first = buffer[0];
  final second = buffer[1];
  final opcode = first & 0x0f;
  final masked = (second & 0x80) != 0;
  var length = second & 0x7f;
  var offset = 2;
  if (length == 126) {
    if (buffer.length < 4) return null;
    length = (buffer[2] << 8) | buffer[3];
    offset = 4;
  } else if (length == 127) {
    if (buffer.length < 10) return null;
    var big = 0;
    for (var i = 2; i < 10; i++) {
      big = (big << 8) | buffer[i];
    }
    length = big;
    offset = 10;
  }
  var maskOffset = -1;
  if (masked) {
    if (buffer.length < offset + 4) return null;
    maskOffset = offset;
    offset += 4;
  }
  if (buffer.length < offset + length) return null;
  final payload = buffer.sublist(offset, offset + length);
  if (maskOffset >= 0) {
    final mask = buffer.sublist(maskOffset, maskOffset + 4);
    for (var i = 0; i < payload.length; i++) {
      payload[i] ^= mask[i % 4];
    }
  }
  buffer.removeRange(0, offset + length);
  return _Frame(opcode, payload);
}

void _sendText(SecureSocket socket, String text) => _send(socket, 1, utf8.encode(text));

void _send(SecureSocket socket, int opcode, List<int> payload) {
  final random = Random.secure();
  final mask = List<int>.generate(4, (_) => random.nextInt(256));
  final header = <int>[0x80 | opcode];
  if (payload.length < 126) {
    header.add(0x80 | payload.length);
  } else if (payload.length < 65536) {
    header.add(0x80 | 126);
    header.add((payload.length >> 8) & 0xff);
    header.add(payload.length & 0xff);
  } else {
    header.add(0x80 | 127);
    for (var shift = 56; shift >= 0; shift -= 8) {
      header.add((payload.length >> shift) & 0xff);
    }
  }
  header.addAll(mask);
  final body = List<int>.generate(payload.length, (i) => payload[i] ^ mask[i % 4]);
  socket.add(header);
  socket.add(body);
}

String _uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
