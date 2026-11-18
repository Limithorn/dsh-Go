import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 用 sherpa-onnx 的 `SpeakerEmbeddingExtractor` 算声纹向量。
///
/// **为什么不用自己写的 fbank**：上游的 [SpeakerEmbeddingExtractor] 内部调
/// kaldi-native-fbank，fbank 参数（窗、mel 滤波器、去 DC、log 底数）和模型训练
/// 时完全一致。手写一份只要有一处偏差（比如去 DC 的顺序、mel 归一化方式），
/// 模型拿到的就不是它认识的输入分布——输出会退化成噪声：**谁都比得上、谁都
/// 分不开**。真机上就是这样：两个人得到几乎一样的分数。
///
/// 所以这里不再自己算特征，音频整段交给 sherpa。
class SherpaSpeakerEmbedder {
  SherpaSpeakerEmbedder._(this._extractor, this._dim);

  final sherpa.SpeakerEmbeddingExtractor _extractor;

  /// 向量维度（CAM++ 是 192）。
  int get dim => _dim;
  final int _dim;

  static const _asset = 'assets/speech/3dspeaker_campplus_sv_zh-cn_16k-common.onnx';

  /// 把模型从 asset 复制到应用目录，然后建提取器。
  ///
  /// sherpa 要的是文件路径而不是 asset 句柄，所以第一次用要落盘；之后复用。
  static Future<SherpaSpeakerEmbedder?> load(String dir) async {
    try {
      final target = File('$dir/speaker-provider.onnx');
      if (!await target.exists()) {
        await Directory(dir).create(recursive: true);
        final data = await rootBundle.load(_asset);
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      sherpa.initBindings();
      final extractor = sherpa.SpeakerEmbeddingExtractor(
        config: sherpa.SpeakerEmbeddingExtractorConfig(
          model: target.path,
          numThreads: 2,
          debug: false,
        ),
      );
      return SherpaSpeakerEmbedder._(extractor, extractor.dim);
    } on Object {
      return null;
    }
  }

  /// 一段 16k 单声道、-1..1 的音频 → 单位向量；算不出来返回 null。
  Float32List? embed(Float32List samples) {
    if (samples.length < 4000) return null; // 少于 0.25 秒没意义
    try {
      final stream = _createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      while (!_extractor.isReady(stream)) {
        // 音频已经全部喂进去了，isReady 还不成立说明太短。
        break;
      }
      if (!_extractor.isReady(stream)) {
        stream.free();
        return null;
      }
      final v = _extractor.compute(stream);
      stream.free();
      if (v.isEmpty) return null;
      return _l2(v);
    } on Object {
      return null;
    }
  }

  sherpa.OnlineStream _createStream() => _extractor.createStream();

  void free() => _extractor.free();

  static Float32List? _l2(Float32List v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final n = sum <= 0 ? 0.0 : _sqrt(sum);
    if (n <= 1e-8) return null;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / n;
    }
    return out;
  }

  static double _sqrt(double v) {
    var x = v;
    for (var i = 0; i < 30; i++) {
      x = 0.5 * (x + v / x);
    }
    return x;
  }
}
