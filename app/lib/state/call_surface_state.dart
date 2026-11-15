// Where a call is drawn, and nothing else.
//
// Only the surface is global. The microphone level and the captions change
// every few tens of milliseconds; they belong to whichever stage is drawing
// them, not to a notifier everyone rebuilds on
// (docs/design/wake-call-on-companion.md §3).
//
// The page or window that shows a call reports which shape it is in; a stage
// that wants to know where the call is reads this. Nothing here owns the call:
// [VoiceCallController] stays with whoever created it.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shapes a call can take, smallest first.
enum CallSurface {
  /// No call is being shown (none may be up at all).
  none,

  /// Her on the desktop with a status line, over other apps.
  floating,

  /// Her with one caption line and the call keys, still inside the app.
  expanded,

  /// The page that covers the conversation today.
  full,
}

class CallSurfaceController extends Notifier<CallSurface> {
  @override
  CallSurface build() => CallSurface.none;

  void set(CallSurface surface) {
    if (ref.mounted && surface != state) state = surface;
  }
}

final callSurfaceProvider = NotifierProvider<CallSurfaceController, CallSurface>(CallSurfaceController.new);
