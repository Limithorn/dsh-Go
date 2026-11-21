import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice.dart';
import '../../speech/speech_audio.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voiceprint_store.dart';
import '../../state/app_info.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// 实景测试：TTS 正在说话的时候，看人说话能不能打断。
///
/// 和另外两页的分工：
/// - 「语音链路诊断」看每一道闸的线画在哪
/// - 「语音自测」离线量采集、模型、分数
/// - **这一页**是唯一在"扬声器真的在响"的条件下测的
///
/// 为什么必须有这一页：自打断（AI 自己的声音漏回麦克风被认成自己）和
/// 插话困难（真说话时分数不够）都只在真的放声音时出现。离线跑 embed 时
/// 麦克风是安静的，这两件事一件都复现不了。
///
/// **收音不再由这一页自己定**：原来这里有独立的 comm/recog/mic 三档，通话走
/// 设置里的「通话收音」，两条路径可能收的不是同一路声音，分数没法互相印证。
/// 现在音源只认一个设置，auto 的判断也由原生统一做（Kotlin 侧的 MicSource），
/// 本页只把"这次实际用的哪一路、量到了什么"显示出来。
class ScreenTestPage extends ConsumerStatefulWidget {
  const ScreenTestPage({super.key});

  @override
  ConsumerState<ScreenTestPage> createState() => _ScreenTestPageState();
}

/// 一次窗口的结果，对应原生每 1.5 秒发上来的那条。
class _Window {
  _Window({required this.score, required this.kind, required this.rms, required this.barged});

  final double score;
  final String kind;
  final double rms;
  final bool barged;
}

/// 原生这次为实景测试选音源的依据，对应 `micSourceReport` 里的 `screen`。
class _Pick {
  _Pick({required this.chosen, required this.requested, this.vc, this.vr, this.delta, this.reason});

  final String chosen;
  final String requested;

  /// 自动判断时量到的峰值（dBFS）；手动指定档位时不量，是 null。
  final double? vc;
  final double? vr;

  /// 识别减通话，dB。
  final double? delta;
  final String? reason;
}

class _ScreenTestPageState extends ConsumerState<ScreenTestPage> {
  static const _channel = MethodChannel('dsh/speech');
  final _voice = CompanionVoice();

  bool _running = false;
  bool _aec = false;
  String? _note;

  /// 本轮所有窗口，按时间顺序。
  final _windows = <_Window>[];

  /// 结束时原生报回来的录音文件路径。
  List<String> _clips = const [];

  /// 正在放第几段；-1 表示没在放。
  int _playing = -1;

  /// 本轮实际用的音源，和原生给的选择依据。
  ///
  /// 音源不再由这一页的开关决定（那个开关已经删掉，改成跟随通话设置）：所以
  /// 页面至少要说清楚"这次到底收的哪一路"，否则分数和通话一对比就没法解释。
  _Pick? _pick;

  /// 让 TTS 一直说下去：说完一句接下一句，直到停。
  ///
  /// 用长句拼出来的，所以不会在等下一句的间隙把扬声器"停下"——那个间隙里
  /// 麦克风是安静的，量出来的分数不代表"正在被自己的声音盖住"的情况。
  static const _script = [
    '我现在正在和你说话，这是一段用来测试的语音，会一直说下去，'
        '你可以随时打断我，说你想说的话。',
    '如果我能听见你并认得出是你，那么这次打断就应该成功，'
        '界面上会显示打断成功和当时的分数。',
    '如果我认不出你，或者把你的声音当成了别人，这次打断就不会成功，'
        '那我们就知道问题出在声纹这一环。',
    '这段语音会重复几遍，你可以多试几次，'
        '在免提和听筒两种模式下各试一遍，比较一下差别。',
  ];

  StreamSubscription<CompanionVoiceEvent>? _sub;
  Timer? _speakTimer;
  int _turn = 0;

  @override
  void initState() {
    super.initState();
    _sub = _voice.events.listen((e) {
      // TTS 说完一句就接下一句，让扬声器一直有声音。
      if (_running && e.type == CompanionVoiceEventType.done) _nextSentence();
    });
  }

  @override
  void dispose() {
    _speakTimer?.cancel();
    unawaited(_sub?.cancel());
    if (_running) unawaited(_stop());
    super.dispose();
  }

  Future<void> _start() async {
    final profiles = ref.read(voiceprintProfilesProvider).value ?? const <VoiceProfile>[];
    if (profiles.isEmpty) {
      setState(() => _note = '还没有录入声音，先录一份再来测');
      return;
    }
    // 存着的设置读完了再取音源，否则可能在默认值上跑一遍。
    final source = (await ref.read(callSettingsProvider.notifier).ready()).callMicSource;
    if (!mounted) return;
    setState(() {
      _windows.clear();
      _clips = const [];
      _note = null;
      _running = true;
      _turn = 0;
      _pick = null;
    });

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'screenTestWindow') return;
      final m = call.arguments as Map;
      final w = _Window(
        score: (m['score'] as num?)?.toDouble() ?? -1,
        kind: '${m['kind']}',
        rms: (m['rms'] as num?)?.toDouble() ?? -120,
        barged: m['barged'] == true,
      );
      if (!mounted) return;
      setState(() {
        _aec = m['aec'] == true;
        _windows.add(w);
      });
    });

    final ok = await _channel.invokeMethod<bool>(
          'screenTestStart',
          {'source': source.wire},
        ) ??
        false;
    if (!ok) {
      if (mounted) setState(() => _running = false);
      if (mounted) setState(() => _note = '开不了采集（权限或被占用）');
      return;
    }
    // 音源在起采集之前就已经定好了，这里只是把它和依据取回来显示。
    await _loadPick();
    await _voice.ready();
    _nextSentence();
  }

  /// 取原生这次选音源的结果（`micSourceReport` 的 `screen` 那份）。
  ///
  /// 新增的方法：旧版原生没有它，取不到就当没有——不影响采集和判定。
  Future<void> _loadPick() async {
    try {
      final r = await _channel.invokeMapMethod<Object?, Object?>('micSourceReport');
      final p = r?['screen'];
      if (!mounted || p is! Map) return;
      final pick = _Pick(
        chosen: '${p['chosen'] ?? '—'}',
        requested: '${p['requested'] ?? '—'}',
        vc: (p['vc'] as num?)?.toDouble(),
        vr: (p['vr'] as num?)?.toDouble(),
        delta: (p['delta'] as num?)?.toDouble(),
        reason: p['reason'] as String?,
      );
      setState(() => _pick = pick);
    } on PlatformException {
      // 旧原生：没有这个方法，页面照旧只显示分数。
    }
  }

  /// 说下一句。用定时兜底：某些 TTS 引擎不发 end 事件（尤其是不支持
  /// utterance 进度回调的），只靠事件会说到第二句就断。
  Future<void> _nextSentence() async {
    if (!_running) return;
    final text = _script[_turn % _script.length];
    _turn++;
    await _voice.speak('screentest-$_turn', text, flush: true);
    _speakTimer?.cancel();
    // 一句大约 25 字、语速 1.0 秒 4 字左右：给足时间，真正的下一句由
    // end 事件触发，这里只是兜底。
    _speakTimer = Timer(const Duration(seconds: 9), () {
      if (_running) unawaited(_nextSentence());
    });
  }

  Future<void> _playClip(int i) async {
    if (_playing == i) {
      await _voice.stop();
      if (mounted) setState(() => _playing = -1);
      return;
    }
    setState(() => _playing = i);
    await _voice.play('screen-clip-$i', _clips[i]);
  }

  Future<void> _stop() async {
    _speakTimer?.cancel();
    setState(() => _running = false);
    await _voice.stop();
    final clips = await _channel.invokeMethod<List<Object?>>('screenTestStop');
    if (!mounted) return;
    setState(() => _clips = [for (final c in clips ?? const []) '$c']);
    _channel.setMethodCallHandler(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final call = ref.watch(callSettingsProvider);

    final you = _windows.where((w) => w.kind == 'YOU').length;
    final other = _windows.where((w) => w.kind == 'OTHER').length;
    final none = _windows.where((w) => w.kind == 'NONE').length;
    final barged = _windows.where((w) => w.barged).length;
    final scored = _windows.where((w) => w.score >= 0).toList();
    final avg = scored.isEmpty ? null : scored.map((w) => w.score).reduce((a, b) => a + b) / scored.length;

    return AppPage.list(
      title: '实景测试',
      subtitle: const Text('让我一直说话，你插话，看能不能打断'),
      children: [
        SettingsSection(
          title: '这一版',
          children: [
            SettingsTile(
              title: AppInfo.buildLabel,
              subtitle: '识别灵敏度 ${call.voiceprintLevel.wire} · '
                  '收音 ${call.voiceprintMic.wire} · '
                  '外人插话${call.voiceprintOthers ? '开' : '关'}',
            ),
            SettingsSegmentTile<CallMicSource>(
              key: const ValueKey('screen-source'),
              title: '收音（和通话同一个设置）',
              subtitle: switch (call.callMicSource) {
                CallMicSource.auto =>
                  '自动：启动时量两路电平，通话那一路低 20dB 以上就换识别——和通话用的是同一次判断',
                CallMicSource.communication =>
                  '通话那一路：带 AEC，自己播的声音不会漏回来；但有的机器会把人声也压掉',
                CallMicSource.recognition =>
                  '识别那一路：不降噪、电平高，但自己播的声音会漏回来',
              },
              segments: const [
                PillSegment(CallMicSource.auto, '自动'),
                PillSegment(CallMicSource.communication, '通话'),
                PillSegment(CallMicSource.recognition, '识别'),
              ],
              selected: call.callMicSource,
              onChanged: _running
                  ? null
                  : (v) => unawaited(
                        ref.read(callSettingsProvider.notifier).edit((saved) => saved.copyWith(callMicSource: v)),
                      ),
            ),
            if (_pick case final p?)
              SettingsTile(
                key: const ValueKey('screen-chosen-source'),
                title: '这一轮收的是 ${p.chosen}',
                subtitle: [
                  p.requested == 'auto' ? (p.reason ?? '自动判断') : '设置里直接指定的档位',
                  if (p.vc != null && p.vr != null)
                    '实测峰值：通话 ${_db(p.vc!)} / 识别 ${_db(p.vr!)} dBFS'
                        '${p.delta == null ? '' : '，差 ${p.delta!.toStringAsFixed(1)} dB'}',
                ].join('\n'),
              ),
          ],
        ),
        SettingsSection(
          children: [
            SettingsTile(
              key: const ValueKey('screen-start'),
              title: _running ? '停止' : '开始',
              subtitle: _running
                  ? '我正在说话——现在插话试试'
                  : '会播放我的声音，你随时插话；同时录下麦克风听到的东西',
              onTap: _running ? _stop : _start,
            ),
            if (_note case final n?) SettingsTile(title: n, danger: true),
            if (_running)
              SettingsTile(
                title: 'AEC ${_aec ? '已生效' : '没生效'}',
                subtitle: _aec
                    ? null
                    : '回声没被消除：我自己的声音会被算进判定，分数偏高',
                danger: !_aec,
              ),
          ],
        ),
        if (_windows.isNotEmpty)
          SettingsSection(
            title: '本轮结果',
            children: [
              SettingsTile(
                title: '${_windows.length} 个窗口 · 打断 $barged 次',
                subtitle: '认成你 $you · 认成旁人 $other · 算不出 $none'
                    '${avg == null ? '' : '　平均分 ${avg.toStringAsFixed(3)}'}',
              ),
            ],
          ),
        if (_windows.isNotEmpty)
          SettingsSection(
            title: '逐条',
            children: [
              for (var i = _windows.length - 1; i >= 0 && i >= _windows.length - 12; i--)
                SettingsTile(
                  title: '${_windows[i].score < 0 ? '—' : _windows[i].score.toStringAsFixed(3)}'
                      '　${_label(_windows[i].kind)}',
                  subtitle: '响度 ${_windows[i].rms.toStringAsFixed(1)} dBFS'
                      '${_windows[i].barged ? ' · 打断了' : ' · 没打断'}',
                  trailing: Icon(
                    _windows[i].barged ? Icons.check_circle_outline : Icons.cancel_outlined,
                    size: 20,
                    color: _windows[i].barged ? scheme.primary : scheme.error,
                  ),
                ),
            ],
          ),
        if (_clips.isNotEmpty)
          SettingsSection(
            title: '录音',
            children: [
              for (var i = 0; i < _clips.length; i++)
                SettingsTile(
                  key: ValueKey('screen-clip-$i'),
                  title: _clips[i].split('/').last,
                  // 之前这里只有标题没有 onTap，所以点不动——看着像按钮，
                  // 实际是块文字。现在点了就用同一套播放器放出来。
                  subtitle: _playing == i ? '正在放…' : '点一下回听：麦克风当时听到的原声',
                  trailing: Icon(
                    _playing == i ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                    size: 20,
                  ),
                  onTap: () => unawaited(_playClip(i)),
                ),
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              title: '怎么用',
              subtitle: '在「通话 → 免提」和「听筒」两种模式下各测一次，比较平均分和打断次数：\n'
                  '· 免提时平均分明显更高 → 我自己的声音漏进来了，是自打断\n'
                  '· 两种模式都打断不了、分数低 → 是声纹本身认不出，调灵敏度或收音档位\n'
                  '两边的收音是同一个设置：这里测的分数可以直接和通话比。',
            ),
          ],
        ),
      ],
    );
  }

  /// 电平显示：−999 / −998 是原生"打不开/没采到"的占位值，别当 dB 读。
  static String _db(double v) => switch (v) {
    <= -997 => '没采到',
    <= -900 => '打不开',
    _ => v.toStringAsFixed(1),
  };

  static String _label(String kind) => switch (kind) {
    'YOU' => '你',
    'OTHER' => '旁人',
    'UNKNOWN' => '不确定',
    'NONE' => '算不出',
    'NOPROFILE' => '没模板',
    _ => kind,
  };
}
