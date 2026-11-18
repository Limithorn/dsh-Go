import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../diagnostics/diagnostics_channel.dart';
import '../nativemedia/speaker_gate_bridge.dart';
import '../speech/wake_word.dart';
import '../speech/speech_settings.dart';
import '../speech/voiceprint_store.dart';
import '../speech/wake_words.dart';
import '../ui/speech/voice_call_page.dart';
import 'app_navigation.dart';
import 'sessions_state.dart';
import 'wake_binding.dart';
import 'wake_sensitivity.dart';

/// 唤醒词的状态：开着没有、模型好没好、刚才被叫了几次。
class WakeState {
  const WakeState({
    this.enabled = false,
    this.loading = false,
    this.listening = false,
    this.hits = 0,
    this.problem,
  });

  /// 人把这个开关打开了吗（会持久化，见 [WakeController]）。
  final bool enabled;

  /// 模型正在载入。
  final bool loading;

  /// 麦克风真的在采集。
  final bool listening;

  /// 醒来过几次；界面用它来显示"刚刚被叫醒"。
  final int hits;

  /// 没起来的原因：mic_busy / mic_unavailable / model_unavailable / service_refused。
  final String? problem;

  WakeState copyWith({
    bool? enabled,
    bool? loading,
    bool? listening,
    int? hits,
    String? problem,
    bool clearProblem = false,
  }) {
    return WakeState(
      enabled: enabled ?? this.enabled,
      loading: loading ?? this.loading,
      listening: listening ?? this.listening,
      hits: hits ?? this.hits,
      problem: clearProblem ? null : (problem ?? this.problem),
    );
  }
}

/// 唤醒词的服务端：模型、麦克风、以及被叫醒之后把通话推上来。
///
/// 采集在 Kotlin（wake/WakeCapture.kt），因为后台要用麦克风就得挂一条
/// microphone 类型的前台服务；这里拿到 PCM 之后喂给 sherpa 的关键词检测，
/// 命中了就停一下、把 App 拉回前台、推开通话页，再继续听。
class WakeController extends Notifier<WakeState> {
  static const _channel = MethodChannel('dsh/wake');

  final _engine = WakeWordEngine();
  var _subscribed = false;

  @override
  WakeState build() {
    ref.onDispose(() {
      _channel.setMethodCallHandler(null);
      _engine.dispose();
    });
    return const WakeState();
  }

  /// 打开或关掉。打开时会载入模型（约 5 MB，第一次要从 assets 落到磁盘）。
  Future<bool> setEnabled(bool on) async {
    if (!on) {
      await stop();
      state = state.copyWith(enabled: false, clearProblem: true);
      return true;
    }
    state = state.copyWith(enabled: true, loading: true, clearProblem: true);
    final ok = await start();
    state = state.copyWith(loading: false);
    if (!ok) state = state.copyWith(enabled: false);
    return ok;
  }

  Future<bool> start() async {
    if (_subscribed == false) {
      _channel.setMethodCallHandler(_onCall);
      _subscribed = true;
    }
    final dir = await prepareWakeModel(await _modelDir());
    // 先把人写的那个词写成模型能读的词表（设置里改过就是新的）。
    await WakeWords.syncTo(dir);
    final level = await WakeSensitivityStore.read();
    final loaded = await _engine.load(dir, threshold: level.threshold);
    if (!loaded) {
      state = state.copyWith(problem: 'model_unavailable');
      return false;
    }
    final bool started;
    try {
      started = await _channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException {
      state = state.copyWith(problem: 'service_refused');
      return false;
    } on MissingPluginException {
      state = state.copyWith(problem: 'service_refused');
      return false;
    }
    state = state.copyWith(listening: started, problem: started ? null : 'mic_busy', clearProblem: started);
    return started;
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object {
      // 已经停了，或者宿主不在（桌面端）。
    }
    state = state.copyWith(listening: false);
  }

  Future<String> _modelDir() async {
    final base = await getApplicationSupportDirectory();
    return '${base.path}/wake';
  }

  /// 最近这段音频，唤醒命中时拿它验"是谁叫的"。
  ///
  /// 唤醒词本身已经把范围缩到"刚叫了名字的人"，这段缓冲正好是那个人的声音，
  /// 不必再等他开口。留 1.5 秒：够 CAM++ 算，也够覆盖一个词的时长。
  final _recent = <int>[];

  static const _recentLimit = 24000; // 1.5s @ 16k

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'chunk':
        final bytes = call.arguments;
        if (bytes is! Uint8List) return;
        final data = ByteData.sublistView(bytes);
        final samples = Int16List(bytes.length ~/ 2);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = data.getInt16(i * 2, Endian.little);
        }
        // 维护"最近 1.5 秒"，唤醒命中时用它判是谁。
        _recent.addAll(samples);
        if (_recent.length > _recentLimit) {
          _recent.removeRange(0, _recent.length - _recentLimit);
        }
        final hit = _engine.accept(samples);
        if (hit != null && hit.isNotEmpty) {
          // 先把这段抄下来：_wake 会把引擎重开，缓冲随即被清。
          final heard = Float32List.fromList([
            for (final v in _recent) v / 32768.0,
          ]);
          unawaited(_wake(hit, heard));
        }
      case 'error':
        state = state.copyWith(listening: false, problem: call.arguments as String?);
    }
  }

  /// 叫名字的这个人，是录过的其中之一吗。
  ///
  /// 三种情况都算"可以答应"，因为这时不该多管闲事：
  ///  - 唤醒声纹开关关着（默认）；
  ///  - 一条声纹都没录（没人可认）；
  ///  - 算出不出来（太短、算失败）——宁可答应，也不要让开关变成"叫不应"。
  ///
  /// 只有"明确判成旁人"才拦下。
  Future<bool> _isKnownVoice(Float32List heard) async {
    final settings = ref.read(callSettingsProvider);
    if (!settings.voiceprint || !settings.voiceprintWake) return true;
    final profiles = ref.read(voiceprintProfilesProvider).value ?? const <VoiceProfile>[];
    if (profiles.isEmpty) return true;
    if (heard.length < 8000) return true;
    // 判定交给原生：模型和模板都在那边，阈值也按唤醒那道闸算。
    // 这里自己再算一遍只会多一套可能不一致的逻辑。
    final ok = await VoiceprintChannel().isKnownVoice(Float32List.fromList(heard));
    unawaited(const DiagnosticsChannel().recordVoiceStage(ok ? 'wake_voice_ok' : 'wake_voice_other'));
    return ok;
  }

  /// 被叫醒了：停一下麦克风（别把通话自己的声音再喂回来），把 App 请到前面，
  /// 推开通话页，然后接着听。
  Future<void> _wake(String word, Float32List heard) async {
    // 认声音：只有录过的人叫名字才答应。开关关着时这一步整个跳过。
    if (!await _isKnownVoice(heard)) {
      // 词对了但人不对：当作没听见，麦克风不动，什么也不弹。
      return;
    }
    state = state.copyWith(hits: state.hits + 1);
    await _channel.invokeMethod<void>('stop');
    state = state.copyWith(listening: false);
    _engine.resetStream();
    try {
      await const MethodChannel('dsh/app').invokeMethod<void>('bringToFront');
    } on Object {
      // 没有宿主通道（桌面端）就只推页面。
    }
    final context = rootNavigatorKey.currentContext;
    if (context != null && context.mounted) {
      await openChatCall(
        context,
        title: word.replaceFirst('@', ''),
        // 被叫醒的通话必须有一个真的会话，不然话没地方去：设置里指定了就用那一个，
        // 没指定就现开一间。之前这里返回 null，结果就是叫醒之后说的话发不出去。
        session: () async {
          final bound = await WakeBinding.read();
          if (bound != null) return bound;
          return ref.read(sessionsProvider.notifier).create();
        },
      );
    }
    if (state.enabled) {
      await start();
    }
  }
}

final wakeProvider = NotifierProvider<WakeController, WakeState>(WakeController.new);

/// 设置页读它显示当前那个词；改完 [WakeWords.write] 之后 invalidate。
final wakeWordProvider = FutureProvider<String>((ref) => WakeWords.read());
