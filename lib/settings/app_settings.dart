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
const String _kAiAsrThreads = 'settings.aiAsrThreads';
const String _kAiAsrForceCpu = 'settings.aiAsrForceCpu';
const String _kModelDownloadSource = 'settings.modelDownloadSource';

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

/// AI 语音识别的 CPU 线程数；0 表示"自动"（按逻辑核心数推算）。
///
/// whisper.cpp 是纯 CPU 推理，线程数直接影响长视频的识别耗时：
/// 线程太少慢得离谱，线程过多收益递减（小模型甚至会变慢），所以给用户一个
/// 可调档位，默认交给自动策略。
final ValueNotifier<int> aiAsrThreadCount = ValueNotifier<int>(0);

/// 是否强制使用 CPU 做识别。
///
/// 用于"装了 GPU 引擎包但显卡驱动有问题"的场景：勾选后即使装了 CUDA/Vulkan
/// 引擎包也会以 `-ng` 启动，退回 CPU 推理，不用删掉引擎包。
final ValueNotifier<bool> aiAsrForceCpu = ValueNotifier<bool>(false);

/// Whisper 模型下载源。
///
/// 本应用面向国内用户，因此**默认就走国内镜像**：
/// - `auto`（默认）：先试国内镜像 hf-mirror，失败再回退 HuggingFace 官方源；
/// - `mirror`：只走国内镜像；
/// - `official`：只走 HuggingFace 官方源（海外用户或镜像异常时用）。
///
/// 三个源都连不上时，还可以用设置页的"导入模型"手动加载离线下载的 ggml 文件。
///
/// 之所以需要这个开关：Dart 的 HttpClient **不读取 Windows 系统代理**，
/// 即使本机挂了代理，应用内下载也是直连——国内直连 huggingface.co 会被拒。
final ValueNotifier<String> modelDownloadSource = ValueNotifier<String>('auto');

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
    aiAsrThreadCount.value = prefs.getInt(_kAiAsrThreads) ?? 0;
    aiAsrForceCpu.value = prefs.getBool(_kAiAsrForceCpu) ?? false;
    final source = prefs.getString(_kModelDownloadSource) ?? 'auto';
    modelDownloadSource.value =
        const ['mirror', 'official'].contains(source) ? source : 'auto';
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

/// 写入"AI 识别线程数"（0 = 自动）。
Future<void> setAiAsrThreadCount(int value) async {
  aiAsrThreadCount.value = value;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAiAsrThreads, value);
  } catch (_) {
    // 持久化失败不影响本次生效。
  }
}

/// 写入"强制使用 CPU 识别"开关。
Future<void> setAiAsrForceCpu(bool value) async {
  aiAsrForceCpu.value = value;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAiAsrForceCpu, value);
  } catch (_) {
    // 持久化失败不影响本次生效。
  }
}

/// 写入"模型下载源"（auto / mirror）。
Future<void> setModelDownloadSource(String value) async {
  modelDownloadSource.value = value;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModelDownloadSource, value);
  } catch (_) {
    // 持久化失败不影响本次生效。
  }
}
