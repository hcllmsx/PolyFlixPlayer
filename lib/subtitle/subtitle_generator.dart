/// AI 字幕生成器：协调音频提取 → Whisper ASR → 字幕显示的流水线。
///
/// 核心职责：
/// 1. 从视频文件中提取音频并转为 16kHz mono WAV（whisper.cpp 输入格式）
/// 2. 调用 whisper_ggml 进行语音识别
/// 3. 将识别结果转为带时间戳的字幕条目
/// 4. 管理字幕缓存（按视频文件 hash 索引，避免重复识别）
///
/// 与流式播放的关系：音频提取不依赖完整文件。对于 PFLX 流式播放源，
/// 可以通过 PflxStreamServer 的 HTTP URL 访问音频数据。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import '../settings/app_settings.dart';
import '../utils/native_file_helper.dart';
import 'engine_pack.dart';
import 'model_manager.dart';
import 'whisper_server.dart';

/// 单条字幕。
class SubtitleEntry {
  const SubtitleEntry({
    required this.start,
    required this.end,
    required this.text,
    this.translatedText,
  });

  /// 字幕开始时间。
  final Duration start;

  /// 字幕结束时间。
  final Duration end;

  /// 原始识别文本。
  final String text;

  /// 翻译后的文本（第二阶段使用）。
  final String? translatedText;

  Map<String, dynamic> toJson() => {
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
        'text': text,
        if (translatedText != null) 'translatedText': translatedText,
      };

  factory SubtitleEntry.fromJson(Map<String, dynamic> json) => SubtitleEntry(
        start: Duration(milliseconds: (json['startMs'] as num?)?.toInt() ?? 0),
        end: Duration(milliseconds: (json['endMs'] as num?)?.toInt() ?? 0),
        text: json['text'] as String? ?? '',
        translatedText: json['translatedText'] as String?,
      );

  @override
  String toString() => '[$start -> $end] $text';
}

/// ASR 处理状态。
enum AsrState {
  /// 空闲，未运行。
  idle,

  /// 正在准备（提取音频、加载模型等）。
  preparing,

  /// 正在识别。
  processing,

  /// 识别完成。
  completed,

  /// 发生错误。
  error,
}

/// ASR 处理进度信息。
class AsrProgress {
  const AsrProgress({
    required this.state,
    this.percent = 0,
    this.message,
  });

  final AsrState state;
  final int percent;
  final String? message;
}

/// 字幕生成器。
///
/// 使用 whisper_ggml 包进行语音识别，输出带时间戳的字幕条目。
class SubtitleGenerator {
  SubtitleGenerator._();
  static final SubtitleGenerator instance = SubtitleGenerator._();

  /// 当前状态流。
  final StreamController<AsrProgress> _progressController =
      StreamController<AsrProgress>.broadcast();
  Stream<AsrProgress> get progressStream => _progressController.stream;

  /// 当前已生成的字幕条目（全量）。
  final List<SubtitleEntry> _entries = [];
  List<SubtitleEntry> get entries => List.unmodifiable(_entries);

  /// 当前这批字幕属于哪个视频。
  ///
  /// 本类是全局单例：切到另一个视频后，里面可能还留着上一个视频的字幕，
  /// 面板与叠加层必须据此判断归属，否则会出现"识别界面串台/显示别的视频字幕"。
  String? _entriesVideoPath;
  String? get entriesVideoPath => _entriesVideoPath;

  /// 这批字幕是否属于指定视频。
  bool holdsEntriesFor(String videoPath) =>
      _entries.isNotEmpty && _entriesVideoPath == videoPath;

  /// 当前状态。
  AsrState _state = AsrState.idle;
  AsrState get state => _state;

  /// 是否正在运行。
  bool get isRunning =>
      _state == AsrState.preparing || _state == AsrState.processing;

  /// 取消标志。
  bool _cancelled = false;

  /// 底层模型是否已被加载/正在使用。
  bool _isModelInUse = false;

  /// 对视频文件执行完整的 ASR 识别。
  ///
  /// [videoPath] 视频文件路径（支持本地文件和 PFLX 流式 URL）。
  /// [modelId] 使用的模型 ID（默认 'tiny'）。
  /// [language] 语言代码（'auto' 自动检测，'en' 英语，'zh' 中文等）。
  ///
  /// 识别结果通过 [entries] 和 [progressStream] 获取。
  Future<List<SubtitleEntry>> transcribeVideo({
    required String videoPath,
    String modelId = 'tiny',
    String language = 'auto',
  }) async {
    if (isRunning) {
      throw StateError('ASR 正在运行中，请先停止当前任务');
    }

    _cancelled = false;
    _entries.clear();
    _entriesVideoPath = videoPath;
    _updateState(AsrState.preparing, message: '正在准备…');

    try {
      // 1. 检查模型是否已导入
      final modelPath = await ModelManager.instance.getModelPath(modelId);
      if (modelPath == null) {
        _updateState(
            AsrState.error, message: '模型未导入，请在设置页「浏览全部模型」里对照文件名导入');
        return [];
      }

      if (_cancelled) return [];

      // 2. 提取音频为 WAV 文件（上报进度，避免长时间黑盒等待）
      _updateState(AsrState.preparing, message: '正在提取音频…');
      final wavPath = await _extractAudioToWav(
        videoPath,
        onProgress: (fraction, _, _) {
          final overall = fraction * _kExtractProgressShare;
          _updateState(
            AsrState.preparing,
            percent: (overall * 100).toInt(),
            message: '正在提取音频… ${(fraction * 100).toStringAsFixed(0)}%',
          );
        },
      );
      if (wavPath == null) {
        _updateState(AsrState.error, message: '音频提取失败');
        return [];
      }

      if (_cancelled) {
        _cleanupTempFile(wavPath);
        return [];
      }

      // 3. 执行 ASR 识别（引擎包优先，回落到内置 FFI 插件）
      _updateState(AsrState.processing, message: '正在分析语音并生成字幕…');
      _isModelInUse = true;

      final langCode = _resolveLanguage(modelId, language);
      // 本次识别统一用同一个线程数，避免识别途中改设置造成前后不一致
      final asrThreads = resolveAsrThreads();

      final recognized = await _recognizeWavFile(
        wavPath: wavPath,
        modelPath: modelPath,
        language: langCode,
        threads: asrThreads,
      );
      _entries.addAll(recognized);

      // 4. 清理临时 WAV 文件
      _cleanupTempFile(wavPath);

      if (_cancelled) return [];

      if (_entries.isNotEmpty) {
        _updateState(AsrState.completed, message: '识别完成 (共 ${_entries.length} 条原语言字幕)');
      } else {
        _updateState(AsrState.completed, message: '未检测到有效语音');
      }
      return List.unmodifiable(_entries);
    } catch (e) {
      _updateState(AsrState.error, message: '识别失败：$e');
      return [];
    }
  }

  /// 上一次识别实际使用的引擎描述（供界面展示，如 "CUDA 引擎包 · RTX 4080"）。
  static String? lastEngineLabel;

  /// 音频提取阶段在整体进度里占的比例，剩下 92% 留给识别。
  ///
  /// 提取（1 小时 2160p 影片通常 20~60 秒）本身也会占掉可观时间，
  /// 所以给它一段独立进度，让用户看到"确实在动"，而不是长时间黑盒等待。
  static const double _kExtractProgressShare = 0.08;

  /// 把"识别阶段"的 0~1 进度映射到整体进度的后 92%。
  static double _remapRecognitionPercent(double p) =>
      _kExtractProgressShare + (1 - _kExtractProgressShare) * p.clamp(0.0, 1.0);

  /// 解析实际要传给引擎的识别语言。
  ///
  /// 英语专用模型（`.en`）只能处理英语：用户即使设成 auto 或其它语言，
  /// 也必须按英语处理，否则输出会是乱码式的英文。
  static String _resolveLanguage(String modelId, String language) {
    if (modelId.toLowerCase().contains('.en')) return 'en';
    return language.trim().isEmpty ? 'auto' : language;
  }

  /// 解析本次识别使用的 CPU 线程数。
  ///
  /// 当前上游插件（whisper_ggml 2.6.0）是纯 CPU 构建，线程数是唯一有效的
  /// 速度杠杆：设置里为 0 时走自动策略 —— 取逻辑核心数的一半并夹在 [4, 12]。
  /// 实测（310 秒音频 / small 模型）：4 线程 38.8s → 8 线程 23.4s → 12 线程
  /// 22.3s，再往上基本没收益（tiny 模型 16 线程反而变慢）。
  static int resolveAsrThreads() {
    final configured = aiAsrThreadCount.value;
    if (configured > 0) return configured;
    return (Platform.numberOfProcessors ~/ 2).clamp(4, 12);
  }

  /// 识别一个 WAV 文件，返回原始分段（时间轴按 [offsetMs] 平移）。
  ///
  /// 两条路径：
  ///  1. **引擎包**（用户把 whisper.cpp 官方预编译包放进引擎目录）：
  ///     走 `whisper-server.exe`，模型常驻内存，CUDA/Vulkan 包可自动用上 GPU；
  ///  2. **内置插件**（whisper_ggml，纯 CPU FFI）：引擎包缺失或启动失败时兜底，
  ///     保证没装引擎包的用户也能正常识别。
  Future<List<SubtitleEntry>> _recognizeWavFile({
    required String wavPath,
    required String modelPath,
    required String language,
    required int threads,
    int offsetMs = 0,
  }) async {
    // ---- 路径 1：引擎包（可 GPU 加速） ----
    try {
      final pack = await EnginePackManager.instance.resolvePreferred(
        allowGpu: !aiAsrForceCpu.value,
      );
      if (pack != null) {
        final session = await WhisperServerSession.acquire(
          pack: pack,
          modelPath: modelPath,
          threads: threads,
          forceCpu: aiAsrForceCpu.value,
        );
        if (session != null) {
          lastEngineLabel = '${pack.displayName} · ${session.resolvedDeviceName}';
          final segments = await session.transcribeWavFile(wavPath, language: language);
          return [
            for (final s in segments)
              SubtitleEntry(
                start: Duration(milliseconds: offsetMs + s.startMs),
                end: Duration(milliseconds: offsetMs + s.endMs),
                text: s.text,
              ),
          ];
        }
      }
    } catch (_) {
      // 引擎包异常（进程崩溃、端口占用、DLL 缺失等）不致命，继续回落内置插件
    }

    // ---- 路径 2：内置插件（FFI / 纯 CPU） ----
    lastEngineLabel = '内置 CPU 引擎';
    final String dllName;
    if (Platform.isAndroid) {
      dllName = 'libwhisper.so';
    } else if (Platform.isWindows) {
      dllName = 'whisper_ggml.dll';
    } else if (Platform.isLinux) {
      dllName = 'libwhisper_ggml.so';
    } else {
      dllName = '';
    }

    final rawJson = await Isolate.run(() => _safeNativeTranscribe(
          dllName: dllName,
          modelPath: modelPath,
          wavPath: wavPath,
          language: language,
          threads: threads,
        ));

    final resMap = jsonDecode(rawJson) as Map<String, dynamic>;
    if (resMap['@type'] == 'error') {
      throw Exception(resMap['message'] as String? ?? '未知错误');
    }
    return _parsePluginSegments(resMap, offsetMs);
  }

  /// 解析内置插件返回的 JSON 分段。
  ///
  /// 注意：whisper.cpp 的时间戳单位是 10ms（厘秒），必须乘以 10 才是毫秒。
  static List<SubtitleEntry> _parsePluginSegments(
    Map<String, dynamic> resMap,
    int offsetMs,
  ) {
    final result = <SubtitleEntry>[];
    final segments = resMap['segments'] as List<dynamic>?;

    if (segments != null && segments.isNotEmpty) {
      for (final item in segments) {
        final seg = item as Map<String, dynamic>;
        final fromMs = ((seg['from_ts'] as num?)?.toInt() ?? 0) * 10;
        final toMs = ((seg['to_ts'] as num?)?.toInt() ?? 0) * 10;
        final text = (seg['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) continue;
        result.add(SubtitleEntry(
          start: Duration(milliseconds: offsetMs + fromMs),
          end: Duration(milliseconds: offsetMs + toMs),
          text: text,
        ));
      }
    } else {
      // 没有分段时间戳时，如果有全文，整体作为一条字幕
      final text = (resMap['text'] as String?)?.trim() ?? '';
      if (text.isNotEmpty) {
        result.add(SubtitleEntry(
          start: Duration(milliseconds: offsetMs),
          end: const Duration(hours: 99),
          text: text,
        ));
      }
    }
    return result;
  }

  /// 在单独 Isolate 中执行的纯原生 FFI 转录。
  ///
  /// 绝对不要在 Windows 上对 C++ 返回的指针调用 malloc.free()，
  /// 否则将触发 0xc0000374 STATUS_HEAP_CORRUPTION 导致进程直接崩溃。
  static String _safeNativeTranscribe({
    required String dllName,
    required String modelPath,
    required String wavPath,
    required String language,
    required int threads,
  }) {
    DynamicLibrary lib;
    if (dllName.isNotEmpty) {
      try {
        lib = DynamicLibrary.open(dllName);
      } catch (_) {
        if (Platform.isAndroid) {
          try {
            lib = DynamicLibrary.open('libwhisper_ggml.so');
          } catch (_) {
            lib = DynamicLibrary.process();
          }
        } else {
          lib = DynamicLibrary.process();
        }
      }
    } else {
      lib = DynamicLibrary.process();
    }

    final reqFunc = lib.lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)>('request');

    final reqBody = {
      '@type': 'getTextFromWavFile',
      'model': modelPath,
      'audio': wavPath,
      'is_translate': false,
      'threads': threads,
      'is_verbose': false,
      'language': language,
      'is_special_tokens': false,
      'is_no_timestamps': false,
      'n_processors': 1,
      'split_on_word': false,
      'no_fallback': false,
      'is_realtime': false,
      'diarize': false,
      'speed_up': false,
      'no_context': false,
      'suppress_non_speech_tokens': true,
      'keep_model_loaded': false,
    };

    final inPtr = jsonEncode(reqBody).toNativeUtf8();
    try {
      final outPtr = reqFunc(inPtr);
      final outStr = outPtr.toDartString();
      // 在 Windows 上绝不调用 malloc.free(outPtr)！
      return outStr;
    } finally {
      malloc.free(inPtr);
    }
  }

  /// 停止当前 ASR 任务。
  void cancel() {
    _cancelled = true;
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        FFmpegKit.cancel();
      } catch (_) {}
    }
    _updateState(AsrState.idle, message: '已取消');
  }

  /// 释放 Whisper 模型内存。
  ///
  /// 在退出播放页或不再需要 ASR 时调用。
  Future<void> releaseModel() async {
    if (!_isModelInUse) return;
    _isModelInUse = false;
  }

  /// 清除当前字幕数据。
  void clear() {
    _entries.clear();
    _entriesVideoPath = null;
    _state = AsrState.idle;
  }

  /// 批量设置字幕条目（从缓存恢复或从后台任务同步）。
  ///
  /// [videoPath] 用于记录这批字幕属于哪个视频，供面板/叠加层判断归属。
  /// [markCompleted] 为 true 时把状态一并置为"识别完成"：从本地缓存恢复的
  /// 字幕在控制面板里应显示成已完成（否则面板停在"就绪"、预览区也展不开），
  /// 而这批字幕并不需要真的再跑一次识别。
  void setEntries(
    List<SubtitleEntry> list, {String? videoPath, bool markCompleted = false}) {
    _entries.clear();
    _entries.addAll(list);
    _entriesVideoPath = videoPath;
    if (markCompleted && list.isNotEmpty) {
      _state = AsrState.completed;
    }
  }

  /// 根据当前播放位置获取应显示的字幕。
  SubtitleEntry? getEntryAt(Duration position) {
    for (final entry in _entries) {
      if (position >= entry.start && position <= entry.end) {
        return entry;
      }
    }
    return null;
  }

  /// 分段切片识别（支持长视频进度透明化与随时优雅中断）。
  Future<List<SubtitleEntry>> transcribeVideoChunked({
    required String videoPath,
    required String modelId,
    String language = 'auto',
    void Function(AsrState state, Duration processed, Duration total, double percent, String? message)? onProgress,
    void Function(List<SubtitleEntry> newEntries)? onNewEntries,
    bool Function()? isCancelled,
  }) async {
    _cancelled = false;
    // 动态归属检测：只有当单例当前确属本次识别的视频时，才允许向单例写入条目或广播状态。
    // 识别流程通常耗时数十秒至数分钟，期间用户随时会切换并播放另一个视频，
    // 因此绝不能用初始布尔快照，必须在每个阶段实时求值。
    bool isCurrentVideo() => _entriesVideoPath == videoPath;

    if (_entriesVideoPath == null || isCurrentVideo()) {
      _entries.clear();
      _entriesVideoPath = videoPath;
      _updateState(AsrState.preparing, message: '正在准备模型…');
    }
    onProgress?.call(AsrState.preparing, Duration.zero, Duration.zero, 0.0, '正在准备模型…');

    final modelPath = await ModelManager.instance.getModelPath(modelId);
    if (modelPath == null) {
      if (isCurrentVideo()) {
        _updateState(AsrState.error, message: '模型未就绪');
      }
      onProgress?.call(AsrState.error, Duration.zero, Duration.zero, 0.0, '模型未就绪');
      throw StateError('模型未就绪，请先导入或下载 Whisper 模型');
    }

    if (isCancelled?.call() == true || _cancelled) return [];

    if (isCurrentVideo()) {
      _updateState(AsrState.preparing, message: '正在提取音频…');
    }
    onProgress?.call(
        AsrState.preparing, Duration.zero, Duration.zero, 0.0, '正在提取音频…');
    final wavPath = await _extractAudioToWav(
      videoPath,
      isCancelled: isCancelled,
      onProgress: (fraction, processed, total) {
        final overall = fraction * _kExtractProgressShare;
        final msg = '正在提取音频… ${(fraction * 100).toStringAsFixed(0)}%';
        if (isCurrentVideo()) {
          _updateState(
            AsrState.preparing,
            percent: (overall * 100).toInt(),
            message: msg,
          );
        }
        onProgress?.call(AsrState.preparing, processed, total, overall, msg);
      },
    );
    if (wavPath == null) {
      if (isCancelled?.call() == true || _cancelled) {
        if (isCurrentVideo()) {
          _updateState(AsrState.idle, message: '已取消');
        }
        return [];
      }
      if (isCurrentVideo()) {
        _updateState(AsrState.error, message: '音频提取失败');
      }
      onProgress?.call(AsrState.error, Duration.zero, Duration.zero, 0.0, '音频提取失败');
      throw StateError('音频提取失败，请检查视频是否有有效音轨或格式');
    }

    final wavFile = File(wavPath);
    final wavSize = await wavFile.length();
    // 16kHz 16bit 单声道 PCM：32000 字节/秒
    const bytesPerSecond = 32000;
    final pcmDataLength = wavSize > 44 ? wavSize - 44 : 0;
    final totalSeconds = pcmDataLength ~/ bytesPerSecond;
    final totalDuration = Duration(seconds: totalSeconds);

    if (totalSeconds <= 0) {
      _cleanupTempFile(wavPath);
      if (isCurrentVideo()) {
        _updateState(AsrState.error, message: '音频数据为空');
      }
      throw StateError('音频数据为空');
    }

    if (isCurrentVideo()) {
      _updateState(AsrState.processing, message: '开始分析音频并生成字幕…');
    }
    _isModelInUse = true;

    // 分析音频能量（静音区间与人声发音点），用于消除前导静音漂移和长句按停顿智能拆分
    final energyProfile = await AudioEnergyProfile.fromWavFile(wavPath);

    final langCode = _resolveLanguage(modelId, language);
    // 本次识别统一用同一个线程数，避免识别途中改设置造成前后不一致
    final asrThreads = resolveAsrThreads();

    // 如果音频较短（<= 120 秒），无需切片，直接整体转录！
    // 这样短视频保留全局上下文与最准确的时间戳，不受切片边界干扰。
    if (totalSeconds <= 120) {
      final processingBase = _kExtractProgressShare;
      if (isCurrentVideo()) {
        _updateState(
          AsrState.processing,
          percent: (processingBase * 100).toInt(),
          message: '正在分析完整音频…',
        );
      }
      onProgress?.call(AsrState.processing, Duration.zero, totalDuration,
          processingBase, '正在分析完整音频…');

      final rawEntries = await _recognizeWavFile(
        wavPath: wavPath,
        modelPath: modelPath,
        language: langCode,
        threads: asrThreads,
      );

      if (isCancelled?.call() == true || _cancelled) {
        if (isCurrentVideo()) {
          _updateState(AsrState.idle, message: '已取消');
        }
        onProgress?.call(AsrState.idle, Duration.zero, totalDuration, 0.0, '已取消');
        return [];
      }

      final normalized = normalizeEntries(rawEntries, energyProfile: energyProfile);
      if (isCurrentVideo()) {
        _entries.clear();
        _entries.addAll(normalized);
      }
      onNewEntries?.call(normalized);

      final finalMsg = normalized.isNotEmpty
          ? '识别完成 (共 ${normalized.length} 条字幕)'
          : '未检测到有效语音';
      if (isCurrentVideo()) {
        _updateState(AsrState.completed, percent: 100, message: finalMsg);
      }
      onProgress?.call(AsrState.completed, totalDuration, totalDuration, 1.0, finalMsg);
      return List.unmodifiable(normalized);
    }

    // 长视频（> 120 秒）：分片时长 60 秒（60 * 32000 = 1,920,000 字节）
    const chunkSeconds = 60;
    const chunkBytes = chunkSeconds * bytesPerSecond;
    final chunkCount = (pcmDataLength / chunkBytes).ceil();

    final audioDir = NativeFileHelper.desktopCacheAudioDir();
    final tempChunkPath = '${audioDir.path}${Platform.pathSeparator}chunk_${DateTime.now().millisecondsSinceEpoch}.wav';

    final rawAccumulated = <SubtitleEntry>[];
    RandomAccessFile? raf;
    try {
      raf = await wavFile.open(mode: FileMode.read);
      for (int i = 0; i < chunkCount; i++) {
        if (isCancelled?.call() == true || _cancelled) {
          if (isCurrentVideo()) {
            _updateState(AsrState.idle, message: '已取消');
          }
          break;
        }

        final chunkOffset = 44 + i * chunkBytes;
        final currentChunkBytes = (chunkOffset + chunkBytes <= wavSize)
            ? chunkBytes
            : (wavSize - chunkOffset);

        if (currentChunkBytes <= 0) break;

        final currentProcessedSec = i * chunkSeconds;
        // 识别阶段占整体的后 92%，前面留给音频提取
        final percent = _remapRecognitionPercent(
          (currentProcessedSec / totalSeconds).clamp(0.0, 0.99),
        );
        final progressMsg = '已识别 ${_formatDuration(Duration(seconds: currentProcessedSec))} / ${_formatDuration(totalDuration)} (${(percent * 100).toStringAsFixed(1)}%) · 片段 ${i + 1}/$chunkCount';

        if (isCurrentVideo()) {
          _updateState(AsrState.processing, percent: (percent * 100).toInt(), message: progressMsg);
        }
        onProgress?.call(AsrState.processing, Duration(seconds: currentProcessedSec), totalDuration, percent, progressMsg);

        // 读取 PCM 片段并构造 WAV 文件
        await raf.setPosition(chunkOffset);
        final pcmBuffer = await raf.read(currentChunkBytes);
        final header = _createWavHeader(currentChunkBytes);

        final chunkFile = File(tempChunkPath);
        final sink = chunkFile.openWrite();
        sink.add(header);
        sink.add(pcmBuffer);
        await sink.flush();
        await sink.close();

        // 识别该分片（引擎包优先，回落内置插件），时间轴按分片偏移平移。
        // 单个分片失败（显存不足、进程被杀等）不应中断整段识别，跳过继续。
        List<SubtitleEntry> chunkEntries;
        try {
          chunkEntries = await _recognizeWavFile(
            wavPath: tempChunkPath,
            modelPath: modelPath,
            language: langCode,
            threads: asrThreads,
            offsetMs: i * chunkSeconds * 1000,
          );
        } catch (_) {
          _cleanupTempFile(tempChunkPath);
          continue;
        }

        _cleanupTempFile(tempChunkPath);

        if (chunkEntries.isNotEmpty) {
          final normalizedChunk = normalizeEntries(chunkEntries);
          rawAccumulated.addAll(chunkEntries);
          if (isCurrentVideo()) {
            _entries.addAll(normalizedChunk);
          }
          onNewEntries?.call(normalizedChunk);
        }
      }
    } finally {
      await raf?.close();
      _cleanupTempFile(tempChunkPath);
    }

    if (isCancelled?.call() == true || _cancelled) {
      if (isCurrentVideo()) {
        _updateState(AsrState.idle, message: '已取消');
      }
      onProgress?.call(AsrState.idle, Duration.zero, totalDuration, 0.0, '已取消');
      return [];
    }

    // 全量整体再次执行一次平滑校准，确保分段接缝处的时长自然过渡与静音校准
    final fullyNormalized = normalizeEntries(rawAccumulated, energyProfile: energyProfile);
    if (isCurrentVideo()) {
      _entries.clear();
      _entries.addAll(fullyNormalized);
      final finalMsg = _entries.isNotEmpty
          ? '识别完成 (共 ${_entries.length} 条字幕)'
          : '未检测到有效语音';
      _updateState(AsrState.completed, percent: 100, message: finalMsg);
    }

    final finalMsg = fullyNormalized.isNotEmpty
        ? '识别完成 (共 ${fullyNormalized.length} 条字幕)'
        : '未检测到有效语音';
    onProgress?.call(AsrState.completed, totalDuration, totalDuration, 1.0, finalMsg);

    return List.unmodifiable(fullyNormalized);
  }

  /// 对字幕条目的显示区间进行智能优化：
  /// 对字幕条目的显示区间进行智能优化：
  /// 1. 若提供 [energyProfile]，自动校准开头发声时间（消除前导数秒静音期的提前弹出问题）；
  /// 2. 识别包含逗号/分号且存在静音停顿的长复合句，智能拆分为独立的短字幕段；
  /// 3. 过滤 [Music]、(music)、♪ 这类无意义音效占位符；
  /// 4. 依据汉字数/英文词数计算合理的阅读停留时长，说话完毕后适时自动淡出消失，保留真实空白。
  static List<SubtitleEntry> normalizeEntries(
    List<SubtitleEntry> rawList, {
    AudioEnergyProfile? energyProfile,
  }) {
    if (rawList.isEmpty) return [];

    // 第零步：先把被引擎在句中截断的相邻原始分段合并回一句
    final sourceList = _mergeRawContinuations(rawList);

    // 第一步：基于真实音频能量校准发音起点，并将长复合句智能拆分为多短语
    final preprocessed = <SubtitleEntry>[];

    for (int i = 0; i < sourceList.length; i++) {
      final cur = sourceList[i];
      // 先剥掉 "MUSIC" 之类的非语音标签（模型常把它和台词粘成一段）
      final text = _stripNonSpeechLabels(cur.text);
      if (text.isEmpty) continue;

      int sMs = cur.start.inMilliseconds;
      int eMs = cur.end.inMilliseconds;

      // 1. 首句/前序校准：如果开始于静音期，扫描真实发音时刻
      if (energyProfile != null) {
        final realStart = energyProfile.findFirstSpeech(sMs, eMs);
        if (realStart > sMs && (realStart - sMs) >= 800) {
          sMs = realStart;
        }
      }

      // 2. 并列复合句智能拆分（如 "Listen to music, send a message, turn on the lights..."）
      //
      //    关键约束：只有当"实际停顿出来的发声块数量"能对上"逗号分句数量"时才拆。
      //    否则说明这些逗号只是同一句话内部的自然停顿（如
      //    "Okay, Whisper, start listening for commands."），必须整句保留：
      //      · 撕碎会让引导词单独闪半秒再留白，观感断裂；
      //      · 旧版本用 min(分句数, 块数) 截取，块数不足时会静默丢弃后半句，造成丢字。
      //    中文还要额外按句末标点（。！？）切分，否则一长段中文会整条显示。
      final clauses = text
          .split(RegExp(r'[,;，；。！？]\s*'))
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList();

      if (clauses.length >= 2 && (eMs - sMs) >= 4000 && energyProfile != null) {
        // whisper 的 to_ts 会一直延伸到下一句的起点，导致搜索窗口里混进下一句起音的残块。
        // 因此把窗口右边界收敛到"下一句真实发音点"之前，保证只统计本句自己的语音块。
        int searchEndMs = eMs;
        if (i + 1 < sourceList.length) {
          final next = sourceList[i + 1];
          final nextSpeech = energyProfile.findFirstSpeech(
            next.start.inMilliseconds,
            next.end.inMilliseconds,
          );
          searchEndMs = min(searchEndMs, nextSpeech - 100);
        }

        if (searchEndMs - sMs >= 2000) {
          final blocks = energyProfile.findSpeechBlocks(sMs, searchEndMs);
          // 再兜一层：块数多于分句数时，逐个丢弃最短的块（泄漏的残音通常最短）
          final usable = blocks.toList();
          while (usable.length > clauses.length) {
            int minIdx = 0;
            for (int b = 1; b < usable.length; b++) {
              if ((usable[b].$2 - usable[b].$1) <
                  (usable[minIdx].$2 - usable[minIdx].$1)) {
                minIdx = b;
              }
            }
            usable.removeAt(minIdx);
          }

          if (usable.length >= clauses.length) {
            for (int cIdx = 0; cIdx < clauses.length; cIdx++) {
              final bStart = usable[cIdx].$1;
              final bEnd = usable[cIdx].$2;
              final nextStart = (cIdx + 1 < clauses.length)
                  ? usable[cIdx + 1].$1
                  : max(searchEndMs, bEnd);

              final cText = clauses[cIdx];
              final cjk = RegExp(r'[\u4e00-\u9fa5]').allMatches(cText).length;
              final words = cText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
              final estDur = (cjk * 240 + words * 320 + 500).clamp(1400, 4500);

              int endTarget = max(bEnd + 500, bStart + estDur);
              if (endTarget > nextStart - 300) {
                endTarget = max(bStart + 1000, nextStart - 300);
              }

              // 末尾分句补回原句的句末标点（中英文都处理），
              // 但分句自身已有标点时不补，避免出现 "lights.." 这类重复标点
              final tailPunct =
                  RegExp(r'[.。！？!?…]$').firstMatch(text)?.group(0);
              final needPunct = cIdx == clauses.length - 1 &&
                  tailPunct != null &&
                  !RegExp(r'[.!?。！？…]$').hasMatch(cText);

              preprocessed.add(SubtitleEntry(
                start: Duration(milliseconds: bStart),
                end: Duration(milliseconds: endTarget),
                text: needPunct ? '$cText$tailPunct' : cText,
                translatedText: cur.translatedText,
              ));
            }
            continue;
          }
        }
      }

      preprocessed.add(SubtitleEntry(
        start: Duration(milliseconds: sMs),
        end: Duration(milliseconds: eMs),
        text: text,
        translatedText: cur.translatedText,
      ));
    }

    // 第二步：阅读时长合理限制与自然淡出
    final result = <SubtitleEntry>[];
    for (int i = 0; i < preprocessed.length; i++) {
      final cur = preprocessed[i];
      final text = cur.text.trim();
      if (text.isEmpty) continue;

      // 忽略纯音乐与背景音占位符
      final lower = text.toLowerCase();
      const placeholders = {
        'music', '[music]', '(music)', '♪', '♫', '♪♪', '♫♫',
        '[applause]', 'applause', '[laughter]', 'laughter',
        '[silence]', 'silence', '[blank_audio]',
      };
      if (placeholders.contains(lower)) continue;
      // 纯括号标注（如 "(laughs)"、"[SIGHS]"）也属于非字幕内容
      if (RegExp(r'^[\[(][^\])]*[\])]$').hasMatch(text)) continue;

      final cjkCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
      final wordCount =
          text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

      // 基于字数计算自然朗读与阅读时长
      final baseEstimateMs = (cjkCount * 240 + wordCount * 320 + 600);
      // 允许的最大停留上限：朗读完后预留合理的理解视线停留（最多 5.5 秒），
      // 避免因背景音乐（BGM）或环境底噪持续触发能量阈值，导致字幕在说完后跨越长段留白一直不退场。
      final maxHoldMs = (baseEstimateMs * 1.4).clamp(1800, 5500).toInt();
      final idealMaxDurationMs = baseEstimateMs.clamp(1400, maxHoldMs);

      // 下一段台词的起始时间点（若为末句则以自身结尾为边界）
      final nextStartMs = (i + 1 < preprocessed.length)
          ? preprocessed[i + 1].start.inMilliseconds
          : cur.end.inMilliseconds;

      final speechEndMs = energyProfile?.findLastSpeechEnd(
            cur.start.inMilliseconds,
            cur.end.inMilliseconds,
          ) ??
          -1;

      int actualEndMs;
      if (speechEndMs > 0) {
        // 说话结束后留出 350ms 的自然停顿与视线缓冲
        actualEndMs = max(speechEndMs + 350, cur.start.inMilliseconds + 1000);
        // 不能超出原始分段边界
        actualEndMs = min(actualEndMs, cur.end.inMilliseconds);
        // 关键防御：不能超过字数所对应的最大合理停留时长，确保台词说完后能正常进入留白
        actualEndMs = min(actualEndMs, cur.start.inMilliseconds + maxHoldMs);
      } else {
        actualEndMs = min(
          cur.end.inMilliseconds,
          cur.start.inMilliseconds + idealMaxDurationMs,
        );
      }

      // 不能侵占下一句的开始时间（并在两句之间至少留出 80ms 视觉换句呼吸期）
      if (actualEndMs > nextStartMs - 80) {
        actualEndMs = nextStartMs > cur.start.inMilliseconds + 1000
            ? nextStartMs - 80
            : cur.start.inMilliseconds + 1000;
      }

      // 模型偶给出极短的时间戳时，字幕会一闪而过；在不侵占下一条的前提下补足最低可读停留
      if (actualEndMs - cur.start.inMilliseconds < 1200 &&
          nextStartMs - cur.start.inMilliseconds >= 1600) {
        actualEndMs = cur.start.inMilliseconds + 1300;
      }

      result.add(SubtitleEntry(
        start: cur.start,
        end: Duration(milliseconds: actualEndMs),
        text: text,
        translatedText: cur.translatedText,
      ));
    }
    return result;
  }

  /// 去掉 whisper 贴在台词前后的非语音标签。
  ///
  /// 典型情况是模型把音乐标记和台词连成一段：`"MUSIC What the fuck?"`。
  /// 这里只处理**明确是标签**的写法：带括号的 `[MUSIC]` / `(music)`，
  /// 或全大写的 `MUSIC` / `APPLAUSE` 等；小写普通单词不动，
  /// 避免把 `Listen to music`（"听音乐"是正常台词）误伤。
  static String _stripNonSpeechLabels(String text) {
    const labels = 'music|applause|laughter|silence|noise|inaudible|beep';
    var result = text.trim();

    // 带括号的标签：出现在开头或结尾都清掉
    final bracket = RegExp(r'^[\[(](?:' + labels + r')[\])]\s*',
        caseSensitive: false);
    final bracketTail = RegExp(r'\s*[\[(](?:' + labels + r')[\])]$',
        caseSensitive: false);
    result = result.replaceFirst(bracket, '');
    result = result.replaceFirst(bracketTail, '');

    // 全大写、不带括号的标签（whisper 输出标记时的典型写法）
    final capsHead = RegExp(r'^(?:MUSIC|APPLAUSE|LAUGHTER|SILENCE|NOISE|INAUDIBLE)'
        r'\b[\s:.\-–—,]*');
    final capsTail = RegExp(
        r'[\s:.\-–—,]*(?:MUSIC|APPLAUSE|LAUGHTER|SILENCE|NOISE|INAUDIBLE)\s*$');
    result = result.replaceFirst(capsHead, '');
    result = result.replaceFirst(capsTail, '');

    return result.trim();
  }

  /// 合并被引擎在句中截断的相邻原始分段。
  ///
  /// whisper 在 30 秒窗口边界处会把一句话切成两段，例如：
  ///   `[14.8 -> 38.9] "Listen to music, send a message, turn on the lights, turn"`
  ///   `[38.9 -> 39.2] "off the lights."`
  /// 前一段没有句末标点、两段时间上首尾相接（间隙约 0ms）。这种必须合并，
  /// 否则会被后面的停顿拆分逻辑当成两个独立短语，后半截还会因为时间戳错位
  /// 而显示在错误的时刻。
  ///
  /// 但**必须防止滚雪球**：电影里的歌词、嘈杂对白常常整段没有标点，
  /// 若只按"无标点 + 紧邻"合并，会把几十个分段粘成一条几百词的字幕，
  /// 随后又被显示时长上限一刀切，导致"还在说话字幕就消失了"。
  /// 因此判据收紧为：
  ///   1. 间隙 ≤ 300ms（真正的句子之间一般会有更长的停顿）；
  ///   2. 前段没有句末标点；
  ///   3. 当前段看起来是"续接的残句"（以小写/短片段收尾），而不是一个完整新句；
  ///   4. 合并后总词数与总跨度都有硬上限（兜底保险）。
  static List<SubtitleEntry> _mergeRawContinuations(List<SubtitleEntry> raw) {
    if (raw.length < 2) return raw;

    const int maxMergeGapMs = 300;
    const int maxMergedUnits = 30;
    final sentenceEnd = RegExp(r'[.!?。！？…]$');
    final startsNewSentence = RegExp(r'^["“(\[]?[A-Z\u4e00-\u9fa5]');

    // 长度单位：西文按词、中文按字。
    // 中文没有空格，若只数"词"会永远算作 1，长度上限形同虚设，
    // 结果就是把整段中文对白粘成一条超长字幕。
    int textUnits(String text) {
      final cjk = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      return cjk + words;
    }

    final merged = <SubtitleEntry>[];
    var mergedUnits = 0;

    for (final cur in raw) {
      if (merged.isNotEmpty) {
        final prev = merged.last;
        final prevText = prev.text.trim();
        final curText = cur.text.trim();
        final gapMs = cur.start.inMilliseconds - prev.end.inMilliseconds;
        final curUnits = textUnits(curText);
        final totalUnits = mergedUnits + curUnits;

        // 当前段是否只是上一句的尾巴：不以大写/汉字开头，或本身很短
        final looksLikeTail =
            !startsNewSentence.hasMatch(curText) || curUnits <= 4;

        // 注意：这里**不能**再用"合并后总跨度"做限制。
        // whisper 的段末会延伸到下一个起点（含大段静音），跨度常常虚高，
        // 用它做判据会把合法的"句尾被截断"场景也一并否掉。长度上限已足够防滚雪球。
        final canMerge = prevText.isNotEmpty &&
            curText.isNotEmpty &&
            !sentenceEnd.hasMatch(prevText) &&
            gapMs <= maxMergeGapMs &&
            looksLikeTail &&
            totalUnits <= maxMergedUnits;

        if (canMerge) {
          merged[merged.length - 1] = SubtitleEntry(
            start: prev.start,
            end: cur.end,
            text: '$prevText $curText',
            translatedText: prev.translatedText,
          );
          mergedUnits = totalUnits;
          continue;
        }
      }
      merged.add(cur);
      mergedUnits = textUnits(cur.text.trim());
    }
    return merged;
  }

  /// 将字幕条目列表转换为标准的 SRT 格式文本。
  static String convertToSrt(List<SubtitleEntry> entries) {
    final buffer = StringBuffer();
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      buffer.writeln('${i + 1}');
      buffer.writeln(
        '${_formatSrtTimestamp(entry.start)} --> ${_formatSrtTimestamp(entry.end)}',
      );
      buffer.writeln(entry.text);
      if (entry.translatedText != null &&
          entry.translatedText!.trim().isNotEmpty) {
        buffer.writeln(entry.translatedText!.trim());
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String _formatSrtTimestamp(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final millis = d.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$millis';
  }

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  static Uint8List _createWavHeader(int dataLength) {
    final header = ByteData(44);
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, dataLength + 36, Endian.little);
    header.setUint8(8, 0x57);  // W
    header.setUint8(9, 0x41);  // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6d); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, 16000, Endian.little); // 16kHz
    header.setUint32(28, 32000, Endian.little); // byte rate
    header.setUint16(32, 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // 16-bit
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataLength, Endian.little);
    return header.buffer.asUint8List();
  }

  void _updateState(AsrState state, {int percent = 0, String? message}) {
    _state = state;
    _progressController.add(AsrProgress(
      state: state,
      percent: percent,
      message: message,
    ));
  }

  /// 从视频文件中提取音频为 16kHz mono WAV。
  ///
  /// Android / iOS / macOS 上使用内置原生 FFmpegKit，Windows 上使用系统 FFmpeg。
  /// 返回临时 WAV 文件路径，调用方负责清理。
  Future<String?> _extractAudioToWav(
    String videoPath, {
    void Function(double fraction, Duration processed, Duration total)?
        onProgress,
    bool Function()? isCancelled,
  }) async {
    try {
      final audioDir = NativeFileHelper.desktopCacheAudioDir();
      if (!audioDir.existsSync()) audioDir.createSync(recursive: true);

      // 用视频路径 hash 命名临时文件，避免冲突
      final hash = md5.convert(utf8.encode(videoPath)).toString().substring(0, 12);
      final wavPath =
          '${audioDir.path}${Platform.pathSeparator}pflx_asr_$hash.wav';

      // 如果临时文件已存在且大小合理，直接复用
      final existing = File(wavPath);
      if (await existing.exists() && await existing.length() > 1024) {
        onProgress?.call(1.0, Duration.zero, Duration.zero);
        return wavPath;
      }

      // 先问出视频时长，用来把 ffmpeg 的进度换算成百分比
      final totalSeconds = await _probeDurationSeconds(videoPath);
      final totalDuration =
          totalSeconds > 0 ? Duration(seconds: totalSeconds.round()) : Duration.zero;

      if (isCancelled?.call() == true || _cancelled) return null;

      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        return await _extractAudioWithFFmpegKit(
          videoPath: videoPath,
          wavPath: wavPath,
          totalSeconds: totalSeconds,
          totalDuration: totalDuration,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }

      final ffmpegCmd = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
      final process = await Process.start(
        ffmpegCmd,
        [
          '-y',
          // 只取音频、丢掉字幕与数据流；-map 0:a:0 只挑第一条音轨，少做无用解码
          '-i', videoPath,
          '-map', '0:a:0?',
          '-vn', '-sn', '-dn',
          '-acodec', 'pcm_s16le',
          '-ar', '16000',
          '-ac', '1',
          // 结构化进度输出到 stdout，便于解析
          '-progress', 'pipe:1',
          '-nostats',
          '-loglevel', 'error',
          wavPath,
        ],
        runInShell: false,
      );

      // 解析进度：out_time_us=<微秒>。
      // 注意 stdout / stderr 都是单订阅流，只能 listen 一次，也不能再 drain，
      // 否则会抛 StateError 被外层 catch 吞掉（表现成"音频提取失败"）。
      var lastReportedPercent = -1;
      final progressSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (isCancelled?.call() == true || _cancelled) {
            process.kill();
            return;
          }
          if (totalSeconds <= 0) return;
          final match = RegExp(r'^out_time_us=(\d+)').firstMatch(line.trim());
          if (match == null) return;
          final micros = int.tryParse(match.group(1)!) ?? 0;
          if (micros <= 0) return;
          final processed = Duration(microseconds: micros);
          final fraction = (processed.inMicroseconds / (totalSeconds * 1000000))
              .clamp(0.0, 1.0);
          final percent = (fraction * 100).round();
          if (percent == lastReportedPercent) return;
          lastReportedPercent = percent;
          onProgress?.call(fraction, processed, totalDuration);
        },
        onError: (_) {},
      );
      // stderr 也必须消费，否则管道写满会卡住子进程
      final stderrSub = process.stderr.listen((_) {}, onError: (_) {});

      final exitCode = await process.exitCode;
      await progressSub.cancel();
      await stderrSub.cancel();

      if (exitCode != 0) {
        // FFmpeg 不可用或视频没有音轨
        return null;
      }

      final wavFile = File(wavPath);
      if (!await wavFile.exists() || await wavFile.length() < 1024) {
        return null;
      }

      onProgress?.call(1.0, totalDuration, totalDuration);
      return wavPath;
    } catch (_) {
      return null;
    }
  }

  /// 使用 FFmpegKit 提取音频（适用于 Android / iOS / macOS 原生集成环境）
  Future<String?> _extractAudioWithFFmpegKit({
    required String videoPath,
    required String wavPath,
    required double totalSeconds,
    required Duration totalDuration,
    void Function(double fraction, Duration processed, Duration total)?
        onProgress,
    bool Function()? isCancelled,
  }) async {
    try {
      final arguments = [
        '-y',
        '-i', videoPath,
        '-map', '0:a:0?',
        '-vn', '-sn', '-dn',
        '-acodec', 'pcm_s16le',
        '-ar', '16000',
        '-ac', '1',
        wavPath,
      ];

      var lastReportedPercent = -1;
      final completer = Completer<bool>();
      int? currentSessionId;

      final session = await FFmpegKit.executeWithArgumentsAsync(
        arguments,
        (completedSession) async {
          final returnCode = await completedSession.getReturnCode();
          if (!completer.isCompleted) {
            completer.complete(ReturnCode.isSuccess(returnCode));
          }
        },
        (log) {
          // 日志回调
        },
        (statistics) {
          if (isCancelled?.call() == true || _cancelled) {
            if (currentSessionId != null) {
              FFmpegKit.cancel(currentSessionId);
            }
            if (!completer.isCompleted) {
              completer.complete(false);
            }
            return;
          }
          final timeMs = statistics.getTime();
          if (totalSeconds > 0 && timeMs > 0) {
            final processed = Duration(milliseconds: timeMs);
            final fraction = (timeMs / (totalSeconds * 1000)).clamp(0.0, 1.0);
            final percent = (fraction * 100).round();
            if (percent != lastReportedPercent) {
              lastReportedPercent = percent;
              onProgress?.call(fraction, processed, totalDuration);
            }
          }
        },
      );

      currentSessionId = session.getSessionId();

      final success = await completer.future;
      if (!success) {
        return null;
      }

      final wavFile = File(wavPath);
      if (!await wavFile.exists() || await wavFile.length() < 1024) {
        return null;
      }

      onProgress?.call(1.0, totalDuration, totalDuration);
      return wavPath;
    } catch (_) {
      return null;
    }
  }

  /// 用 ffprobe / FFprobeKit 读取媒体总时长（秒）；失败返回 0。
  ///
  /// 只读头部信息，毫秒级完成，不会像"猜一个进度"那样让进度条骗人。
  Future<double> _probeDurationSeconds(String videoPath) async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        final session = await FFprobeKit.getMediaInformation(videoPath);
        final info = session.getMediaInformation();
        final durationStr = info?.getDuration();
        if (durationStr != null) {
          final d = double.tryParse(durationStr);
          if (d != null && d > 0) return d;
        }
      } catch (_) {}
      return 0;
    }

    final ffprobeCmd = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    try {
      final result = await Process.run(
        ffprobeCmd,
        [
          '-v', 'error',
          '-show_entries', 'format=duration',
          '-of', 'default=noprint_wrappers=1:nokey=1',
          videoPath,
        ],
        runInShell: false,
      );
      if (result.exitCode != 0) return 0;
      return double.tryParse(result.stdout.toString().trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  void _cleanupTempFile(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  /// 释放资源。
  void dispose() {
    _progressController.close();
  }
}

/// 音频能量分析器（轻量自适应 VAD）。
class AudioEnergyProfile {
  AudioEnergyProfile({
    required this.timeline,
    required this.noiseFloor,
    required this.speechThreshold,
  });

  /// 时刻与能量序列 [(tMs, rms)]
  final List<(int, double)> timeline;
  final double noiseFloor;
  final double speechThreshold;

  /// 返回 [fromMs, toMs] 内最后一次真实发声的结束时刻（毫秒）。
  ///
  /// 用于确定字幕应该停留到什么时候：以"最后一次发声 + 少量余量"为准。
  /// 要求至少连续 2 帧（约 100ms）高于阈值，过滤孤立瞬态底噪。
  /// 区间内没有检测到发声时返回 -1。
  int findLastSpeechEnd(int fromMs, int toMs) {
    var last = -1;
    int highCount = 0;
    for (final entry in timeline) {
      final t = entry.$1;
      final r = entry.$2;
      if (t < fromMs) continue;
      if (t > toMs) break;
      if (r >= speechThreshold) {
        highCount++;
        if (highCount >= 2) {
          last = t + 100; // 采样窗口长 100ms
        }
      } else {
        highCount = 0;
      }
    }
    return last;
  }

  /// 在 [fromMs, toMs] 范围内寻找首次出现真实人声发音的毫秒点
  int findFirstSpeech(int fromMs, int toMs) {
    int consecutiveHigh = 0;
    int firstHighTime = fromMs;

    for (final entry in timeline) {
      final t = entry.$1;
      final r = entry.$2;
      if (t < fromMs) continue;
      if (t > toMs) break;

      if (r >= speechThreshold) {
        if (consecutiveHigh == 0) firstHighTime = t;
        consecutiveHigh++;
        // 连续 200ms 以上高能量，确认人声发音，过滤孤立瞬态底噪
        if (consecutiveHigh >= 4) {
          return max(fromMs, firstHighTime - 200);
        }
      } else {
        consecutiveHigh = 0;
      }
    }
    return fromMs;
  }

  /// 在 [fromMs, toMs] 范围内寻找连续人声块列表 [(startMs, endMs)]
  ///
  /// [minBlockMs] 用于丢弃过短的碎片发音块（瞬态噪声、或相邻句子的起音泄漏），
  /// 保证统计出来的块数都是真正成句的语音。
  List<(int, int)> findSpeechBlocks(int fromMs, int toMs,
      {int minBlockMs = 700}) {
    final rawBlocks = <(int, int)>[];
    bool inSpeech = false;
    int blockStart = fromMs;

    for (final entry in timeline) {
      final t = entry.$1;
      final r = entry.$2;
      if (t < fromMs) continue;
      if (t > toMs) break;

      if (r >= speechThreshold) {
        if (!inSpeech) {
          inSpeech = true;
          blockStart = max(fromMs, t - 200);
        }
      } else {
        if (inSpeech) {
          inSpeech = false;
          rawBlocks.add((blockStart, min(toMs, t + 400)));
        }
      }
    }
    if (inSpeech) {
      rawBlocks.add((blockStart, toMs));
    }

    // 合并间隔低于 700ms 的短停顿碎片语音
    final merged = <(int, int)>[];
    for (final b in rawBlocks) {
      if (merged.isEmpty) {
        merged.add(b);
      } else {
        final last = merged.last;
        if (b.$1 - last.$2 < 700) {
          merged[merged.length - 1] = (last.$1, b.$2);
        } else {
          merged.add(b);
        }
      }
    }

    // 丢弃过短的碎片发音块：多为瞬态噪声，或下一段发音的起音漏进了本段窗口，
    // 不能把它当成一个"有效停顿前的短语"，否则会诱发错误的拆句。
    final filtered =
        merged.where((b) => (b.$2 - b.$1) >= minBlockMs).toList();
    return filtered.isNotEmpty ? filtered : merged;
  }

  /// 快速分析 16kHz 16bit 单声道 WAV 音频的能量特征（耗时 < 10ms）
  static Future<AudioEnergyProfile?> fromWavFile(String wavPath) async {
    try {
      final file = File(wavPath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 44) return null;

      final pcmBytes = bytes.sublist(44);
      final samples = Int16List.view(
        pcmBytes.buffer,
        pcmBytes.offsetInBytes,
        pcmBytes.length ~/ 2,
      );
      if (samples.isEmpty) return null;

      const sampleRate = 16000;
      final windowSize = (sampleRate * 0.1).toInt(); // 100ms
      final stepSize = (sampleRate * 0.05).toInt(); // 50ms

      final timeline = <(int, double)>[];
      final sampleCount = samples.length;
      final allRms = <double>[];

      for (int i = 0; i <= sampleCount - windowSize; i += stepSize) {
        double sumSquares = 0;
        for (int j = 0; j < windowSize; j++) {
          final s = samples[i + j];
          sumSquares += s * s;
        }
        final rms = sqrt(sumSquares / windowSize);
        final tMs = ((i / sampleRate) * 1000).toInt();
        timeline.add((tMs, rms));
        allRms.add(rms);
      }

      allRms.sort();
      final noiseFloor = allRms.isNotEmpty ? allRms[allRms.length ~/ 10] : 100.0;
      final speechThreshold = max(600.0, noiseFloor * 3.0);

      return AudioEnergyProfile(
        timeline: timeline,
        noiseFloor: noiseFloor,
        speechThreshold: speechThreshold,
      );
    } catch (_) {
      return null;
    }
  }
}
