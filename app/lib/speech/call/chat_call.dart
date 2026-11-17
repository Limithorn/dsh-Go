// A call with a conversation of the main chat: what the person says is sent
// as a message, as if typed (an open question takes it as its answer, like the
// composer does); the reply is every assistant step of the turn that follows,
// read in order (「我查一下」 before a tool call is said too).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import 'voice_call.dart';

/// The conversation a call belongs to, resolved once and then held.
///
/// The page that opened the call can go away (收起 pops its route, 画中画
/// rebuilds the tree): a callback that reads that page's `mounted` or its
/// draft then starts answering null, and every spoken sentence is lost with
/// 「没发出去，再说一次」. A successful id is the call's, for good.
class PinnedSession {
  PinnedSession(this._resolve);

  final Future<String?> Function() _resolve;
  Future<String?>? _inFlight;
  String? _id;

  /// A successful id belongs to the call for good. The page that answered
  /// can be gone (收起, 画中画, a draft switch) — asking it again would only
  /// answer null and lose every sentence with 「没发出去，再说一次」.
  /// A miss is not pinned: the next turn may settle it.
  Future<String?> id() {
    final pinned = _id;
    if (pinned != null) return Future<String?>.value(pinned);
    return _inFlight ??= _resolve().then((value) {
      if (value != null) _id = value;
      _inFlight = null;
      return value;
    });
  }
}

class ChatCallConversation implements CallConversation {
  /// [session] gives the conversation's id, creating it for a new chat.
  /// Asked at most once successfully: the call keeps the conversation it
  /// began in, even if the page that opened it is gone.
  ChatCallConversation(this._container, Future<String?> Function() session)
    : _pinned = PinnedSession(session);

  final ProviderContainer _container;
  final PinnedSession _pinned;
  final _replies = StreamController<CallReply>.broadcast();
  ProviderSubscription<ChatState>? _sub;
  String? _id;
  bool _disposed = false;

  /// The assistant steps already there before the last send.
  Set<String> _before = const {};
  bool _tracking = false;
  bool _sawRunning = false;
  String _last = '';
  Timer? _idle;

  @override
  Stream<CallReply> get replies => _replies.stream;

  @override
  bool get waiting {
    final id = _id;
    if (id == null) return false;
    final s = _container.read(chatProvider(id));
    return s.openApproval != null || s.questions.isNotEmpty;
  }

  /// The conversation the call is in, once it has one.
  String? get sessionId => _id;

  void _follow(String id) {
    if (_id == id && _sub != null) return;
    _sub?.close();
    _id = id;
    _sub = _container.listen<ChatState>(chatProvider(id), (_, next) => _changed(next));
    // Its replies are heard here: no banner for them while the call is up.
    _container.read(callChatProvider.notifier).set((host: _container.read(activeHostProvider), sessionId: id));
  }

  @override
  Future<bool> send(String text) async {
    final id = await _pinned.id();
    // The call ended while its conversation was made: nothing to follow.
    if (id == null || _disposed) return false;
    _follow(id);
    final chat = _container.read(chatProvider(id).notifier);
    var state = _container.read(chatProvider(id));
    if (!state.controlReady && !await chat.waitForSync()) return false;
    // Hung up while the conversation caught up: it is not sent.
    if (_disposed) return false;
    state = _container.read(chatProvider(id));
    _before = {
      for (final item in state.items)
        if (item is AssistantChatItem) item.key,
    };
    _tracking = true;
    _sawRunning = state.running;
    _last = '';
    final bool ok;
    if (state.singleQuestion case final request? when state.openApproval == null) {
      ok = await chat.answer(request, [QuestionAnswer(request.questions.single.id, custom: text)]);
    } else {
      ok = await chat.send(text);
    }
    if (!ok) {
      _tracking = false;
      return false;
    }
    if (_disposed) return true;
    // A turn that never starts (sent while another one wraps up): give up waiting after a while.
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 90), () {
      if (_tracking && !_sawRunning) _done();
    });
    return true;
  }

  void _changed(ChatState state) {
    if (!_tracking) return;
    if (state.running) _sawRunning = true;
    final steps = [
      for (final item in state.items)
        if (item is AssistantChatItem && !_before.contains(item.key) && item.text.trim().isNotEmpty) item.text.trim(),
    ];
    final text = steps.join('\n');
    if (text != _last && text.length >= _last.length) {
      _last = text;
      if (!_replies.isClosed) _replies.add(CallReply(text, done: false));
    }
    if (_sawRunning && !state.running) _done();
  }

  void _done() {
    if (!_tracking) return;
    _tracking = false;
    _idle?.cancel();
    if (!_replies.isClosed) _replies.add(CallReply(_last, done: true));
  }

  @override
  Future<void> interrupt() async {
    final id = _id;
    _tracking = false;
    _idle?.cancel();
    if (id == null) return;
    if (_container.read(chatProvider(id)).running) await _container.read(chatProvider(id).notifier).cancel();
  }

  @override
  void dispose() {
    _disposed = true;
    _idle?.cancel();
    _sub?.close();
    _sub = null;
    unawaited(_replies.close());
  }
}
