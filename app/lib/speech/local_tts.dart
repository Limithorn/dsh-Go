// Speaking on the phone itself: sherpa-onnx's Kokoro multi-language voice
// (int8, Apache-2.0), everything offline. The pack is one tar.bz2 from the
// sherpa-onnx releases; it is fetched once, checked against its SHA-256,
// unpacked into the app's own folder and handed to OfflineTts.
//
// This is the only voice source that asks nothing of a network or an account
// once it is installed. What it costs is disk (about 182 MB unpacked) and the
// first synthesis, which loads the 109 MB model.

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
  return await part.exists() ? part.length() : 0;
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

  // Unpacking 182 MB of files: off the UI isolate.
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

/// One loaded OfflineTts, kept until [close]: loading the model takes seconds
/// and the voice is asked per sentence.
class LocalTts {
  LocalTts._(this._tts);

  final sherpa.OfflineTts _tts;

  /// Loads the pack at [pack]; throws when it cannot be loaded.
  static Future<LocalTts> open(Directory pack) async {
    sherpa.initBindings();
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: '${pack.path}/${LocalTtsPack.model}',
          voices: '${pack.path}/${LocalTtsPack.voices}',
          tokens: '${pack.path}/${LocalTtsPack.tokens}',
          dataDir: '${pack.path}/${LocalTtsPack.dataDir}',
          // Both lexicons, comma-separated: the pack reads English words in a
          // Chinese sentence through the first one and the Chinese through the
          // second (the upstream examples pass both).
          lexicon: '${pack.path}/lexicon-us-en.txt,${pack.path}/lexicon-zh.txt',
          // Without this the pack reads Chinese as English: espeak-ng picks the
          // phoneme set from the language.
          lang: 'zh',
          lengthScale: 1.0,
        ),
        numThreads: 4,
        debug: false,
        provider: 'cpu',
      ),
    );
    try {
      return LocalTts._(sherpa.OfflineTts(config));
    } on Object catch (error) {
      throw LocalTtsError('$error');
    }
  }

  /// One sentence as a 16-bit mono WAV, which is what the mouth and the queue
  /// already read. [sid] 48 is zf_xiaoyi; the default tempo is a little above
  /// the model's own, which reads slower than the person speaks.
  Uint8List speak(String text, {int sid = LocalTtsPack.chineseFemale, double speed = 1.1}) {
    final audio = _tts.generate(text: text, sid: sid, speed: speed);
    if (audio.samples.isEmpty) throw const LocalTtsError('empty');
    return wavOf(audio.samples, audio.sampleRate);
  }

  void close() {
    try {
      _tts.free();
    } on Object {
      // Already gone.
    }
  }
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
