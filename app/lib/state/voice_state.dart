// Voice input: the platform bridge (a seam for tests).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/chat/voice/voice_bridge.dart';

final voiceBridgeProvider = Provider<VoiceBridge>((ref) => MethodChannelVoiceBridge());

// fork(call): 通话宿主（state/voice_call_host.dart）判「权限拿到了」用这个，
// 不用直接 import ui/chat/voice/voice_bridge.dart 枚举——那条 state→ui 的
// 边不许新增（test/arch/import_direction_test.dart 只减不增）。
extension VoicePermissionGranted on VoicePermission {
  bool get granted => this == VoicePermission.granted;
}

/// Asked once per page that shows them.
final voiceCapabilitiesProvider = FutureProvider.autoDispose<VoiceCapabilities>(
  (ref) => ref.watch(voiceBridgeProvider).capabilities(),
);

/// Dictation into the composer is on (starting, listening or transcribing).
/// The chat page reports it; what waits for a quiet moment reads it.
class VoiceInputActiveController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool active) {
    if (ref.mounted && active != state) state = active;
  }
}

final voiceInputActiveProvider = NotifierProvider<VoiceInputActiveController, bool>(VoiceInputActiveController.new);
