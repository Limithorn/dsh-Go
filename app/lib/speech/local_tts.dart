// Speaking on the phone itself: sherpa-onnx's Kokoro multi-language voice
// (Apache-2.0), everything offline. The pack is one tar.bz2 from the
// sherpa-onnx releases; it is fetched once, checked against its SHA-256,
// unpacked into the app's own folder and handed to OfflineTts.
//
// Both loading the model and generating a sentence take seconds, so they run in
// a dedicated isolate: on the UI isolate they block input long enough for the
// system to bring up "isn't responding" (which is what happened before this was
// split out). The main isolate only sends text and receives WAV bytes.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// The pinned pack: one archive, one hash.
class LocalTtsPack {
  const LocalTtsPack._();

  static const url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2';
  static const bytes = 349886476;
  static const sha256 = '60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4';

  /// The folder the archive unpacks into.
  static const folder = 'kokoro-multi-lang-v1_0';

  /// What OfflineTts needs, relative to [folder].
  ///
  /// The unquantised model on purpose: `model.int8.onnx` is a third of the
  /// size and sounds metallic, which is the whole reason this pack is 350 MB.
  static const model = 'model.onnx';
  static const voices = 'voices.bin';
  static const tokens = 'tokens.txt';
  static const lexicon = 'lexicon-zh.txt';
  static const dataDir = 'espeak-ng-data';

  /// The voices this pack ships; sid is the index into `voices.bin`.
  ///
  /// 53 speakers: 0–27 English, 45 zf_xiaobei, 46 zf_xiaoni, 47 zf_xiaoxiao,
  /// 48 zf_xiaoyi, 49–52 the Mandarin male ones. 3 and 6 are af_heart and
  /// af_nicole, which is why an English voice was reading Chinese.
  static const voiceCount = 53;

  /// zf_xiaoyi.
  static const chineseFemale = 48;
}

/// Where the pack lives: `<app support>/tts/`.
Future<Directory> localTtsRoot() async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}/tts');
}

/// The unpacked folder, or null while the pack is not installed.
Future<Directory?> localTtsInstalled() async {
  final root = await localTtsRoot();
  final dir = Directory('${root.path}/${LocalTtsPack.folder}');
  for (final name in [LocalTtsPack.model, LocalTtsPack.voices, LocalTtsPack.tokens]) {
    if (!await File('${dir.path}/$name').exists()) return null;
  }
  if (!await Directory('${dir.path}/${LocalTtsPack.dataDir}').exists()) return null;
  return dir;
}

/// Bytes already on disk for an install under way (a resumable download).
Future<int> localTtsPartialBytes() async {
  final root = await localTtsRoot();
  final part = File('${root.path}/kokoro.tar.bz2.part');
  return await part.exists() ? await part.length() : 0;
}

/// Downloads and unpacks the pack. Throws [LocalTtsError] when it cannot.
///
/// [onProgress] gets (received, total) for the download only; unpacking has no
/// progress to report.
Future<Directory> installLocalTts({void Function(int received, int total)? onProgress}) async {
  final root = await localTtsRoot();
  await root.create(recursive: true);
  // A pack installed under another name (the quantised one) is of no use now
  // and holds a few hundred megabytes.
  for (final entry in await root.list().toList()) {
    if (entry is Directory &&
        entry.path != '${root.path}/${LocalTtsPack.folder}' &&
        entry.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('kokoro')) {
      await entry.delete(recursive: true);
    }
  }
  final part = File('${root.path}/kokoro.tar.bz2.part');
  var have = await part.exists() ? await part.length() : 0;
  if (have > LocalTtsPack.bytes) {
    // Longer than the pack: not ours to resume.
    if (await part.exists()) await part.delete();
    have = 0;
  }

  if (have < LocalTtsPack.bytes) {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(LocalTtsPack.url));
      if (have > 0) request.headers['range'] = 'bytes=$have-';
      final response = await client.send(request);
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw LocalTtsError('HTTP ${response.statusCode}');
      }
      final sink = part.openWrite(mode: have > 0 && response.statusCode == 206 ? FileMode.append : FileMode.write);
      if (response.statusCode == 200) have = 0;
      var received = have;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, LocalTtsPack.bytes);
        }
      } finally {
        await sink.close();
      }
    } on LocalTtsError {
      rethrow;
    } on Object catch (error) {
      throw LocalTtsError('$error');
    } finally {
      client.close();
    }
  }

  final got = await part.length();
  if (got != LocalTtsPack.bytes) throw LocalTtsError('size $got');
  final digest = await _sha256OfFile(part);
  if (digest != LocalTtsPack.sha256) {
    if (await part.exists()) await part.delete();
    throw const LocalTtsError('checksum');
  }

  // Unpacking 383 MB of files: off the UI isolate.
  final target = root.path;
  await Isolate.run(() => _unpack(part.path, target));
  if (await part.exists()) await part.delete();
  final installed = await localTtsInstalled();
  if (installed == null) throw const LocalTtsError('unpack');
  return installed;
}

Future<String> _sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// bz2 → tar → files, keeping the archive's own folder names.
void _unpack(String archivePath, String into) {
  final raw = File(archivePath).readAsBytesSync();
  final tar = BZip2Decoder().decodeBytes(raw);
  final archive = TarDecoder().decodeBytes(tar);
  for (final entry in archive.files) {
    final name = entry.name.replaceAll('\\', '/');
    if (name.contains('..')) continue;
    final out = File('$into/$name');
    if (entry.isFile) {
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(entry.content as List<int>, flush: true);
    } else {
      Directory('$into/$name').createSync(recursive: true);
    }
  }
}

/// Removes the installed pack (and any download under way).
Future<void> removeLocalTts() async {
  final root = await localTtsRoot();
  if (await root.exists()) await root.delete(recursive: true);
}

class LocalTtsError implements Exception {
  const LocalTtsError(this.reason);
  final String reason;

  @override
  String toString() => 'LocalTtsError($reason)';
}

/// One loaded OfflineTts, living in its own isolate.
///
/// The UI isolate only talks to it: a request is (text, sid, speed), the answer
/// is the WAV bytes. Loading happens in the worker's first message, so the
/// caller waits for it once and never again.
class LocalTts {
  LocalTts._(this._requests, this._replies, this._isolate);

  final SendPort _requests;
  final ReceivePort _replies;
  final Isolate _isolate;
  final _pending = <int, Completer<Uint8List>>{};
  var _next = 0;
  bool _closed = false;

  /// Starts the worker and loads the pack at [pack] in it.
  static Future<LocalTts> open(Directory pack) async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    final errors = Completer<String>();

    final isolate = await Isolate.spawn(
      _ttsMain,
      [replies.sendPort, pack.path],
      onError: replies.sendPort,
      onExit: replies.sendPort,
      debugName: 'dsh-tts',
    );

    late final LocalTts tts;
    replies.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is List && message.length == 2 && message[0] is int) {
        final id = message[0] as int;
        final payload = message[1];
        final waiter = tts._pending.remove(id);
        if (payload is Uint8List) {
          waiter?.complete(payload);
        } else {
          waiter?.completeError(LocalTtsError('$payload'));
        }
        return;
      }
      if (message is String && !errors.isCompleted) {
        errors.complete(message);
        return;
      }
      // An isolate error arrives as [description, stack]; a load failure as
      // ['error', description].
      if (message is List && message.isNotEmpty && !errors.isCompleted) {
        errors.complete('${message.first}');
      }
    });

    final result = await Future.any<Object>([
      ready.future,
      errors.future,
      Future<Object>.delayed(const Duration(seconds: 90), () => 'timeout loading the pack'),
    ]);
    if (result is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      throw LocalTtsError('$result');
    }
    tts = LocalTts._(result, replies, isolate);
    return tts;
  }

  /// One sentence as a 16-bit mono WAV. [sid] 48 is zf_xiaoyi; the default
  /// tempo is a little above the model's own.
  Future<Uint8List> speak(String text, {int sid = LocalTtsPack.chineseFemale, double speed = 1.1}) async {
    if (_closed) throw const LocalTtsError('closed');
    final id = _next++;
    final done = Completer<Uint8List>();
    _pending[id] = done;
    _requests.send([id, text, sid, speed]);
    try {
      return await done.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      _pending.remove(id);
      throw const LocalTtsError('timeout speaking');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _requests.send(const ['close']);
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _replies.close();
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.completeError(const LocalTtsError('closed'));
    }
    _pending.clear();
  }
}

/// The worker: load once, then answer (id, text, sid, speed) with (id, WAV).
@pragma('vm:entry-point')
void _ttsMain(List args) {
  final replies = args[0] as SendPort;
  final path = args[1] as String;
  final inbox = ReceivePort();
  replies.send(inbox.sendPort);
  sherpa.OfflineTts? tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: '$path/${LocalTtsPack.model}',
            voices: '$path/${LocalTtsPack.voices}',
            tokens: '$path/${LocalTtsPack.tokens}',
            dataDir: '$path/${LocalTtsPack.dataDir}',
            lexicon: '$path/lexicon-us-en.txt,$path/${LocalTtsPack.lexicon}',
            lang: 'zh',
            lengthScale: 1.0,
          ),
          numThreads: 4,
          debug: false,
          provider: 'cpu',
        ),
      ),
    );
  } on Object catch (error) {
    replies.send('load $error');
    inbox.close();
    return;
  }

  inbox.listen((message) {
    if (message is List && message.isNotEmpty && message[0] == 'close') {
      try {
        tts?.free();
      } on Object {
        // Already gone.
      }
      inbox.close();
      return;
    }
    if (message is! List || message.length != 4) return;
    final id = message[0] as int;
    final text = message[1] as String;
    final sid = message[2] as int;
    final speed = message[3] as double;
    try {
      final audio = tts!.generate(text: text, sid: sid, speed: speed);
      if (audio.samples.isEmpty) {
        replies.send([id, 'empty']);
        return;
      }
      replies.send([id, wavOf(audio.samples, audio.sampleRate)]);
    } on Object catch (error) {
      replies.send([id, 'speak $error']);
    }
  });
}

/// Float samples (-1..1) as a 16-bit PCM WAV.
Uint8List wavOf(Float32List samples, int sampleRate) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(i * 2, v, Endian.little);
  }
  final header = ByteData(44);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      header.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  final size = data.lengthInBytes;
  ascii(0, 'RIFF');
  header.setUint32(4, 36 + size, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, size, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...data.buffer.asUint8List()]);
}
