import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 唤醒词：一段 16 kHz 的流式关键词检测。
///
/// 走 sherpa-onnx 的 KeywordSpotter，模型是 zipformer 中文 KWS（3.3M，
/// int8 量化后约 4.7 MB）。它每吃进一小段音频就推进一次前向，
/// 命中我们自定的词就回一句话给上层。
///
/// 采集不在 Dart 这边：后台要麦克风，Android 必须挂一个 microphone 类型的
/// 前台服务，所以 AudioRecord 在 Kotlin（WakeCapture.kt），PCM 分批推过来。
class WakeWordEngine {
  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  bool _loading = false;

  bool get ready => _spotter != null;

  /// 载入模型。模型文件由 [prepareWakeModel] 放到本地后传进来。
  Future<bool> load(String dir) async {
    if (_spotter != null || _loading) return _spotter != null;
    _loading = true;
    try {
      sherpa.initBindings();
      _spotter = sherpa.KeywordSpotter(
        sherpa.KeywordSpotterConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: '$dir/encoder.int8.onnx',
              decoder: '$dir/decoder.int8.onnx',
              joiner: '$dir/joiner.int8.onnx',
            ),
            tokens: '$dir/tokens.txt',
            numThreads: 2,
            provider: 'cpu',
            debug: false,
          ),
          keywordsFile: '$dir/keywords.txt',
          // 0.25 是官方示例的默认值：低一点更灵，但也更容易被相似音叫醒。
          keywordsThreshold: 0.25,
          keywordsScore: 1.0,
        ),
      );
      _stream = _spotter!.createStream();
      return true;
    } on Object {
      _spotter?.free();
      _spotter = null;
      return false;
    } finally {
      _loading = false;
    }
  }

  /// 吃一段 PCM16（16 kHz 单声道），命中返回关键词，否则 null。
  String? accept(Int16List pcm) {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null || pcm.isEmpty) return null;
    final samples = Float32List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      samples[i] = pcm[i] / 32768.0;
    }
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
      final result = spotter.getResult(stream);
      if (result.keyword.isNotEmpty) return result.keyword;
    }
    return null;
  }

  /// 一段说完之后把流清干净，免得上一句的尾巴影响下一次判定。
  void resetStream() {
    _stream?.free();
    _stream = _spotter?.createStream();
  }

  void dispose() {
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
  }
}

/// 把打包进 assets 的唤醒模型复制到应用目录，返回目录路径。
///
/// sherpa 要的是文件路径而不是 asset 句柄，所以第一次用要落盘；之后直接复用。
Future<String> prepareWakeModel(String targetDir) async {
  final dir = Directory(targetDir);
  final tokens = File('${dir.path}/tokens.txt');
  if (await tokens.exists()) return dir.path;
  await dir.create(recursive: true);
  const files = [
    'encoder.int8.onnx',
    'decoder.int8.onnx',
    'joiner.int8.onnx',
    'tokens.txt',
    'keywords.txt',
  ];
  for (final name in files) {
    final data = await rootBundle.load('assets/wake/$name');
    await File('${dir.path}/$name').writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }
  return dir.path;
}
