import 'dart:async';

import 'voice_call.dart';

/// 通话页的「不接大模型」测试会话。
///
/// 用来把通话页本身当测试台：采集、AEC、声纹判定、打断、TTS 播放全走
/// 真实链路，只有「回复从哪来」这一环换成固定台词。这样测出来的分数
/// 和实际通话一致，又不花 token、不受网络影响、结果可复现。
///
/// 为什么不复用设置页那个「实景测试」按钮：那个是自己开一路采集，
/// 和通话页是两个入口。用户要验的是**通话页面这条链路**——包括它怎么
/// 开采集、怎么管 AEC、怎么判定插话，这些只有真进通话页才走得到。
class ScriptedCallConversation implements CallConversation {
  ScriptedCallConversation({
    required this.lines,
    this.thinking = const Duration(milliseconds: 400),
    this.revealStep = const Duration(milliseconds: 40),
  });

  /// 按顺序念的台词，念完回到开头。
  final List<String> lines;

  /// 「思考」多久再出第一个字——留出这段，插话才测得到「还没开口就打断」。
  final Duration thinking;

  /// 每个字之间隔多久吐出来。逐字吐是为了让回复有「正在说」的过程，
  /// 打断能发生在半句中间，这和真实模型流式返回的形态一致。
  final Duration revealStep;

  final _replies = StreamController<CallReply>.broadcast();
  int _at = 0;
  Timer? _timer;
  bool _waiting = false;

  @override
  Stream<CallReply> get replies => _replies.stream;

  @override
  bool get waiting => _waiting;

  @override
  Future<bool> send(String text) async {
    _timer?.cancel();
    final line = lines[_at % lines.length];
    _at++;
    // 先发一个空回复：通话页据此进入「她在说」的状态，但还没出声。
    // 这段空窗期正好用来测「一个字都还没说就被打断」。
    _replies.add(CallReply('', done: false));
    var shown = '';
    var i = 0;
    _timer = Timer.periodic(thinking + revealStep * (i + 1), (t) {
      if (i >= line.length) {
        t.cancel();
        _replies.add(CallReply(line, done: true));
        return;
      }
      i++;
      shown = line.substring(0, i);
      _replies.add(CallReply(shown, done: i >= line.length));
      if (i >= line.length) t.cancel();
    });
    return true;
  }

  @override
  Future<void> interrupt() async {
    _timer?.cancel();
    _timer = null;
    _waiting = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _replies.close();
  }
}
