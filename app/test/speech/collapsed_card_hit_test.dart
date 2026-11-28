// 收起之后，屏幕别的地方还能不能点。
//
// 这一课是踩出来的：卡片本身没问题，Problems 出在承载它的那条路由上。
// PageRouteBuilder 的 barrierDismissible 默认是 true，于是透明路由上盖了
// 一层看不见的 ModalBarrier，把整屏的点击都吃掉了——看着像界面卡死，
// 其实是所有手指都落在一个空层上。
//
//   flutter test test/speech/collapsed_card_hit_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 收起卡片现在的结构（与 voice_call_page.dart 的 _collapsedCard 一致）。
Widget collapsedCard(Widget card) {
  return Stack(
    fit: StackFit.expand,
    children: [
      // 占满但不收事件：下面的对话页、输入框都还要能点。
      const IgnorePointer(child: SizedBox.expand()),
      Positioned(
        left: 16,
        right: 16,
        bottom: 20,
        child: RepaintBoundary(
          child: Align(alignment: Alignment.center, child: card),
        ),
      ),
    ],
  );
}

Widget sampleCard({VoidCallback? onExpand}) {
  return SizedBox(
    width: 300,
    height: 56,
    child: Material(
      color: Colors.grey,
      child: Row(
        children: [
          const SizedBox(width: 10),
          const Text('正在听'),
          const Spacer(),
          TextButton(
            key: const ValueKey('expand'),
            onPressed: onExpand ?? () {},
            child: const Text('展开'),
          ),
        ],
      ),
    ),
  );
}

/// 一层底页面（模拟对话页），上面压一条透明路由（模拟收起后的通话页）。
Widget host({
  required Widget overlay,
  required VoidCallback onUnder,
  bool barrierDismissible = false,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: const ValueKey('under'),
                onPressed: onUnder,
                child: const Text('下面的按钮'),
              ),
              TextButton(
                key: const ValueKey('open'),
                onPressed: () => Navigator.of(context).push(
                  PageRouteBuilder<void>(
                    barrierDismissible: barrierDismissible,
                    opaque: false,
                    pageBuilder: (_, _, _) => overlay,
                  ),
                ),
                child: const Text('开'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  // 结论（实测，不是推测）：只要通话是 push 上去的一条路由，收起之后下面的
  // 页面就点不到——跟卡片怎么摆、有没有 barrier 都无关。Flutter 的 Navigator
  // 里，上层路由会占住整块区域，透明只是让它「看得见下面」，不代表「摸得到下面」。
  //
  // 所以「在 App 内收起成一张卡片、同时还能继续用聊天」这条路，靠路由做不到。
  // 要做只能把通话控制器从页面里拿出来，收起时 pop 掉路由，卡片挂在对话页上。
  testWidgets('透明路由就算关掉 barrier，下面也点不到（Navigator 的固有行为）', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(overlay: collapsedCard(sampleCard()), onUnder: () => taps++));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('under')), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0, reason: '这正是「整屏点不了」的根子：不是卡，是路由挡着');
  });

  testWidgets('barrierDismissible 默认 true 时，下面点不到（旧的那种坏）', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(overlay: collapsedCard(sampleCard()), onUnder: () => taps++, barrierDismissible: true),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('under')), warnIfMissed: false);
    await tester.pump();
    // 把当年那个症状钉在这里：barrier 在吃点击。
    expect(taps, 0, reason: '默认的 barrier 会把整屏点击吃掉');
  });

  testWidgets('卡片自己的按钮点得到', (tester) async {
    var expanded = 0;
    await tester.pumpWidget(
      host(overlay: collapsedCard(sampleCard(onExpand: () => expanded++)), onUnder: () {}),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('expand')));
    await tester.pump();
    expect(expanded, 1);
  });
}
