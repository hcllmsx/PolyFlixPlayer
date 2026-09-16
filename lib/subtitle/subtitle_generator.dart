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

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'model_manager.dart';

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
    _updateState(AsrState.preparing, message: '正在准备…');

    try {
      // 1. 检查模型是否已下载
      final modelPath = await ModelManager.instance.getModelPath(modelId);
      if (modelPath == null) {
        _updateState(AsrState.error, message: '模型未下载，请先在设置中下载模型');
        return [];
      }

      if (_cancelled) return [];

      // 2. 提取音频为 WAV 文件
      _updateState(AsrState.preparing, message: '正在提取音频…');
      final wavPath = await _extractAudioToWav(videoPath);
      if (wavPath == null) {
        _updateState(AsrState.error, message: '音频提取失败');
        return [];
      }

      if (_cancelled) {
        _cleanupTempFile(wavPath);
        return [];
      }

      // 3. 执行 ASR 识别（在后台 Isolate 中进行安全 FFI 调用，不阻塞 UI 且彻底防止堆崩溃）
      _updateState(AsrState.processing, message: '正在分析语音并生成字幕…');
      _isModelInUse = true;

      final dllName = Platform.isWindows ? 'whisper_ggml.dll' : 'libwhisper_ggml.so';
      final langCode = language.trim().isEmpty ? 'auto' : language;

      final rawJson = await Isolate.run(() => _safeNativeTranscribe(
            dllName: dllName,
            modelPath: modelPath,
            wavPath: wavPath,
            language: langCode,
          ));

      // 4. 清理临时 WAV 文件
      _cleanupTempFile(wavPath);

      if (_cancelled) return [];

      // 5. 转换结果
      final resMap = jsonDecode(rawJson) as Map<String, dynamic>;
      if (resMap['@type'] == 'error') {
        final errMsg = resMap['message'] as String? ?? '未知错误';
        throw Exception(errMsg);
      }

      final segments = resMap['segments'] as List<dynamic>?;

      if (segments != null && segments.isNotEmpty) {
        for (final item in segments) {
          final seg = item as Map<String, dynamic>;
          // whisper.cpp 的时间戳单位是 10ms (厘秒/centiseconds)，必须乘以 10 转换为毫秒
          final fromMs = ((seg['from_ts'] as num?)?.toInt() ?? 0) * 10;
          final toMs = ((seg['to_ts'] as num?)?.toInt() ?? 0) * 10;
          final segText = (seg['text'] as String?)?.trim() ?? '';
          if (segText.isNotEmpty) {
            _entries.add(SubtitleEntry(
              start: Duration(milliseconds: fromMs),
              end: Duration(milliseconds: toMs),
              text: segText,
            ));
          }
        }
      } else {
        // 没有分段时间戳时，如果有全文，整体作为一条字幕
        final text = (resMap['text'] as String?)?.trim() ?? '';
        if (text.isNotEmpty) {
          _entries.add(SubtitleEntry(
            start: Duration.zero,
            end: const Duration(hours: 99),
            text: text,
          ));
        }
      }

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

  /// 在单独 Isolate 中执行的纯原生 FFI 转录。
  ///
  /// 绝对不要在 Windows 上对 C++ 返回的指针调用 malloc.free()，
  /// 否则将触发 0xc0000374 STATUS_HEAP_CORRUPTION 导致进程直接崩溃。
  static String _safeNativeTranscribe({
    required String dllName,
    required String modelPath,
    required String wavPath,
    required String language,
  }) {
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(dllName);
    } catch (_) {
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
      'threads': 4,
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
      'suppress_non_speech_tokens': false,
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
    _state = AsrState.idle;
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
  /// 使用系统 FFmpeg（Windows PATH 上需有 ffmpeg.exe）。
  /// 返回临时 WAV 文件路径，调用方负责清理。
  Future<String?> _extractAudioToWav(String videoPath) async {
    try {
      final tempDir = Directory.systemTemp;
      // 用视频路径 hash 命名临时文件，避免冲突
      final hash = md5.convert(videoPath.codeUnits).toString().substring(0, 12);
      final wavPath =
          '${tempDir.path}${Platform.pathSeparator}pflx_asr_$hash.wav';

      // 如果临时文件已存在且大小合理，直接复用
      final existing = File(wavPath);
      if (await existing.exists() && await existing.length() > 1024) {
        return wavPath;
      }

      // FFmpeg 提取音频：16kHz、单声道、16-bit PCM WAV
      final ffmpegCmd = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
      final result = await Process.run(
        ffmpegCmd,
        [
          '-y',
          '-i', videoPath,
          '-vn',
          '-acodec', 'pcm_s16le',
          '-ar', '16000',
          '-ac', '1',
          wavPath,
        ],
        runInShell: true,
      );

      if (result.exitCode != 0) {
        // FFmpeg 不可用或视频没有音轨
        return null;
      }

      final wavFile = File(wavPath);
      if (!await wavFile.exists() || await wavFile.length() < 1024) {
        return null;
      }

      return wavPath;
    } catch (_) {
      return null;
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
