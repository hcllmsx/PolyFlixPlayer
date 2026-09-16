/// 应用设置：全局可监听的配置项 + 本地持久化。
///
/// 用顶层 ValueNotifier 而不是引入状态管理库：设置项很少，设置页写、
/// 播放页读，两边监听同一个值即可，改动面最小。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kFitWindowToVideo = 'settings.fitWindowToVideo';

/// 打开视频后是否让播放窗口自动适应视频画面比例（仅桌面端生效）。
///
/// 默认关闭：窗口大小随视频变化会打断用户的观看节奏，交给用户自己决定。
final ValueNotifier<bool> fitWindowToVideo = ValueNotifier<bool>(false);

/// 从本地存储载入设置，应在 runApp 之前调用一次。
Future<void> loadAppSettings() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    fitWindowToVideo.value = prefs.getBool(_kFitWindowToVideo) ?? false;
  } catch (_) {
    // 读取失败时保留默认值，不能因为设置读不出来就启动不了。
  }
}

/// 写入"窗口适应视频比例"开关。
Future<void> setFitWindowToVideo(bool value) async {
  fitWindowToVideo.value = value;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFitWindowToVideo, value);
  } catch (_) {
    // 持久化失败不影响本次生效。
  }
}
