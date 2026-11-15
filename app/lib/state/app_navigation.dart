import 'package:flutter/material.dart';

/// 整个 App 的导航钥匙。
///
/// 有些事不从某个页面里发生：唤醒词命中的时候人可能正在别的 App，
/// 这时要用它把通话页推上来（lib/state/wake_state.dart）。
final rootNavigatorKey = GlobalKey<NavigatorState>();
