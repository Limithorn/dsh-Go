// 收起卡片与小窗共用的通话组件：状态一句话、那颗光球、四键卡片本身。
//
// 从 voice_call_page.dart 抽出（fork(call) 的 A 区）：页面与 RootGate 的
// CallCardLayer 都只做装配，这里承载卡片自己的样子与语义。

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../speech/call/voice_call.dart';
import '../../../speech/speech_settings.dart';
import '../../fx/voice_ring/voice_ring.dart';
import '../../theme/app_icons.dart';
import 'call_visuals.dart';

/// The status line for a call, wherever it is drawn: on the page, on the
/// 收起 card, in the picture-in-picture window. [signedIn] is read lazily,
/// only to word the no-recognizer ending — it drags the account's connection
/// state with it, which nobody should pay for just to word a status.
(String, bool) callStatus(L10n l10n, VoiceCallController call, {required bool Function() signedIn}) {
  if (call.phase == CallPhase.ended) {
    return (
      switch (call.ended) {
        CallEnd.permission => l10n.speechCallEndPermission,
        CallEnd.microphone => l10n.speechCallEndMicrophone,
        CallEnd.noRecognizer =>
          wordsForIos
              ? (signedIn() ? l10n.iosSpeechCallEndNoRecognizerSignedIn : l10n.iosSpeechCallEndNoRecognizer)
              : (signedIn() ? l10n.speechCallEndNoRecognizerSignedIn : l10n.speechCallEndNoRecognizer),
        CallEnd.background => l10n.speechCallEndBackground,
        CallEnd.failed => l10n.speechCallEndFailed,
        CallEnd.hungUp || null => l10n.speechCallEnded,
      },
      false,
    );
  }
  if (call.muted && call.phase != CallPhase.speaking && call.phase != CallPhase.thinking) {
    return (l10n.speechCallMuted, false);
  }
  return switch (call.phase) {
    CallPhase.starting => (l10n.speechCallStarting, true),
    CallPhase.listening => (l10n.speechCallListening, true),
    CallPhase.hearing => (l10n.speechCallHearing, false),
    CallPhase.thinking => (l10n.speechCallThinking, true),
    CallPhase.speaking => (l10n.speechCallSpeaking, false),
    CallPhase.ended => (l10n.speechCallEnded, false),
  };
}

/// 整页和小窗共用的那颗光球：按设置画玻璃球或声波环，都由 [scene] 驱动。
/// 抽出来是为了小窗不再贴一张静态图，而是和通话界面同一套动画。
class CallOrb extends StatelessWidget {
  const CallOrb({
    super.key,
    required this.scene,
    required this.call,
    required this.visual,
    required this.palette,
    required this.dark,
    required this.size,
    this.halo = 1,
  });

  final CallScene scene;
  final VoiceCallController call;
  final CallVisual visual;
  final CallPalette palette;
  final bool dark;
  final double size;

  /// Softened for the small window; the page keeps 1.
  final double halo;

  @override
  Widget build(BuildContext context) {
    if (visual == CallVisual.glass) {
      return CallLight(key: const ValueKey('glass'), scene: scene, palette: palette, size: size, halo: halo);
    }
    final phase = call.phase;
    return VoiceRing(
      key: ValueKey(visual),
      type: visual == CallVisual.mono ? VoiceRingType.mono : VoiceRingType.ring,
      state: switch (phase) {
        CallPhase.starting || CallPhase.thinking => VoiceRingState.processing,
        CallPhase.listening || CallPhase.hearing => VoiceRingState.listening,
        CallPhase.speaking => VoiceRingState.speaking,
        CallPhase.ended => VoiceRingState.idle,
      },
      size: size * 0.82,
      theme: dark ? VoiceRingTheme.dark : VoiceRingTheme.light,
      paused: phase == CallPhase.ended,
      level: () => switch (call.phase) {
        CallPhase.hearing when !call.muted => VoiceRingLevel.mic(call.micLevel),
        CallPhase.speaking => VoiceRingLevel.playback(call.voiceLevel),
        _ => 0,
      },
    );
  }
}

/// 收起后的通话卡片：状态一句 + 静音、展开、小窗、挂断四个键。
///
/// 只画卡片自己，不占整屏——挂它的地方各自负责摆放（页面里 [VoiceCallPage]
/// 折叠时垫一整层，RootGate 的 CallCardLayer 只在底部摆一张）。整屏的
/// 触摸穿透问题出在路由上，不在卡片上（collapsed_card_hit_test.dart）。
class CollapsedCallCard extends StatelessWidget {
  const CollapsedCallCard({
    super.key,
    required this.status,
    required this.ended,
    required this.l10n,
    required this.theme,
    required this.onExpand,
    required this.onPip,
    required this.onHangUp,
    this.muted = false,
    this.onMute,
  });

  /// 窄卡片：不是横贯屏幕的一条。留出来的左右余量既是给用户「挪开挡住的内容」，
  /// 也是拖动边界能真正放开的前提（第三轮按屏宽推 ±8，就是因为宽度被钉死）。
  static const double width = 248;

  final String status;
  final bool ended;
  final L10n l10n;
  final ThemeData theme;
  final VoidCallback onExpand;
  final Future<void> Function() onPip;
  final VoidCallback onHangUp;
  final bool muted;
  final VoidCallback? onMute;

  /// 四个键压到 38dp：真机上仍是够点的靶子，但一行能塞进一张窄卡片。
  Widget _key({
    required String key,
    required String? tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
  }) =>
      IconButton(
        key: ValueKey<String>(key),
        tooltip: tooltip,
        icon: icon,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 38, height: 38),
        visualDensity: VisualDensity.compact,
      );

  @override
  Widget build(BuildContext context) {
    final ink = theme.colorScheme;
    return Material(
      key: const ValueKey('call-collapsed'),
      elevation: 10,
      borderRadius: BorderRadius.circular(22),
      color: ink.surfaceContainerHigh,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            children: [
              // 不是装饰：它和整页那个键一样，是静音/取消静音。
              _key(
                key: 'call-collapsed-mute',
                tooltip: muted ? l10n.speechCallUnmute : l10n.speechCallMute,
                icon: Icon(
                  muted ? AppIcons.micMuted : AppIcons.voice,
                  size: 18,
                  color: muted ? ink.error : ink.primary,
                ),
                onPressed: ended || onMute == null ? null : onMute,
              ),
              Expanded(
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              _key(
                key: 'call-expand',
                tooltip: l10n.speechCallExpand,
                icon: const Icon(Icons.open_in_full, size: 18),
                onPressed: onExpand,
              ),
              _key(
                key: 'call-picture-in-picture',
                tooltip: l10n.speechCallPictureInPicture,
                icon: const Icon(Icons.picture_in_picture_alt, size: 18),
                onPressed: ended ? null : onPip,
              ),
              _key(
                key: 'call-collapsed-hang-up',
                tooltip: l10n.speechCallHangUp,
                icon: Icon(AppIcons.hangUp, size: 20, color: ink.error),
                onPressed: ended ? null : onHangUp,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
