// 卡片控制、返回键、会话绑定 —— 这轮几件欠账的保护测试。
//
// 先于实现写就，先红后绿。每一条红在它自己那件事上，不牵连既有测试：
//
//   flutter test test/speech/call_card_controls_test.dart

import 'package:dsh_app/speech/call/chat_call.dart';
import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/state/picture_in_picture.dart';
import 'package:dsh_app/state/voice_call_host.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/speech/voice_call_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart';
import '../chat/support/harness.dart';
import 'speech_fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    addTearDown(VoiceCallHost.instance.reset);
    addTearDown(() => pictureInPictureMode.value = false);
  });

  List<Override> callOverrides(FakeAudio audio, String said) => [
    speechAudioProvider.overrideWithValue(audio),
    callRecognizerProvider.overrideWithValue(() async => FakeCloud(said)),
    voiceBridgeProvider.overrideWithValue(FakeVoiceBridge()),
    deepSeekSpeechProvider.overrideWithValue(() async => FakeDeepSeek()),
  ];

  Future<(FakeAudio, FakeConversation)> pumpHosted(
    WidgetTester tester, {
    FakeConversation? conversation,
    Widget? probe,
    String said = '这周末北京天气怎么样',
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final audio = FakeAudio();
    final conv = conversation ?? FakeConversation();
    await tester.pumpWidget(
      testApp(
        CallCardLayer(
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const ValueKey('open'),
                      onPressed: () => openChatCall(
                        context,
                        title: '周末去哪儿玩',
                        session: () async => null,
                        conversation: conv,
                      ),
                      child: const Text('open'),
                    ),
                    probe ?? const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ),
        ),
        overrides: callOverrides(audio, said),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      if (i % 5 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    return (audio, conv);
  }

  Future<void> collapse(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('call-collapse')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> say(WidgetTester tester, FakeAudio audio) async {
    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 2)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('卡片能拖动：拖过之后位置变了，三个键还点得到', (tester) async {
    await pumpHosted(tester);
    await collapse(tester);
    final card = find.byKey(const ValueKey('call-collapsed'));
    final before = tester.getRect(card);

    await tester.drag(card, const Offset(-80, -160));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final after = tester.getRect(card);

    expect(after.top, lessThan(before.top - 100), reason: '拖上去 160，卡片得跟着走');
    expect(after.left, lessThan(before.left - 40), reason: '拖左 80，卡片得跟着走');

    // 拖动不能吃掉按钮的单击：展开键照旧把页面带回来。
    await tester.tap(find.byKey(const ValueKey('call-expand')));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(VoiceCallPage), findsOneWidget);
    expect(VoiceCallHost.instance.call!.phase, isNot(CallPhase.ended));
  });

  testWidgets('卡片上的麦克风键能静音、再点取消，卡片状态跟着变', (tester) async {
    await pumpHosted(tester);
    await collapse(tester);
    final mute = find.byKey(const ValueKey('call-collapsed-mute'));
    expect(mute, findsOneWidget, reason: '麦克风不是装饰图标，得是能点的键');
    expect(find.text('在听'), findsOneWidget);

    await tester.tap(mute);
    await tester.pump();
    expect(VoiceCallHost.instance.call!.muted, isTrue);
    expect(find.text('已静音'), findsOneWidget);

    await tester.tap(mute);
    await tester.pump();
    expect(VoiceCallHost.instance.call!.muted, isFalse);
    expect(find.text('在听'), findsOneWidget);
  });

  testWidgets('通话整页按返回：收起成卡片，通话没退出', (tester) async {
    await pumpHosted(tester);
    expect(find.byType(VoiceCallPage), findsOneWidget);
    final scopes = find.descendant(of: find.byType(VoiceCallPage), matching: find.byWidgetPredicate((w) => w is PopScope));
    expect(scopes, findsOneWidget, reason: '整页得拦住返回，不能直接 pop 掉通话');
    final scope = tester.widget<PopScope>(scopes);
    expect(scope.canPop, isFalse);

    scope.onPopInvokedWithResult!(false, null);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(VoiceCallPage), findsNothing, reason: '返回 = 收起，路由收掉');
    expect(find.byKey(const ValueKey('call-collapsed')), findsOneWidget, reason: '卡片得在，不然看着像通话没了');
    expect(VoiceCallHost.instance.call!.phase, isNot(CallPhase.ended));
  });

  testWidgets('收起后按返回：进画中画小窗，不裸退后台', (tester) async {
    var pips = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('dsh/app'), (call) async {
      if (call.method == 'enterPictureInPicture') {
        pips++;
        return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('dsh/app'), null));

    await pumpHosted(tester);
    await collapse(tester);
    final scopes = find.descendant(of: find.byType(CallCardLayer), matching: find.byWidgetPredicate((w) => w is PopScope));
    expect(scopes, findsWidgets, reason: '卡片状态也得拦住返回');
    final scope = tester.widget<PopScope>(scopes.first);
    expect(scope.canPop, isFalse);

    scope.onPopInvokedWithResult!(false, null);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(pips, 1, reason: '按返回要主动进小窗，麦克风才不被掐');
    expect(find.byKey(const ValueKey('call-collapsed')), findsOneWidget, reason: '不能把人直接送进后台');
    expect(VoiceCallHost.instance.call!.phase, isNot(CallPhase.ended));
  });

  testWidgets('进小窗不卸载聊天页：回来后发起页还活着（会话没丢）', (tester) async {
    Probe.starts = 0;
    Probe.ends = 0;
    await pumpHosted(tester, probe: const Probe());
    await collapse(tester);
    // 收起到进小窗这一段不能重建发起页：会话绑定挂在它身上。
    final starts = Probe.starts;
    final ends = Probe.ends;

    pictureInPictureMode.value = true;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(Probe.ends, ends, reason: '小窗里画简版，但不能把下面整棵页面树拆了：会话绑定挂在发起页上');
    expect(Probe.starts, starts);

    pictureInPictureMode.value = false;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(Probe.starts, starts, reason: '回到 App 不该重建发起页');
    expect(Probe.ends, ends);
  });

  testWidgets('识别的文本没发到会话：不立刻报「没发出去」，恢复后自动补发', (tester) async {
    final (audio, conversation) = await pumpHosted(tester);
    conversation.accept = false;

    await say(tester, audio);
    expect(conversation.sent, hasLength(1));
    expect(find.text('没发出去，再说一次'), findsNothing, reason: '先等会话接住这句话，别马上叫人重说');

    conversation.accept = true;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(conversation.sent.length, greaterThan(1), reason: '会话能收了，要把原来那句补发过去');
    expect(conversation.sent.last, endsWith('这周末北京天气怎么样'));
  });

  testWidgets('收起后仍听着原生的小窗事件：进小窗时这层会知道', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await pumpHosted(tester);
    await collapse(tester);

    // 原生通知「进了画中画」。页面 pop 时若把通道监听拆了，这条消息就没人接，
    // 小窗里显示的还是挤扁的整页，会话状态也跟着乱。
    const codec = StandardMethodCodec();
    final data = codec.encodeMethodCall(const MethodCall('pictureInPictureChanged', true));
    await messenger.handlePlatformMessage('dsh/app', data, (_) {});
    await tester.pump();
    expect(pictureInPictureMode.value, isTrue, reason: '页面 pop 不能把画中画监听拆了，否则进了小窗这层也不知道');
  });

  testWidgets('收起后原生仍知道通话在继续：按返回/按 home 才会进小窗', (tester) async {
    bool? active;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('dsh/app'), (call) async {
      if (call.method == 'setCallActive') active = (call.arguments as Map)['active'] as bool?;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('dsh/app'), null));

    await pumpHosted(tester);
    expect(active, isTrue);
    await collapse(tester);
    expect(active, isTrue, reason: '页面 pop 掉不能把原生通话标志关掉，否则按返回只会裸退后台');
  });

  test('会话只解析一次：发起页后来失效也不影响这通电话', () async {
    var calls = 0;
    var alive = true;
    final pinned = PinnedSession(() async {
      calls++;
      return alive ? 'session-1' : null;
    });
    expect(await pinned.id(), 'session-1');
    alive = false;
    expect(await pinned.id(), 'session-1', reason: 'id 一旦拿到就是这通电话的，不再问发起页');
    expect(calls, 1);
  });
}

/// 发起页的替身：它在不在、有没有被重建，一眼看得出来。
class Probe extends StatefulWidget {
  const Probe({super.key});

  static int starts = 0;
  static int ends = 0;

  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  @override
  void initState() {
    super.initState();
    Probe.starts++;
  }

  @override
  void dispose() {
    Probe.ends++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
