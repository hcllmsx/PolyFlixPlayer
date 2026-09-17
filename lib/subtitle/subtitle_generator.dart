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

import '../utils/native_file_helper.dart';
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

  /// 批量设置字幕条目（从缓存恢复或从后台任务同步）。
  void setEntries(List<SubtitleEntry> list) {
    _entries.clear();
    _entries.addAll(list);
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
    _entries.clear();
    _updateState(AsrState.preparing, message: '正在准备模型…');
    onProgress?.call(AsrState.preparing, Duration.zero, Duration.zero, 0.0, '正在准备模型…');

    final modelPath = await ModelManager.instance.getModelPath(modelId);
    if (modelPath == null) {
      _updateState(AsrState.error, message: '模型未就绪');
      onProgress?.call(AsrState.error, Duration.zero, Duration.zero, 0.0, '模型未就绪');
      return [];
    }

    if (isCancelled?.call() == true || _cancelled) return [];

    _updateState(AsrState.preparing, message: '正在提取音频…');
    onProgress?.call(AsrState.preparing, Duration.zero, Duration.zero, 0.0, '正在提取音频…');
    final wavPath = await _extractAudioToWav(videoPath);
    if (wavPath == null) {
      _updateState(AsrState.error, message: '音频提取失败');
      onProgress?.call(AsrState.error, Duration.zero, Duration.zero, 0.0, '音频提取失败');
      return [];
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
      _updateState(AsrState.error, message: '音频数据为空');
      return [];
    }

    _updateState(AsrState.processing, message: '开始分析音频并生成字幕…');
    _isModelInUse = true;

    // 分析音频能量（静音区间与人声发音点），用于消除前导静音漂移和长句按停顿智能拆分
    final energyProfile = await AudioEnergyProfile.fromWavFile(wavPath);

    final dllName = Platform.isWindows ? 'whisper_ggml.dll' : 'libwhisper_ggml.so';
    final langCode = language.trim().isEmpty ? 'auto' : language;

    // 如果音频较短（<= 120 秒），无需切片，直接整体转录！
    // 这样短视频保留全局上下文与最准确的时间戳，不受切片边界干扰。
    if (totalSeconds <= 120) {
      _updateState(AsrState.processing, percent: 30, message: '正在分析完整音频…');
      onProgress?.call(AsrState.processing, Duration.zero, totalDuration, 0.3, '正在分析完整音频…');

      final rawJson = await Isolate.run(() => _safeNativeTranscribe(
            dllName: dllName,
            modelPath: modelPath,
            wavPath: wavPath,
            language: langCode,
          ));

      if (isCancelled?.call() == true || _cancelled) {
        _updateState(AsrState.idle, message: '已取消');
        onProgress?.call(AsrState.idle, Duration.zero, totalDuration, 0.0, '已取消');
        return [];
      }

      final resMap = jsonDecode(rawJson) as Map<String, dynamic>;
      final rawEntries = <SubtitleEntry>[];
      if (resMap['@type'] != 'error') {
        final segments = resMap['segments'] as List<dynamic>?;
        if (segments != null && segments.isNotEmpty) {
          for (final item in segments) {
            final seg = item as Map<String, dynamic>;
            final fromMs = ((seg['from_ts'] as num?)?.toInt() ?? 0) * 10;
            final toMs = ((seg['to_ts'] as num?)?.toInt() ?? 0) * 10;
            final segText = (seg['text'] as String?)?.trim() ?? '';
            if (segText.isNotEmpty) {
              rawEntries.add(SubtitleEntry(
                start: Duration(milliseconds: fromMs),
                end: Duration(milliseconds: toMs),
                text: segText,
              ));
            }
          }
        }
      }

      final normalized = normalizeEntries(rawEntries, energyProfile: energyProfile);
      _entries.addAll(normalized);
      onNewEntries?.call(normalized);

      final finalMsg = _entries.isNotEmpty
          ? '识别完成 (共 ${_entries.length} 条字幕)'
          : '未检测到有效语音';
      _updateState(AsrState.completed, percent: 100, message: finalMsg);
      onProgress?.call(AsrState.completed, totalDuration, totalDuration, 1.0, finalMsg);
      return List.unmodifiable(_entries);
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
          _updateState(AsrState.idle, message: '已取消');
          break;
        }

        final chunkOffset = 44 + i * chunkBytes;
        final currentChunkBytes = (chunkOffset + chunkBytes <= wavSize)
            ? chunkBytes
            : (wavSize - chunkOffset);

        if (currentChunkBytes <= 0) break;

        final currentProcessedSec = i * chunkSeconds;
        final percent = (currentProcessedSec / totalSeconds).clamp(0.0, 0.99);
        final progressMsg = '已识别 ${_formatDuration(Duration(seconds: currentProcessedSec))} / ${_formatDuration(totalDuration)} (${(percent * 100).toStringAsFixed(1)}%) · 片段 ${i + 1}/$chunkCount';

        _updateState(AsrState.processing, percent: (percent * 100).toInt(), message: progressMsg);
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

        // 原生调用转录该分片
        final rawJson = await Isolate.run(() => _safeNativeTranscribe(
              dllName: dllName,
              modelPath: modelPath,
              wavPath: tempChunkPath,
              language: langCode,
            ));

        _cleanupTempFile(tempChunkPath);

        // 解析并追加
        final resMap = jsonDecode(rawJson) as Map<String, dynamic>;
        if (resMap['@type'] != 'error') {
          final segments = resMap['segments'] as List<dynamic>?;
          final chunkEntries = <SubtitleEntry>[];
          final offsetMs = i * chunkSeconds * 1000;

          if (segments != null && segments.isNotEmpty) {
            for (final item in segments) {
              final seg = item as Map<String, dynamic>;
              final fromMs = ((seg['from_ts'] as num?)?.toInt() ?? 0) * 10;
              final toMs = ((seg['to_ts'] as num?)?.toInt() ?? 0) * 10;
              final segText = (seg['text'] as String?)?.trim() ?? '';
              if (segText.isNotEmpty) {
                chunkEntries.add(SubtitleEntry(
                  start: Duration(milliseconds: offsetMs + fromMs),
                  end: Duration(milliseconds: offsetMs + toMs),
                  text: segText,
                ));
              }
            }
          }
          if (chunkEntries.isNotEmpty) {
            final normalizedChunk = normalizeEntries(chunkEntries);
            rawAccumulated.addAll(chunkEntries);
            _entries.addAll(normalizedChunk);
            onNewEntries?.call(normalizedChunk);
          }
        }
      }
    } finally {
      await raf?.close();
      _cleanupTempFile(tempChunkPath);
    }

    if (isCancelled?.call() == true || _cancelled) {
      _updateState(AsrState.idle, message: '已取消');
      onProgress?.call(AsrState.idle, Duration.zero, totalDuration, 0.0, '已取消');
      return [];
    }

    // 全量整体再次执行一次平滑校准，确保分段接缝处的时长自然过渡与静音校准
    final fullyNormalized = normalizeEntries(rawAccumulated, energyProfile: energyProfile);
    _entries.clear();
    _entries.addAll(fullyNormalized);

    final finalMsg = _entries.isNotEmpty
        ? '识别完成 (共 ${_entries.length} 条字幕)'
        : '未检测到有效语音';
    _updateState(AsrState.completed, percent: 100, message: finalMsg);
    onProgress?.call(AsrState.completed, totalDuration, totalDuration, 1.0, finalMsg);

    return List.unmodifiable(_entries);
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

    // 第一步：基于真实音频能量校准发音起点，并将长复合句智能拆分为多短语
    final preprocessed = <SubtitleEntry>[];

    for (int i = 0; i < rawList.length; i++) {
      final cur = rawList[i];
      final text = cur.text.trim();
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
      final clauses = text
          .split(RegExp(r'[,;，；]\s*'))
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList();

      if (clauses.length >= 2 && (eMs - sMs) >= 4000 && energyProfile != null) {
        // whisper 的 to_ts 会一直延伸到下一句的起点，导致搜索窗口里混进下一句起音的残块。
        // 因此把窗口右边界收敛到"下一句真实发音点"之前，保证只统计本句自己的语音块。
        int searchEndMs = eMs;
        if (i + 1 < rawList.length) {
          final next = rawList[i + 1];
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

              // 仅当分句自身没有句末标点时才补句号，避免出现 "lights.." 这类重复标点
              final needPeriod = cIdx == clauses.length - 1 &&
                  text.endsWith('.') &&
                  !RegExp(r'[.!?。！？…]$').hasMatch(cText);

              preprocessed.add(SubtitleEntry(
                start: Duration(milliseconds: bStart),
                end: Duration(milliseconds: endTarget),
                text: needPeriod ? '$cText.' : cText,
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
      if (lower == '[music]' ||
          lower == '(music)' ||
          lower == '♪' ||
          lower == '♫' ||
          lower == '[applause]' ||
          lower == '[laughter]') {
        continue;
      }

      final cjkCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
      final wordCount =
          text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

      final baseEstimateMs = (cjkCount * 240 + wordCount * 320 + 600);
      final idealMaxDurationMs = baseEstimateMs.clamp(1500, 5500);

      final nextStartMs = (i + 1 < preprocessed.length)
          ? preprocessed[i + 1].start.inMilliseconds
          : (cur.start.inMilliseconds + idealMaxDurationMs);

      int actualEndMs = cur.end.inMilliseconds;
      final rawDurationMs = actualEndMs - cur.start.inMilliseconds;

      if (rawDurationMs > idealMaxDurationMs) {
        actualEndMs = cur.start.inMilliseconds + idealMaxDurationMs;
      }

      if (actualEndMs > nextStartMs) {
        actualEndMs = nextStartMs > cur.start.inMilliseconds
            ? nextStartMs
            : cur.start.inMilliseconds + 1000;
      }

      // 模型偶给出极短的时间戳时，字幕会一闪而过；在不侵占下一条的前提下补足可读停留
      if (actualEndMs - cur.start.inMilliseconds < 1200 &&
          nextStartMs - cur.start.inMilliseconds >= 1600) {
        actualEndMs = cur.start.inMilliseconds + 1400;
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
  /// 使用系统 FFmpeg（Windows PATH 上需有 ffmpeg.exe）。
  /// 返回临时 WAV 文件路径，调用方负责清理。
  Future<String?> _extractAudioToWav(String videoPath) async {
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
