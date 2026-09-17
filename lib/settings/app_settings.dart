/// 应用设置：全局可监听的配置项 + 本地持久化。
///
/// 用顶层 ValueNotifier 而不是引入状态管理库：设置项很少，设置页写、
/// 播放页读，两边监听同一个值即可，改动面最小。
///
/// 持久化走 [AppStore]（`%LOCALAPPDATA%\PolyFlixPlayer\settings.json`），
/// 不再使用 shared_preferences —— 后者的落盘路径由 exe 的公司名/产品名决定，
/// 一旦改名用户设置就会丢。
library;

import 'package:flutter/foundation.dart';

import '../subtitle/model_manager.dart';
import 'app_store.dart';

// ------------------------------ 存储键（settings.json 里的字段名） ------------------------------
const String _kFitWindowToVideo = 'fitWindowToVideo';
const String _kAiSubtitleEnabled = 'aiSubtitleEnabled';
const String _kAiAsrModelId = 'aiAsrModelId';
const String _kAiAsrThreads = 'aiAsrThreads';
const String _kAiAsrForceCpu = 'aiAsrForceCpu';
const String _kResumePlayback = 'resumePlayback';
const String _kResumeMinVideoSeconds = 'resumeMinVideoSeconds';

/// "短片不记进度"可选档位（秒）。0 = 不限制。
///
/// 放在这里而不是设置页里：读取时要用它校验存储值，避免脏数据落到界面上。
const List<int> resumeMinVideoOptions = [0, 30, 60, 120, 300];

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

/// 是否记录播放进度（"续播"）。
///
/// 开启：退出播放时记住看到哪儿，下次打开同一个视频从那里继续，播放列表
/// 卡片上也会显示上次看到的位置（▶ 12:34）。
/// 关闭：不写也不读进度记录（已有记录保留着，重新打开开关即可恢复）。
final ValueNotifier<bool> resumePlaybackEnabled = ValueNotifier<bool>(true);

/// "短片不记进度"的阈值（秒）；0 表示不限制（所有视频都记）。
///
/// 短片从头再看一遍也就分把钟，记进度反而添乱；但"多短算短"因人而异，
/// 所以给几档让用户自己定（见 [resumeMinVideoOptions]）。
final ValueNotifier<int> resumeMinVideoSeconds = ValueNotifier<int>(60);

/// 从本地存储载入设置，应在 runApp 之前调用一次。
Future<void> loadAppSettings() async {
  final store = AppStore.instance;
  await store.load();
  fitWindowToVideo.value = store.getBool(_kFitWindowToVideo, false);
  aiSubtitleEnabled.value = store.getBool(_kAiSubtitleEnabled, true);
  final savedModel = store.getString(_kAiAsrModelId) ?? '';
  // 只接受模型清单里真实存在的 ID：清单有 40 多个型号（tiny~large-v3 系列），
  // 写死几个会让用户记住的大模型选择失效，脏数据才回退到 tiny。
  aiAsrModelId.value = availableModels.any((m) => m.id == savedModel)
      ? savedModel
      : 'tiny';
  aiAsrThreadCount.value = store.getInt(_kAiAsrThreads, 0);
  aiAsrForceCpu.value = store.getBool(_kAiAsrForceCpu, false);
  resumePlaybackEnabled.value = store.getBool(_kResumePlayback, true);
  final resumeMin = store.getInt(_kResumeMinVideoSeconds, 60);
  // 只接受档位里存在的值，脏数据回退到 1 分钟
  resumeMinVideoSeconds.value = resumeMinVideoOptions.contains(resumeMin)
      ? resumeMin
      : 60;
}

/// 写入"窗口适应视频比例"开关。
Future<void> setFitWindowToVideo(bool value) async {
  fitWindowToVideo.value = value;
  await AppStore.instance.setBool(_kFitWindowToVideo, value);
}

/// 写入"AI 字幕"开关。
Future<void> setAiSubtitleEnabled(bool value) async {
  aiSubtitleEnabled.value = value;
  await AppStore.instance.setBool(_kAiSubtitleEnabled, value);
}

/// 写入"AI 语音识别模型"选择，下次打开面板时恢复。
Future<void> setAiAsrModelId(String value) async {
  aiAsrModelId.value = value;
  await AppStore.instance.setString(_kAiAsrModelId, value);
}

/// 写入"AI 识别线程数"（0 = 自动）。
Future<void> setAiAsrThreadCount(int value) async {
  aiAsrThreadCount.value = value;
  await AppStore.instance.setInt(_kAiAsrThreads, value);
}

/// 写入"强制使用 CPU 识别"开关。
Future<void> setAiAsrForceCpu(bool value) async {
  aiAsrForceCpu.value = value;
  await AppStore.instance.setBool(_kAiAsrForceCpu, value);
}

/// 写入"记录播放进度（续播）"开关。
Future<void> setResumePlaybackEnabled(bool value) async {
  resumePlaybackEnabled.value = value;
  await AppStore.instance.setBool(_kResumePlayback, value);
}

/// 写入"短片不记进度"的阈值（秒，0 = 不限制）。
Future<void> setResumeMinVideoSeconds(int value) async {
  resumeMinVideoSeconds.value = value;
  await AppStore.instance.setInt(_kResumeMinVideoSeconds, value);
}
