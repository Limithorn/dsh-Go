import '../l10n/l10n.dart';

/// Build-time app metadata.
///
/// There is no package_info plugin in the dependency set, so the version is a
/// constant kept in sync with `pubspec.yaml` (checked by tooling tests). Release builds can
/// override it with `--dart-define=DSH_APP_VERSION=1.2.0+7`.
abstract final class AppInfo {
  static const version = String.fromEnvironment('DSH_APP_VERSION', defaultValue: '1.3.0+1');

  /// 这一版是怎么打出来的，由 `tool/build_apk.sh` 编进来。
  ///
  /// 版本号本身是常量（`1.2.0+1` 打了三十遍都一样），装到手机上根本分不清
  /// 跑的是哪一个。这个名字带着提交哈希和时间，写在诊断页最上面。
  ///
  /// 手工 `flutter build` 时这三个都为空，[buildLabel] 会退回版本号。
  static const buildName = String.fromEnvironment('DSH_BUILD_NAME');
  static const buildCommit = String.fromEnvironment('DSH_BUILD_COMMIT');
  static const buildTime = String.fromEnvironment('DSH_BUILD_TIME');

  /// 诊断页顶上那一行。
  static String get buildLabel {
    if (buildName.isNotEmpty) return buildName;
    // 没走脚本时至少把版本号显示出来，别让人以为这行是空的。
    return displayVersion;
  }

  /// "1.0.0 (1)" for display.
  static String get displayVersion {
    final parts = version.split('+');
    return parts.length == 2 ? '${parts[0]} (${parts[1]})' : version;
  }

  /// The app's name as the phone shows it: launcher, Recents, notifications, system
  /// settings, the licence page. Matches `android:label` in AndroidManifest.xml.
  static const name = 'DSH Go';

  /// The in-app wordmark: the drawer's lockup, the welcome page and the brand mark's
  /// spoken label.
  static const wordmark = 'DSH';

  /// Required wording: the app is built on DSH but is not an official DeepSeek product.
  /// Shown on the About and licence pages.
  static String get disclaimer => appL10n.stateAppDisclaimer;

  /// The line under the brand mark (welcome page, 关于 dsh-go).
  static String get slogan => appL10n.appSlogan;

  /// The original DSH Go author and their personal profiles, not project pages.
  static const author = 'ccch1mneyyy';
  static const authorBilibiliName = 'ccchimneyyy';
  static const authorBilibiliUrl = 'https://b23.tv/9WBns6Y';
  static const authorXHandle = '@cccch1mneyyyy';
  static const authorXUrl = 'https://x.com/cccch1mneyyyy';
  static const authorGithubUrl = 'https://github.com/ccch1mneyyy';

  static const deepseekPlatform = 'https://platform.deepseek.com/api_keys';
  static const remoteConsole = 'https://dsh.r2049.cn/app';

  /// DSH Remote's upstream, credited under the DSH Remote card as its GitHub
  /// handle and name.
  static const remoteProject = 'liguobao/ds-harness-remote';
  static const remoteProjectUrl = 'https://github.com/$remoteProject';
}
