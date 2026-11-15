// The WebView that draws the companion (app/assets/companion/). Everything
// Live2D happens in there; this widget serves it, passes commands in and events
// out, and pauses it when nobody can see it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../companion/companion_adapt.dart';
import '../../companion/companion_moves.dart';
import '../../companion/companion_pack.dart';
import '../../companion/companion_server.dart';
import '../../companion/companion_stage_commands.dart';
import '../plugins/islands/island_platform.dart';
import '../web/web_view_guard.dart';

// The controller and the events live in companion/ so non-UI code can hold them;
// re-exported here so every existing import of this file keeps working.
export '../../companion/companion_stage_commands.dart';

/// Phones with less memory than this get a smaller texture (4096² is about
/// 64 MB of GPU memory, more with mipmaps).
// Physical memory reported by iOS is slightly below the marketed RAM size;
// this separates the 4 GB and 6 GB device classes without a model-name list.
const _bigTextureFromBytes = 5 * 1024 * 1024 * 1024;

/// Why a stage left for good on its own account ([CompanionStageEvents.onFailed]):
/// her renderer died, or the pack under her was about to change. Not for the
/// person to read; the room has its own words for them.
const companionStageRendererGone = 'renderer gone';
const companionStagePackChanged = 'pack changed';

class CompanionStage extends StatefulWidget {
  const CompanionStage({
    super.key,
    required this.store,
    required this.controller,
    required this.events,
    this.bare = false,
  });

  final CompanionPackStore store;
  final CompanionStageController controller;
  final CompanionStageEvents events;

  /// The model alone on a see-through page, without her room around it (the
  /// tavern's visual novel draws its own scene behind).
  final bool bare;

  @override
  State<CompanionStage> createState() => _CompanionStageState();
}

class _CompanionStageState extends State<CompanionStage> with WidgetsBindingObserver {
  static const _readyTimeout = Duration(seconds: 40);

  CompanionServer? _server;
  WebViewController? _web;

  /// The Android WebView behind [_web], once it is guarded.
  int? _webId;
  StreamSubscription<IslandPlatformEvent>? _platformEvents;
  void Function()? _unhook;

  /// Goes up each time her WebView is retired: a start that awaited across
  /// one gives up, and the retired page is no longer heard.
  int _generation = 0;
  Timer? _timeout;
  AppLifecycleState? _lifecycle;
  bool _routeVisible = true;
  bool? _appliedPause;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _platformEvents = IslandPlatform.instance.events.listen((event) {
      // One renderer for every WebView of the app: any loss is hers too.
      if (event is IslandRendererGone && _webId != null) unawaited(_retire(companionStageRendererGone));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Off only when a page covers the room whole (the memory page): a sheet or
    // a dialog over her leaves her moving under it, not frozen.
    _routeVisible = TickerMode.valuesOf(context).enabled;
    _syncVisibility();
  }

  void _syncVisibility() {
    if (!widget.controller.isReady) return;
    final pause = !_routeVisible || (_lifecycle != null && _lifecycle != AppLifecycleState.resumed);
    if (_appliedPause == pause) return;
    _appliedPause = pause;
    widget.controller.command(pause ? 'pause' : 'resume');
  }

  Future<void> _start() async {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final generation = _generation;
    bool stale() => generation != _generation;
    // Before the pack under her changes she stops reading it. Never call the
    // store from this hook: it runs inside the store's queue.
    _unhook = widget.store.beforeChanges(() => _retire(companionStagePackChanged));
    try {
      final server = await CompanionServer.start(rootBundle, widget.store.pack);
      if (stale()) {
        await server.close();
        return;
      }
      _server = server;
      final device = await IslandPlatform.instance.device();
      if (stale()) return;
      // WebKit's GPU-process budget is separate from the phone's RAM.
      final ios = defaultTargetPlatform == TargetPlatform.iOS;
      final small = device.totalMem > 0 ? device.totalMem < _bigTextureFromBytes : ios;
      final lowMemory = device.totalMem <= 0 || device.totalMem <= 3 * 1024 * 1024 * 1024;
      final web = WebViewController(onPermissionRequest: (request) => unawaited(request.deny()));
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(widget.bare ? const Color(0x00000000) : const Color(0xFF0D2F55));
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              server.ownsUrl(request.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onWebResourceError: (error) {
            if (generation == _generation && (error.isForMainFrame ?? false)) _fail('load ${error.errorCode}');
          },
        ),
      );
      await web.addJavaScriptChannel(
        'DshCompanion',
        onMessageReceived: (m) {
          if (generation == _generation) _onMessage(m.message);
        },
      );
      if (stale()) return;
      // After the navigation delegate: the guard wraps the client it set.
      // Her renderer is the floating window's too; unguarded, its death takes
      // the app with it, so she doesn't load without the guard. (The page has
      // no text and its own colours: nothing else of the attach applies.)
      final id = defaultTargetPlatform == TargetPlatform.android ? WebViewGuard.identifierOf(web) : null;
      if (id != null) {
        final guarded = await IslandPlatform.instance.attach(id, dark: false, textZoom: 100);
        if (stale()) return;
        if (!guarded) {
          _fail('guard');
          return;
        }
        _webId = id;
      }
      widget.controller.attach(web);
      setState(() {
        _web = web;
      });
      _timeout = Timer(_readyTimeout, () => _fail('timeout'));
      await web.loadRequest(
        server.pageUrl(
          query: {
            if (small) 'maxTexture': ios && lowMemory ? '1024' : '2048',
            if (ios) ...{
              'dpr': lowMemory
                  ? '1'
                  : small
                  ? '1.5'
                  : '2',
              'antialias': '0',
              'gpuBudget': 'low',
            },
            if (reduceMotion) 'reduceMotion': '1',
            if (widget.bare) 'bare': '1',
          },
        ),
      );
    } on Object catch (error) {
      if (generation == _generation) _fail('$error');
    }
  }

  /// Her WebView leaves for good and its server closes: the renderer died, or
  /// the pack is about to change (the store waits here for the last handler).
  /// The room builds a new stage; this one is not loaded again.
  Future<void> _retire(String why) async {
    if (kDebugMode) debugPrint('[companion] stage retired: $why');
    if (mounted) {
      _generation++;
      _timeout?.cancel();
      final id = _webId;
      widget.controller.detach();
      _webId = null;
      if (_web != null) setState(() => _web = null);
      // Destroyed once the frame without its widget is drawn, as the other
      // pages do. Not awaited: no frame comes while the app is hidden, and
      // the store's queue must not wait for one.
      if (id != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(IslandPlatform.instance.destroy(id)));
      }
    }
    await _server?.close();
    _fail(why);
  }

  void _onMessage(String raw) {
    if (!mounted) return;
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (message is! Map) return;
    final events = widget.events;
    switch (message['type']) {
      case 'ready':
        _timeout?.cancel();
        widget.controller.markReady();
        _appliedPause = null;
        _syncVisibility();
        // What the model is first: its moves are kept by its fingerprint.
        if (CompanionProbe.fromJson(message['probe']) case final probe?) events.onProbe?.call(probe);
        events.onModel?.call(CompanionModelInfo.fromMessage(message));
        events.onReady();
      case 'adapted':
        if (CompanionProbe.fromJson(message['probe']) case final probe?) events.onProbe?.call(probe);
      case 'error':
        _fail('${message['message']}');
      case 'touch':
        final zone = message['zone'];
        final kind = message['kind'];
        if (zone is String && kind is String) events.onTouch(zone, kind);
      case 'wake':
        events.onWake();
      case 'mood':
        final mood = message['mood'];
        if (mood is String) events.onMood(mood);
      case 'object':
        final id = message['id'];
        if (id is String && const {'snack', 'play', 'rest'}.contains(id)) events.onObject(id);
      case 'activity':
        final name = message['name'];
        if (name is String) events.onActivity(name);
    }
  }

  void _fail(String why) {
    _timeout?.cancel();
    if (mounted) widget.events.onFailed(why);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_platformEvents?.cancel());
    _generation++;
    _timeout?.cancel();
    widget.controller.detach();
    // The hook stays until the server has closed: a pack change that races
    // leaving the room waits for the last handler too.
    final unhook = _unhook;
    unawaited((_server?.close() ?? Future<void>.value()).whenComplete(() => unhook?.call()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    if (web == null) return const SizedBox.expand();
    return WebViewWidget(
      controller: web,
      // Her touch handling lives in the page: strokes must not become scrolls
      // or the back gesture's competitors.
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}
