/// 平台能力判定：集中描述"桌面端"与"移动端"的行为差异。
///
/// 桌面端与移动端的关键差异：
/// - 桌面端没有 SystemChrome（系统状态栏 / 屏幕方向）概念，相关调用无意义；
/// - 桌面端控件显隐由鼠标移动驱动，而非点击画面；
/// - 桌面端需要键盘快捷键（空格、方向键等），移动端没有键盘。
///
/// 目前仅 Windows 为受支持的桌面平台；macOS / Linux 归入桌面端只是
/// 逻辑上的通用归类，并未做验证，不代表已支持。
library;

import 'dart:io' show Platform;

/// 是否为桌面平台（Windows / macOS / Linux）。
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 是否为移动平台（Android / iOS）。
bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;

/// 是否为 Windows 平台（当前唯一正式支持的桌面平台）。
bool get isWindowsPlatform => Platform.isWindows;
