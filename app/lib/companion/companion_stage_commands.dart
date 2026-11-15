// What the companion stage is told and what it tells back.
//
// These two live outside `ui/` on purpose: state and other non-UI code must be
// able to hold a controller and read its events without importing `ui/`
// (docs/architecture.md §2.5, guard: app/test/arch/import_direction_test.dart).
// The WebView that serves the page stays in `ui/companion/companion_stage.dart`
// and re-exports both classes, so existing imports keep working.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'companion_adapt.dart';
import 'companion_moves.dart';

/// Sends commands to the stage; does nothing until it is ready.
class CompanionStageController {
  CompanionStageController({this.sink});

  /// Tests watch commands here instead of a WebView.
  final void Function(String type, Map<String, Object?> args)? sink;

  WebViewController? _web;
  bool _ready = false;

  /// The page behind this controller is up: commands reach it from now on.
  ///
  /// Called by the stage that owns the WebView. Not for other callers.
  void attach(WebViewController web) {
    _web = web;
    _ready = false;
  }

  /// The page said it is ready.
  ///
  /// Called by the stage that owns the WebView. Not for other callers.
  void markReady() {
    _ready = true;
  }

  /// The page is gone (retired, disposed, or the renderer died): commands are
  /// dropped until a new page [attach]es.
  ///
  /// Called by the stage that owns the WebView. Not for other callers.
  void detach() {
    _web = null;
    _ready = false;
  }

  /// Commands from now on reach a page.
  bool get isReady => _ready;

  void command(String type, [Map<String, Object?> args = const {}]) {
    sink?.call(type, args);
    final web = _web;
    if (web == null || !_ready) return;
    // Structured and JSON-encoded: nothing from a reply becomes script.
    unawaited(web.runJavaScript('stage.command(${jsonEncode({'type': type, ...args})})').catchError((Object _) {}));
  }
}

/// What the stage tells the page.
class CompanionStageEvents {
  const CompanionStageEvents({
    required this.onReady,
    required this.onFailed,
    required this.onTouch,
    required this.onWake,
    required this.onMood,
    required this.onObject,
    required this.onActivity,
    this.onModel,
    this.onProbe,
  });

  final VoidCallback onReady;

  /// What the model is (stage.js `probeReport`), when it loads and whenever
  /// an adapter is worn or taken off (companion_adapt.dart).
  final ValueChanged<CompanionProbe>? onProbe;

  /// What the model brings of its own, as it finishes loading (before [onReady]).
  final ValueChanged<CompanionModelInfo>? onModel;
  final ValueChanged<String> onFailed;
  final void Function(String zone, String kind) onTouch;
  final VoidCallback onWake;
  final ValueChanged<String> onMood;

  /// One of her things was tapped: `snack`, `play` or `rest`.
  final ValueChanged<String> onObject;

  /// What she's doing changed (also when it ran out): `idle` / `snack` / `play` / `rest`.
  final ValueChanged<String> onActivity;
}
