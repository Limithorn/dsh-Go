// 收起成卡片、同时还能继续用聊天 —— 这套流程的保护测试。
//
// 结论（collapsed_card_hit_test.dart 钉死的）：只要通话是 push 上去的一条路由，
// 收起后下面的页面就点不到。所以通话控制器必须从页面里拿出来
// （state/voice_call_host.dart）：收起 = pop 掉全屏路由、卡片挂到 RootGate 的
// CallCardLayer 上、点卡片重新 push 页面、通话不中断。
//
// 这组测试先于实现写就，先红后绿；红的那几条就是这次要做成的事。
//
//   flutter test test/speech/collapsed_call_flow_test.dart

import 'dart:typed_data';

import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/state/voice_call_host.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/speech/voice_call_page.dart';
import 'package:flutter/material.dart';
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
  });

  List<Override> callOverrides(FakeAudio audio, String said) => [
    speechAudioProvider.overrideWithValue(audio),
    callRecognizerProvider.overrideWithValue(() async => FakeCloud(said)),
    voiceBridgeProvider.overrideWithValue(FakeVoiceBridge()),
    deepSeekSpeechProvider.overrideWithValue(() async => FakeDeepSeek()),
  ];

  /// The app as the phone has it: the chat page beneath, the card layer the
  /// RootGate hangs, and a call opened the way the chat page opens one.
  Future<(FakeAudio, FakeConversation)> pumpHosted(
    WidgetTester tester, {
    FakeConversation? conversation,
    void Function()? onChatTap,
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
                    TextButton(
                      key: const ValueKey('chat-input'),
                      onPressed: onChatTap ?? () {},
                      child: const Text('下面的输入框'),
                    ),
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
      // The saved voice is read with real async work before the call starts listening.
      if (i % 5 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    return (audio, conv);
  }

  /// 收起：点通话页的收起键，等出场的动画走完。
  Future<void> collapse(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('call-collapse')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('收起后：路由收掉、通话仍在、卡片可见、下面的聊天页还能点', (tester) async {
    var taps = 0;
    final (audio, _) = await pumpHosted(tester, onChatTap: () => taps++);
    expect(find.text('在听'), findsOneWidget);

    await collapse(tester);

    // 收起不是把页面藏起来：那条全屏路由必须收掉，这是点不到别处的根子。
    expect(find.byType(VoiceCallPage), findsNothing);
    // 通话仍在宿主里活着，没被页面带走。
    final call = VoiceCallHost.instance.call;
    expect(call, isNotNull, reason: '控制器要归宿主（voice_call_host.dart），页面来去通话不动');
    expect(call!.phase, isNot(CallPhase.ended));
    expect(audio.calls, isNot(contains('callStop')));
    // 卡片挂上来了。
    expect(find.byKey(const ValueKey('call-collapsed')), findsOneWidget);
    // 下面的聊天页要点得到——这是这次改造要做成的事。
    await tester.tap(find.byKey(const ValueKey('chat-input')), warnIfMissed: false);
    await tester.pump();
    expect(taps, 1, reason: '收起后屏幕别处必须能点：卡片只在它自己那块收触摸');
  });

  testWidgets('点卡片：回到通话页，通话没断，卡片退下去', (tester) async {
    final (audio, conversation) = await pumpHosted(tester);
    await collapse(tester);

    await tester.tap(find.byKey(const ValueKey('call-expand')));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.byType(VoiceCallPage), findsOneWidget);
    expect(find.byKey(const ValueKey('call-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-collapsed')), findsNothing);
    expect(find.text('在听'), findsOneWidget);
    expect(audio.calls, isNot(contains('callStop')));
    expect(VoiceCallHost.instance.call!.phase, isNot(CallPhase.ended));

    // 回到通话页，一整轮对话照常：听见、发出去、她答上来。
    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 2)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(conversation.sent.single, endsWith('这周末北京天气怎么样'));
  });

  testWidgets('收起期间她说完一句：卡片上的状态跟着变', (tester) async {
    final (audio, conversation) = await pumpHosted(tester);
    await collapse(tester);
    expect(find.byKey(const ValueKey('call-collapsed')), findsOneWidget);
    expect(find.text('在听'), findsOneWidget);

    // 一轮对话从收着的状态里走完：他在说、她在想、她说、说完。
    audio.emit(const SpeechStart(over: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('你在说'), findsOneWidget);

    audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 2)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('想一想'), findsOneWidget);

    conversation.reply('北京晴，最高二十度。', done: true);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final id = RegExp(r'^open:(\S+):call=true$').firstMatch(audio.calls.lastWhere((c) => c.startsWith('open:')))![1]!;
    audio.emit(PlayEvent(id, PlayPhase.start));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('正在说，轻点光球可以跳过'), findsOneWidget);

    audio.emit(PlayEvent(id, PlayPhase.done));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('在听'), findsOneWidget);
    expect(audio.calls, isNot(contains('callStop')), reason: '整轮走完，通话没断过');
  });

  testWidgets('收起时出了岔子：页面弹回来让人读到原因，然后收拾干净', (tester) async {
    final (audio, _) = await pumpHosted(tester);
    await collapse(tester);

    // 麦克风被系统收走这类结束原因：从卡片上也看得到，但得把页面弹回来才读得清。
    audio.emit(const CallError('mic'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(VoiceCallPage), findsOneWidget, reason: '收起时结束的通话要把页面弹回来，让人读到原因');

    // 原因亮够一会儿，页面自己收掉，宿主把一切清干净。
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(VoiceCallPage), findsNothing);
    expect(find.byKey(const ValueKey('call-collapsed')), findsNothing);
    expect(VoiceCallHost.instance.call, isNull);
    expect(audio.calls, contains('callStop'));
  });
}
