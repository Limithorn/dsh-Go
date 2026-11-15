// Speaking with Microsoft's Edge voice: the same free service the browser's
// read-aloud uses, reached over the websocket it exposes to its own extension.
// No key, no account; the audio is 24 kHz mono mp3 and comes back in chunks
// while the sentence is still being synthesized.
//
// Nothing here is documented by Microsoft, so it is pinned to what the Edge
// extension itself sends. If they close it, this stops working — the other
// sources are unaffected.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
  EdgeVoice('zh-CN-liaoning-XiaobeiNeural', 'Xiaobei (东北)', 'zh-CN'),
  EdgeVoice('zh-TW-HsiaoChenNeural', 'HsiaoChen (台湾)', 'zh-TW'),
  EdgeVoice('en-US-AriaNeural', 'Aria', 'en-US'),
  EdgeVoice('en-US-GuyNeural', 'Guy', 'en-US'),
];

const edgeDefaultVoice = 'zh-CN-XiaoxiaoNeural';

class EdgeTtsError implements Exception {
  const EdgeTtsError(this.reason);
  final String reason;

  @override
  String toString() => 'EdgeTtsError($reason)';
}

/// Speaks [text] in [voice] and returns an mp3.
///
/// [rate] and [pitch] are the percentage/Hz strings the service takes, such as
/// '+10%' and '-2Hz'.
Future<Uint8List> edgeSpeak(
  String text, {
  String voice = edgeDefaultVoice,
  String rate = '+0%',
  String pitch = '+0Hz',
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clean = text.trim();
  if (clean.isEmpty) throw const EdgeTtsError('nothing to say');

  final url =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
      '?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  final WebSocket socket;
  try {
    socket = await WebSocket.connect(
      url,
      headers: const {
        // What the Edge extension presents; without them the service answers
        // with a plain HTTP response instead of upgrading (seen as
        // `was not upgraded to websocket`).
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
      },
    ).timeout(timeout);
  } on Object catch (error) {
    throw EdgeTtsError('connect $error');
  }

  final audio = BytesBuilder(copy: false);
  final done = Completer<void>();
  final failed = Completer<String>();

  socket.listen(
    (message) {
      if (message is String) {
        if (message.contains('Path:turn.end')) {
          if (!done.isCompleted) done.complete();
        } else if (message.contains('Path:error')) {
          if (!failed.isCompleted) failed.complete(message);
        }
        return;
      }
      if (message is List<int>) {
        // Binary frames start with a two-byte big-endian header length, then
        // that header, then the audio itself.
        if (message.length < 2) return;
        final headerLength = (message[0] << 8) | message[1];
        final start = 2 + headerLength;
        if (start >= message.length) return;
        audio.add(message.sublist(start));
      }
    },
    onError: (Object error) {
      if (!failed.isCompleted) failed.complete('$error');
    },
    onDone: () {
      if (!done.isCompleted && !failed.isCompleted) done.complete();
    },
    cancelOnError: false,
  );

  void send(String payload) {
    final bytes = utf8.encode(payload);
    final head = ByteData(2)..setUint16(0, bytes.length);
    socket.add(head.buffer.asUint8List());
    socket.add(bytes);
  }

  final stamp = DateTime.now().toUtc().toIso8601String();
  send(
    'X-Timestamp:$stamp\r\n'
    'Content-Type:application/json; charset=utf-8\r\n'
    'Path:speech.config\r\n\r\n'
    '{"context":{"synthesis":{"audio":{"metadataoptions":'
    '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
    '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
  );

  final lang = edgeVoices.firstWhere((v) => v.id == voice, orElse: () => edgeVoices.first).lang;
  final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(clean);
  final requestId = _uuid();
  send(
    'X-RequestId:$requestId\r\n'
    'Content-Type:application/ssml+xml\r\n'
    'X-Timestamp:${stamp}Z\r\n'
    'Path:ssml\r\n\r\n'
    "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$lang'>"
    "<voice name='$voice'><prosody pitch='$pitch' rate='$rate' volume='+0%'>"
    '$escaped'
    '</prosody></voice></speak>',
  );

  try {
    final result = await Future.any<Object>([
      done.future.then((_) => 'done'),
      failed.future,
      Future<Object>.delayed(timeout, () => 'timeout'),
    ]).timeout(timeout + const Duration(seconds: 2));
    if (result != 'done') throw EdgeTtsError('$result');
    final bytes = audio.takeBytes();
    if (bytes.isEmpty) throw const EdgeTtsError('empty reply');
    return bytes;
  } finally {
    await socket.close();
  }
}

String _uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
