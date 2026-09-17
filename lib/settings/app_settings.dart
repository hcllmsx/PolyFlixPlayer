/// 应用设置：全局可监听的配置项 + 本地持久化。
///
/// 用顶层 ValueNotifier 而不是引入状态管理库：设置项很少，设置页写、
/// 播放页读，两边监听同一个值即可，改动面最小。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kFitWindowToVideo = 'settings.fitWindowToVideo';
const String _kAiSubtitleEnabled = 'settings.aiSubtitleEnabled';
const String _kAiAsrModelId = 'settings.aiAsrModelId';

/// 打开视频后是否让播放窗口自动适应视频画面比例（仅桌面端生效）。
///
/// 默认关闭：窗口大小随视频变化会打断用户的观看节奏，交给用户自己决定。
final ValueNotifier<bool> fitWindowToVideo = ValueNotifier<bool>(false);

/// AI 字幕功能总开关。
///
/// 开启后，在播放页会出现 AI 字幕按钮，用户可以选择使用 ASR 语音识别
/// 生成字幕。此开关独立于视频是否有内置字幕——即使有内置字幕也可开启。
final ValueNotifier<bool> aiSubtitleEnabled = ValueNotifier<bool>(true);

/// AI 语音识别上次使用的模型 ID（tiny / base / small）。
///
/// 打开 AI 字幕面板时自动恢复为上次选用的模型，避免每次都回到 tiny。
final ValueNotifier<String> aiAsrModelId = ValueNotifier<String>('tiny');

/// 从本地存储载入设置，应在 runApp 之前调用一次。
Future<void> loadAppSettings() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    fitWindowToVideo.value = prefs.getBool(_kFitWindowToVideo) ?? false;
    aiSubtitleEnabled.value = prefs.getBool(_kAiSubtitleEnabled) ?? true;
    final savedModel = prefs.getString(_kAiAsrModelId) ?? 'tiny';
    // 仅接受合法的模型 ID，防止脏数据导致面板找不到模型
    aiAsrModelId.value =
        const ['tiny', 'base', 'small'].contains(savedModel) ? savedModel : 'tiny';
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

/// 写入"AI 字幕"开关。
Future<void> setAiSubtitleEnabled(bool value) async {
  aiSubtitleEnabled.value = value;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAiSubtitleEnabled, value);
  } catch (_) {
    // 持久化失败不影响本次生效。
  }
}

/// 写入"AI 语音识别模型"选择，下次打开面板时恢复。
Future<void> setAiAsrModelId(String value) async {
  aiAsrModelId.value = value;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAiAsrModelId, value);
  } catch (_) {
    // 持久化失败不影响本次生效。
  }
}
