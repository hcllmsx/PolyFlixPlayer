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
import '../utils/platform_utils.dart';
import 'app_store.dart';

// ------------------------------ 存储键（settings.json 里的字段名） ------------------------------
const String _kFitWindowToVideo = 'fitWindowToVideo';
const String _kAiSubtitleEnabled = 'aiSubtitleEnabled';
const String _kAiAsrModelId = 'aiAsrModelId';
const String _kAiAsrThreads = 'aiAsrThreads';
const String _kAiAsrForceCpu = 'aiAsrForceCpu';
const String _kResumePlayback = 'resumePlayback';
const String _kResumeMinVideoSeconds = 'resumeMinVideoSeconds';

// 翻译相关存储键
const String _kAiTranslationEnabled = 'aiTranslationEnabled';
const String _kAiTranslationTargetLang = 'aiTranslationTargetLang';
const String _kAiTranslationMode = 'aiTranslationMode';
const String _kAiTranslationProvider = 'aiTranslationProvider';
const String _kAiBaiduAppId = 'aiBaiduAppId';
const String _kAiBaiduSecretKey = 'aiBaiduSecretKey';
const String _kAiBaiduModelType = 'aiBaiduModelType';
const String _kAiAzureKey = 'aiAzureKey';
const String _kAiAzureRegion = 'aiAzureRegion';
const String _kAiAzureEndpoint = 'aiAzureEndpoint';
const String _kAiLocalEndpoint = 'aiLocalEndpoint';
const String _kAiTranslationProxyMode = 'aiTranslationProxyMode';
const String _kAiTranslationCustomProxy = 'aiTranslationCustomProxy';
const String _kAiTranslationVerifiedEngineKey = 'aiTranslationVerifiedEngineKey';

/// "短片不记进度"可选档位（秒）。0 = 不限制。
///
/// 放在这里而不是设置页里：读取时要用它校验存储值，避免脏数据落到界面上。
const List<int> resumeMinVideoOptions = [0, 30, 60, 120, 300];

/// 打开视频后是否让播放窗口自动适应视频画面比例（仅桌面端生效）。
///
/// 默认关闭：窗口大小随视频变化会打断用户的观看节奏，交给用户自己决定。
final ValueNotifier<bool> fitWindowToVideo = ValueNotifier<bool>(false);

/// AI 语音识别功能开关（原名 AI 字幕功能总开关）。
///
/// 开启后，在播放页可使用 ASR 语音识别生成字幕。
final ValueNotifier<bool> aiSubtitleEnabled = ValueNotifier<bool>(true);

/// AI 字幕翻译功能开关。
///
/// 开启后，支持将视频内置字幕或 AI 识别字幕翻译为目标语言。
final ValueNotifier<bool> aiTranslationEnabled = ValueNotifier<bool>(true);

/// 翻译目标语言（默认简体中文 zh-Hans）。
final ValueNotifier<String> aiTranslationTargetLang = ValueNotifier<String>('zh-Hans');

/// 翻译方式（online / local）。
final ValueNotifier<String> aiTranslationMode = ValueNotifier<String>('online');

/// 在线翻译服务提供商（baidu / azure）。
final ValueNotifier<String> aiTranslationProvider = ValueNotifier<String>('baidu');

/// 百度翻译 APP ID。
final ValueNotifier<String> aiBaiduAppId = ValueNotifier<String>('');

/// 百度翻译 Secret Key。
final ValueNotifier<String> aiBaiduSecretKey = ValueNotifier<String>('');

/// 百度翻译模型模式（llm: 大模型翻译，默认 | nmt: 通用机器翻译）。
final ValueNotifier<String> aiBaiduModelType = ValueNotifier<String>('llm');

/// 微软 Azure 翻译 Key。
final ValueNotifier<String> aiAzureKey = ValueNotifier<String>('');

/// 微软 Azure 翻译 Region（默认 eastasia）。
final ValueNotifier<String> aiAzureRegion = ValueNotifier<String>('eastasia');

/// 微软 Azure 翻译自定义终结点（默认空，走标准全局端点）。
final ValueNotifier<String> aiAzureEndpoint = ValueNotifier<String>('');

/// 在线翻译网络通道策略：'auto' (自适应/自动检测，默认) | 'direct' (直连) | 'custom' (指定代理)
final ValueNotifier<String> aiTranslationProxyMode = ValueNotifier<String>('auto');

/// 用户自定义代理地址（如 127.0.0.1:10808）
final ValueNotifier<String> aiTranslationCustomProxy = ValueNotifier<String>('');

/// 本地翻译端点地址预留。
final ValueNotifier<String> aiLocalEndpoint = ValueNotifier<String>('');

/// 最近一次测试通过并在用状态的翻译引擎配置特征键（指纹）。
final ValueNotifier<String> aiTranslationVerifiedEngineKey = ValueNotifier<String>('');

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
  aiAsrThreadCount.value =
      isDesktopPlatform ? store.getInt(_kAiAsrThreads, 0) : 0;
  aiAsrForceCpu.value = store.getBool(_kAiAsrForceCpu, false);
  resumePlaybackEnabled.value = store.getBool(_kResumePlayback, true);
  final resumeMin = store.getInt(_kResumeMinVideoSeconds, 60);
  // 只接受档位里存在的值，脏数据回退到 1 分钟
  resumeMinVideoSeconds.value = resumeMinVideoOptions.contains(resumeMin)
      ? resumeMin
      : 60;

  // 翻译设置读取
  aiTranslationEnabled.value = store.getBool(_kAiTranslationEnabled, true);
  aiTranslationTargetLang.value = store.getString(_kAiTranslationTargetLang) ?? 'zh-Hans';
  aiTranslationMode.value = store.getString(_kAiTranslationMode) ?? 'online';
  final savedProvider = store.getString(_kAiTranslationProvider) ?? 'baidu';
  aiTranslationProvider.value = (savedProvider == 'tencent') ? 'baidu' : savedProvider;
  aiBaiduAppId.value = store.getString(_kAiBaiduAppId) ?? '';
  aiBaiduSecretKey.value = store.getString(_kAiBaiduSecretKey) ?? '';
  aiBaiduModelType.value = store.getString(_kAiBaiduModelType) ?? 'llm';
  aiAzureKey.value = store.getString(_kAiAzureKey) ?? '';
  final savedRegion = store.getString(_kAiAzureRegion) ?? 'eastasia';
  aiAzureRegion.value = (savedRegion.isEmpty || savedRegion == 'global') ? 'eastasia' : savedRegion;
  aiAzureEndpoint.value = store.getString(_kAiAzureEndpoint) ?? '';
  aiLocalEndpoint.value = store.getString(_kAiLocalEndpoint) ?? '';
  aiTranslationProxyMode.value = store.getString(_kAiTranslationProxyMode) ?? 'auto';
  aiTranslationCustomProxy.value = store.getString(_kAiTranslationCustomProxy) ?? '';
  aiTranslationVerifiedEngineKey.value = store.getString(_kAiTranslationVerifiedEngineKey) ?? '';
}

/// 写入"窗口适应视频比例"开关。
Future<void> setFitWindowToVideo(bool value) async {
  fitWindowToVideo.value = value;
  await AppStore.instance.setBool(_kFitWindowToVideo, value);
}

/// 写入"AI 字幕识别"开关。
Future<void> setAiSubtitleEnabled(bool value) async {
  aiSubtitleEnabled.value = value;
  await AppStore.instance.setBool(_kAiSubtitleEnabled, value);
}

/// 写入"AI 字幕翻译"开关。
Future<void> setAiTranslationEnabled(bool value) async {
  aiTranslationEnabled.value = value;
  await AppStore.instance.setBool(_kAiTranslationEnabled, value);
}

/// 写入目标翻译语言。
Future<void> setAiTranslationTargetLang(String value) async {
  aiTranslationTargetLang.value = value;
  await AppStore.instance.setString(_kAiTranslationTargetLang, value);
}

/// 写入翻译方式（online / local）。
Future<void> setAiTranslationMode(String value) async {
  aiTranslationMode.value = value;
  await AppStore.instance.setString(_kAiTranslationMode, value);
}

/// 写入在线翻译服务商（baidu / azure）。
Future<void> setAiTranslationProvider(String value) async {
  aiTranslationProvider.value = value;
  await AppStore.instance.setString(_kAiTranslationProvider, value);
}

/// 写入百度翻译凭据。
Future<void> setAiBaiduCredentials({required String appId, required String secretKey}) async {
  aiBaiduAppId.value = appId;
  aiBaiduSecretKey.value = secretKey;
  await AppStore.instance.setString(_kAiBaiduAppId, appId);
  await AppStore.instance.setString(_kAiBaiduSecretKey, secretKey);
}

/// 写入百度翻译模型模式（llm / nmt）。
Future<void> setAiBaiduModelType(String value) async {
  aiBaiduModelType.value = value;
  await AppStore.instance.setString(_kAiBaiduModelType, value);
}

/// 写入微软 Azure 翻译凭据。
Future<void> setAiAzureCredentials({
  required String key,
  String region = 'eastasia',
  String endpoint = '',
}) async {
  final cleanRegion = region.trim().isEmpty ? 'eastasia' : region.trim();
  aiAzureKey.value = key;
  aiAzureRegion.value = cleanRegion;
  aiAzureEndpoint.value = endpoint;
  await AppStore.instance.setString(_kAiAzureKey, key);
  await AppStore.instance.setString(_kAiAzureRegion, cleanRegion);
  await AppStore.instance.setString(_kAiAzureEndpoint, endpoint);
}

/// 写入本地端点地址。
Future<void> setAiLocalEndpoint(String value) async {
  aiLocalEndpoint.value = value;
  await AppStore.instance.setString(_kAiLocalEndpoint, value);
}

/// 写入在线翻译网络通道策略及自定义代理。
Future<void> setAiTranslationProxy({
  required String mode,
  String customProxy = '',
}) async {
  aiTranslationProxyMode.value = mode;
  aiTranslationCustomProxy.value = customProxy;
  await AppStore.instance.setString(_kAiTranslationProxyMode, mode);
  await AppStore.instance.setString(_kAiTranslationCustomProxy, customProxy);
}

/// 写入当前已测试通过并在用状态的翻译引擎配置指纹。
Future<void> setAiTranslationVerifiedEngineKey(String value) async {
  aiTranslationVerifiedEngineKey.value = value;
  await AppStore.instance.setString(_kAiTranslationVerifiedEngineKey, value);
}

/// 写入"AI 语音识别模型"选择，下次打开面板时恢复。
Future<void> setAiAsrModelId(String value) async {
  aiAsrModelId.value = value;
  await AppStore.instance.setString(_kAiAsrModelId, value);
}

/// 写入"AI 识别线程数"（0 = 自动）。移动端静默锁定为 0（自动）不可修改。
Future<void> setAiAsrThreadCount(int value) async {
  if (!isDesktopPlatform) {
    aiAsrThreadCount.value = 0;
    return;
  }
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

