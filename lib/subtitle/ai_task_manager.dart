/// 全局 AI 语音识别任务管理系统。
///
/// 负责跨页面协调后台转录任务、追踪切片进度、持久化字幕缓存，并向首页与播放页广播状态变更。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../utils/native_file_helper.dart';
import 'model_manager.dart';
import 'subtitle_generator.dart';

/// 单个 AI 语音识别任务实体。
class AiTask extends ChangeNotifier {
  AiTask({
    required this.id,
    required this.videoPath,
    required this.videoTitle,
    required this.modelId,
    required this.language,
  }) : startTime = DateTime.now();

  final String id;
  final String videoPath;
  final String videoTitle;
  final String modelId;
  final String language;
  final DateTime startTime;

  AsrState _state = AsrState.idle;
  AsrState get state => _state;

  Duration _totalDuration = Duration.zero;
  Duration get totalDuration => _totalDuration;

  Duration _processedDuration = Duration.zero;
  Duration get processedDuration => _processedDuration;

  double _percent = 0.0;
  double get percent => _percent;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  final List<SubtitleEntry> _entries = [];
  List<SubtitleEntry> get entries => List.unmodifiable(_entries);

  bool _isCancelled = false;
  bool get isCancelled => _isCancelled;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String get modelDisplayName {
    for (final m in availableModels) {
      if (m.id == modelId) return m.displayName;
    }
    return modelId.toUpperCase();
  }

  void updateState(
    AsrState state, {
    Duration? totalDuration,
    Duration? processedDuration,
    double? percent,
    String? message,
    String? errorMessage,
  }) {
    _state = state;
    if (totalDuration != null) _totalDuration = totalDuration;
    if (processedDuration != null) _processedDuration = processedDuration;
    if (percent != null) _percent = percent.clamp(0.0, 1.0);
    if (message != null) _statusMessage = message;
    if (errorMessage != null) _errorMessage = errorMessage;
    notifyListeners();
  }

  void addEntries(List<SubtitleEntry> newEntries) {
    _entries.addAll(newEntries);
    notifyListeners();
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _state = AsrState.idle;
    _statusMessage = '已取消';
    notifyListeners();
  }
}

/// 全局任务管理器单例。
class AiTaskManager extends ChangeNotifier {
  AiTaskManager._();
  static final AiTaskManager instance = AiTaskManager._();

  final Map<String, AiTask> _tasks = {};

  /// 所有当前活动中（正在提取或正在识别）的任务。
  List<AiTask> get activeTasks => _tasks.values
      .where((t) =>
          !t.isCancelled &&
          (t.state == AsrState.preparing || t.state == AsrState.processing))
      .toList();

  /// 是否有处于后台运行中的任务。
  bool get hasActiveTasks => activeTasks.isNotEmpty;

  /// 获取指定视频的任务（如果存在）。
  AiTask? getTask(String videoPath) => _tasks[videoPath];

  /// 启动某视频的语音识别任务。
  Future<AiTask> startTask({
    required String videoPath,
    required String videoTitle,
    required String modelId,
    String language = 'auto',
  }) async {
    final existing = _tasks[videoPath];
    if (existing != null &&
        !existing.isCancelled &&
        (existing.state == AsrState.preparing ||
            existing.state == AsrState.processing)) {
      return existing;
    }

    final task = AiTask(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_tasks.length}',
      videoPath: videoPath,
      videoTitle: videoTitle,
      modelId: modelId,
      language: language,
    );

    _tasks[videoPath] = task;
    notifyListeners();

    // 触发执行
    _runTask(task);
    return task;
  }

  /// 取消指定视频的任务。
  void cancelTask(String videoPath) {
    final task = _tasks[videoPath];
    if (task != null) {
      task.cancel();
      SubtitleGenerator.instance.cancel();
      notifyListeners();
    }
  }

  /// 后台驱动切片识别流水线。
  Future<void> _runTask(AiTask task) async {
    try {
      await SubtitleGenerator.instance.transcribeVideoChunked(
        videoPath: task.videoPath,
        modelId: task.modelId,
        language: task.language,
        onProgress: (state, processed, total, percent, message) {
          task.updateState(
            state,
            processedDuration: processed,
            totalDuration: total,
            percent: percent,
            message: message,
          );
          notifyListeners();
        },
        onNewEntries: (newEntries) {
          task.addEntries(newEntries);
          notifyListeners();
        },
        isCancelled: () => task.isCancelled,
      );

      if (task.isCancelled) {
        task.updateState(AsrState.idle, message: '任务已取消');
      } else {
        task.updateState(
          AsrState.completed,
          percent: 1.0,
          message: '识别完成 (共 ${task.entries.length} 条字幕)',
        );
        // 保存字幕缓存（按模型区分，仅写高效 JSON 缓存，不自动生成冗余 srt）
        await saveCachedSubtitles(task.videoPath, task.entries, modelId: task.modelId);
      }
    } catch (e) {
      task.updateState(
        AsrState.error,
        errorMessage: e.toString(),
        message: '识别失败: $e',
      );
    } finally {
      notifyListeners();
    }
  }

  /// 提取易读且安全的文件名（过滤非法字符并控制长度）。
  static String _extractCleanBaseName(String videoPath) {
    String base = videoPath.split(Platform.isWindows ? r'\' : '/').last;
    final dotIdx = base.lastIndexOf('.');
    if (dotIdx > 0) base = base.substring(0, dotIdx);
    var clean = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (clean.length > 36) clean = clean.substring(0, 36);
    return clean.isEmpty ? 'video' : clean;
  }

  /// 计算视频文件特征指纹（文件精确大小 + 头部 8KB 快速哈希）。
  ///
  /// 耗时 < 1 毫秒，不受视频绝对路径或重命名的影响；
  /// 即使在不同目录下，相同视频内容也会生成完全一致的 8 位特征码。
  static String _getVideoFingerprint(String videoPath) {
    try {
      final file = File(videoPath);
      if (file.existsSync()) {
        final length = file.lengthSync();
        if (length > 0) {
          final raf = file.openSync(mode: FileMode.read);
          final readLen = length < 8192 ? length : 8192;
          final bytes = raf.readSync(readLen);
          raf.closeSync();
          final lenBytes = utf8.encode('$length:');
          return md5.convert([...lenBytes, ...bytes]).toString().substring(0, 8);
        }
      }
    } catch (_) {}
    // 流媒体或读取失败降级为路径 hash
    return md5.convert(utf8.encode(videoPath)).toString().substring(0, 8);
  }

  /// 查找指定视频在特定模型下的缓存文件（支持跨路径/跨目录副本自动匹配）。
  File? _findCacheFile(
    String videoPath,
    String modelId,
    String fingerprint,
    String dirPath,
  ) {
    final cleanName = _extractCleanBaseName(videoPath);
    final mId = modelId.toLowerCase();

    // 1. 首选：同名 + 同模型 + 同指纹
    final direct = File('$dirPath${Platform.pathSeparator}${cleanName}_${mId}_$fingerprint.json');
    if (direct.existsSync()) return direct;

    // 2. 跨目录/改名匹配：扫描缓存目录下所有具有相同特征指纹的文件 (*_${mId}_${fingerprint}.json)
    try {
      final dir = Directory(dirPath);
      final list = dir.listSync();
      final targetSuffix = '_${mId}_$fingerprint.json';
      for (final item in list) {
        if (item is File && item.path.endsWith(targetSuffix)) {
          return item;
        }
      }
    } catch (_) {}

    // 3. 兼容检查上个版本基于路径前6位短哈希命名的文件
    final pathHash6 = md5.convert(utf8.encode(videoPath)).toString().substring(0, 6);
    final legacyShort = File('$dirPath${Platform.pathSeparator}${cleanName}_${mId}_$pathHash6.json');
    if (legacyShort.existsSync()) return legacyShort;

    return null;
  }

  /// 获取指定视频已缓存过字幕的模型列表（支持跨目录检测已存在缓存）。
  Future<List<String>> getCachedModelIds(String videoPath) async {
    final dir = NativeFileHelper.desktopSubtitleCacheDir();
    if (!dir.existsSync()) return const [];

    final fingerprint = _getVideoFingerprint(videoPath);
    final cached = <String>[];
    for (final mid in ['tiny', 'base', 'small']) {
      final f = _findCacheFile(videoPath, mid, fingerprint, dir.path);
      if (f != null && f.existsSync()) {
        cached.add(mid);
      }
    }
    return cached;
  }

  /// 读取已缓存的字幕数据。
  ///
  /// 若指定了 [modelId]，则严格只加载该模型的字幕（支持跨目录副本自动复用），
  /// 找不到时返回 null，绝不回退到其他模型的缓存，保证与「已缓存」标签一致；
  /// 若未指定，则按 small -> base -> tiny 顺序匹配，并向前兼容旧版 sub_hash.json 缓存。
  Future<List<SubtitleEntry>?> loadCachedSubtitles(
    String videoPath, {
    String? modelId,
  }) async {
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) return null;

      final fingerprint = _getVideoFingerprint(videoPath);

      // 1. 若指定了模型，严格精准加载（支持跨路径/同视频自动复用，不回退其他模型）
      if (modelId != null && modelId.isNotEmpty) {
        final targetFile = _findCacheFile(videoPath, modelId, fingerprint, dir.path);
        if (targetFile != null && await targetFile.exists()) {
          return await _readJsonEntries(targetFile);
        }
        return null;
      }

      // 2. 否则按优先级匹配可能存在的历史缓存 (small -> base -> tiny)
      for (final mid in ['small', 'base', 'tiny']) {
        final f = _findCacheFile(videoPath, mid, fingerprint, dir.path);
        if (f != null && await f.exists()) {
          return await _readJsonEntries(f);
        }
      }

      // 3. 向前兼容旧版的纯路径哈希命名：sub_${hash16}.json
      final oldHash = md5.convert(utf8.encode(videoPath)).toString().substring(0, 16);
      final oldFile = File('${dir.path}${Platform.pathSeparator}sub_$oldHash.json');
      if (await oldFile.exists()) {
        return await _readJsonEntries(oldFile);
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<SubtitleEntry>?> _readJsonEntries(File file) async {
    final jsonStr = await file.readAsString();
    final list = jsonDecode(jsonStr) as List<dynamic>;
    return list
        .map((e) => SubtitleEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 将字幕数据保存至本地缓存（以安全视频名 + 模型 + 内容指纹命名，支持跨目录自动复用）。
  Future<void> saveCachedSubtitles(
    String videoPath,
    List<SubtitleEntry> entries, {
    String? modelId,
  }) async {
    try {
      final cleanName = _extractCleanBaseName(videoPath);
      final fingerprint = _getVideoFingerprint(videoPath);
      final mId = (modelId != null && modelId.isNotEmpty) ? modelId.toLowerCase() : 'default';
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final file = File('${dir.path}${Platform.pathSeparator}${cleanName}_${mId}_$fingerprint.json');
      final jsonList = entries.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (_) {}
  }

  /// 删除指定视频在特定模型下的本地字幕缓存文件。
  Future<bool> deleteCachedSubtitles(String videoPath, {required String modelId}) async {
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) return false;

      final fingerprint = _getVideoFingerprint(videoPath);
      final targetFile = _findCacheFile(videoPath, modelId, fingerprint, dir.path);
      if (targetFile != null && await targetFile.exists()) {
        await targetFile.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
