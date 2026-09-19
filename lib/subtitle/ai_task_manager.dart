/// 全局 AI 语音识别任务管理系统。
///
/// 负责跨页面协调后台转录任务、追踪切片进度、持久化字幕缓存，并向首页与播放页广播状态变更。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../utils/native_file_helper.dart';
import 'model_manager.dart';
import 'subtitle_generator.dart';
import 'translation/translation_engine.dart';
import 'translation/translation_service.dart';
import 'translation/builtin_subtitle_extractor.dart';

/// 任务类型：语音识别 或 字幕翻译
enum AiTaskType {
  transcription,
  translation,
}

/// 单个 AI 任务实体（支持语音识别与字幕翻译）。
class AiTask extends ChangeNotifier {
  AiTask({
    required this.id,
    required this.videoPath,
    required this.videoTitle,
    required this.modelId,
    required this.language,
    this.taskType = AiTaskType.transcription,
    this.targetLanguage,
    this.sourceType,
    this.engineId,
    this.pendingTranslationLang,
    String? cacheKey,
    DateTime? startTime,
  }) : cacheKey = cacheKey ?? videoPath,
       startTime = startTime ?? DateTime.now();

  final String id;
  final AiTaskType taskType;
  final String? targetLanguage;
  final String? sourceType;
  final String? engineId;

  /// 若在 ASR 识别过程中预约了翻译，记录目标语言（如 'zh-Hans'）
  String? pendingTranslationLang;
  bool get hasPendingTranslation => pendingTranslationLang != null;

  /// 提取音频用的地址：本地文件路径，或 PFLX 本次会话的本地流地址。
  final String videoPath;

  /// 字幕缓存的**身份键**，必须是稳定值（本地文件路径 / .pflx 文件路径）。
  ///
  /// 为什么不直接用 [videoPath]：PFLX 的播放地址是
  /// `http://127.0.0.1:<随机端口>/pflx`，端口每次打开都不同，拿它当缓存键会
  /// 导致"下次打开同一条视频找不到上次的缓存"，于是重复识别、缓存越攒越多。
  final String cacheKey;

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

  int _totalUnits = 0;
  int get totalUnits => _totalUnits;

  int _completedUnits = 0;
  int get completedUnits => _completedUnits;

  String get modelDisplayName {
    if (taskType == AiTaskType.translation) {
      final langName = targetLanguage != null
          ? TranslationLanguage.findByCode(targetLanguage!).name
          : '目标语言';
      final src = (sourceType != null && sourceType!.startsWith('builtin_'))
          ? '内置字幕'
          : '识别字幕';
      return '$src翻译 → $langName';
    }
    for (final m in availableModels) {
      if (m.id == modelId) return m.displayName;
    }
    return modelId.toUpperCase();
  }

  /// 是否正在运行（语音识别或字幕翻译中）。
  ///
  /// [isInterrupted] 的任务虽然保存时是 processing，但续跑不可能，所以不算运行中。
  bool get isRunning =>
      !_isCancelled &&
      !_interrupted &&
      (_state == AsrState.preparing || _state == AsrState.processing);

  /// 是否已经结束（完成 / 失败 / 取消 / 中断）。
  bool get isFinished => !isRunning;

  /// 是否是被应用退出打断的任务（从磁盘恢复历史记录时判定）。
  bool _interrupted = false;
  bool get isInterrupted => _interrupted;

  /// 已生成字幕条数。
  ///
  /// 历史记录不把字幕本体写进 JSON（体积太大，字幕在缓存文件里），
  /// 只保留条数，所以这里的取值要兼容"有实体条目"和"只有条数"两种情况。
  int _entryCount = 0;
  int get entryCount => _entries.isNotEmpty ? _entries.length : _entryCount;

  /// 结束时间（完成 / 失败 / 取消时写入）。
  DateTime? _endTime;
  DateTime? get endTime => _endTime;

  /// 本条任务已耗时：进行中按"现在"算，结束后固定为总耗时。
  Duration get elapsed => (_endTime ?? DateTime.now()).difference(startTime);

  /// 把时长格式化成 `12 秒` / `3 分 05 秒` / `1 时 02 分`。
  static String formatDuration(Duration d) {
    final seconds = d.inSeconds;
    if (seconds < 60) {
      return '$seconds 秒';
    }
    final minutes = seconds ~/ 60;
    if (minutes < 60) {
      return '$minutes 分 ${(seconds % 60).toString().padLeft(2, '0')} 秒';
    }
    return '${minutes ~/ 60} 时 ${(minutes % 60).toString().padLeft(2, '0')} 分';
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
    // 进入终态就固定结束时间，之后 elapsed 不再增长
    if (state == AsrState.completed || state == AsrState.error) {
      _endTime ??= DateTime.now();
    }
    notifyListeners();
  }

  void updateTranslationProgress(int completed, int total, {String? message}) {
    _completedUnits = completed;
    _totalUnits = total;
    if (total > 0) {
      _percent = (completed / total).clamp(0.0, 1.0);
    }
    if (message != null) _statusMessage = message;
    notifyListeners();
  }

  void addEntries(List<SubtitleEntry> newEntries) {
    _entries.addAll(newEntries);
    notifyListeners();
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    pendingTranslationLang = null;
    _state = AsrState.idle;
    _statusMessage = '已取消';
    _endTime ??= DateTime.now();
    notifyListeners();
  }

  /// 序列化。字幕本体不入库（在缓存文件里），只记条数。
  ///
  /// [lastSeen] 仅在任务仍在运行时写入：应用被强杀时它代表"最后一次已知存活时间"，
  /// 恢复历史记录时用它可以算出一个合理的耗时，而不是把离线时长也算进去。
  Map<String, dynamic> toJson({DateTime? lastSeen}) => {
    'id': id,
    'taskType': taskType.name,
    'videoPath': videoPath,
    'cacheKey': cacheKey,
    'videoTitle': videoTitle,
    'modelId': modelId,
    'language': language,
    'targetLanguage': targetLanguage,
    'sourceType': sourceType,
    'engineId': engineId,
    'pendingTranslationLang': pendingTranslationLang,
    'totalUnits': _totalUnits,
    'completedUnits': _completedUnits,
    'startTime': startTime.toIso8601String(),
    'endTime': _endTime?.toIso8601String(),
    'lastSeen': lastSeen?.toIso8601String(),
    'state': _state.name,
    'statusMessage': _statusMessage,
    'errorMessage': _errorMessage,
    'entryCount': entryCount,
    'percent': _percent,
    'cancelled': _isCancelled,
  };

  /// 从持久化数据恢复一条历史记录。数据损坏时返回 null（跳过这一条）。
  static AiTask? fromJson(Map<String, dynamic> json) {
    try {
      final videoPath = json['videoPath'] as String;
      final taskTypeStr = json['taskType'] as String?;
      final taskType = AiTaskType.values.firstWhere(
        (t) => t.name == taskTypeStr,
        orElse: () => AiTaskType.transcription,
      );

      final task = AiTask(
        id: json['id'] as String,
        taskType: taskType,
        videoPath: videoPath,
        // 旧记录没有 cacheKey：按 videoPath 兜底（老版本本来就用它当缓存键）
        cacheKey: (json['cacheKey'] as String?) ?? videoPath,
        videoTitle: (json['videoTitle'] as String?) ?? '',
        modelId: (json['modelId'] as String?) ?? '',
        language: (json['language'] as String?) ?? 'auto',
        targetLanguage: json['targetLanguage'] as String?,
        sourceType: json['sourceType'] as String?,
        engineId: json['engineId'] as String?,
        pendingTranslationLang: json['pendingTranslationLang'] as String?,
        startTime:
            DateTime.tryParse((json['startTime'] as String?) ?? '') ??
            DateTime.now(),
      );

      task._totalUnits = (json['totalUnits'] as num?)?.toInt() ?? 0;
      task._completedUnits = (json['completedUnits'] as num?)?.toInt() ?? 0;
      task._entryCount = (json['entryCount'] as num?)?.toInt() ?? 0;
      task._percent = ((json['percent'] as num?)?.toDouble() ?? 0).clamp(
        0.0,
        1.0,
      );
      task._statusMessage = json['statusMessage'] as String?;
      task._errorMessage = json['errorMessage'] as String?;
      task._isCancelled = (json['cancelled'] as bool?) ?? false;
      final stateName = json['state'] as String?;
      task._state = AsrState.values.firstWhere(
        (s) => s.name == stateName,
        orElse: () => AsrState.idle,
      );

      final endTime = DateTime.tryParse((json['endTime'] as String?) ?? '');
      final lastSeen = DateTime.tryParse((json['lastSeen'] as String?) ?? '');
      task._endTime = endTime ?? lastSeen;

      // 保存时还在跑的：应用已经退出，不可能续跑，标记为"已中断"
      if (!task._isCancelled &&
          (task._state == AsrState.preparing ||
              task._state == AsrState.processing)) {
        task._interrupted = true;
        task._state = AsrState.idle;
        task._statusMessage = taskType == AiTaskType.translation
            ? '已中断（应用退出时翻译未完成，可重新发起）'
            : '已中断（应用退出时任务未完成，可重新识别）';
        task._endTime = lastSeen ?? task.startTime;
      }
      return task;
    } catch (_) {
      return null;
    }
  }
}

/// 全局任务管理器单例。
class AiTaskManager extends ChangeNotifier {
  AiTaskManager._();
  static final AiTaskManager instance = AiTaskManager._();

  /// 全部任务记录（含已完成的），不自动清理，由用户手动删除。
  ///
  /// 用列表而不是 Map：同一个视频重新识别会产生新任务，旧记录要保留下来
  /// 供用户在「任务列表」里回看，所以不能按视频路径覆盖。
  final List<AiTask> _tasks = [];

  /// 最多保留多少条历史记录（超出后丢弃最旧的）。
  static const int _maxRecords = 60;

  Timer? _saveTimer;

  /// 任务记录的落盘文件：`%LOCALAPPDATA%\PolyFlixPlayer\ai_tasks.json`。
  ///
  /// 放在应用数据目录（不是 %TEMP% 缓存目录），"清理应用缓存"不会误删记录。
  File _storageFile() {
    final dir = NativeFileHelper.desktopDataDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}ai_tasks.json');
  }

  /// 变更后合并写盘：3 秒内多次改动只写一次。
  ///
  /// 识别过程中进度回调很密集，逐次写 JSON 会白白磨损磁盘。另外对仍在运行的
  /// 任务会写入 lastSeen，应用被强杀时靠它推算出合理的耗时（不会把离线时间算进去）。
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), _save);
  }

  Future<void> _save() async {
    try {
      final from = _tasks.length > _maxRecords
          ? _tasks.length - _maxRecords
          : 0;
      final now = DateTime.now();
      final list = _tasks
          .sublist(from)
          .map((t) => t.toJson(lastSeen: t.isRunning ? now : null))
          .toList();
      await _storageFile().writeAsString(jsonEncode(list));
    } catch (_) {
      // 落盘失败不影响本次使用
    }
  }

  /// 从磁盘恢复历史记录，应用启动时调用一次。
  Future<void> loadPersisted() async {
    try {
      final file = _storageFile();
      if (!file.existsSync()) return;
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      final loaded = <AiTask>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final task = AiTask.fromJson(item);
          if (task != null) {
            task.addListener(_onTaskChanged);
            loaded.add(task);
          }
        }
      }
      if (loaded.isEmpty) return;
      _tasks
        ..clear()
        ..addAll(loaded);
      // 用 super 直接通知：载入本身不需要再安排一次写盘
      super.notifyListeners();
    } catch (_) {
      // 文件损坏时等同于没有历史记录，不影响启动
    }
  }

  void _onTaskChanged() {
    notifyListeners();
  }

  void _addTask(AiTask task) {
    task.addListener(_onTaskChanged);
    _tasks.add(task);
    notifyListeners();
  }

  @override
  void notifyListeners() {
    // 任何变更都安排一次合并写盘，保证异常退出也能留下记录
    _scheduleSave();
    super.notifyListeners();
  }

  /// 所有任务，正在跑的排在最前，其余按开始时间倒序。
  List<AiTask> get allTasks {
    final list = [..._tasks];
    list.sort((a, b) {
      if (a.isRunning != b.isRunning) return a.isRunning ? -1 : 1;
      return b.startTime.compareTo(a.startTime);
    });
    return list;
  }

  /// 所有当前活动中（正在提取或正在识别）的任务。
  List<AiTask> get activeTasks => _tasks.where((t) => t.isRunning).toList();

  /// 是否有处于后台运行中的任务。
  bool get hasActiveTasks => activeTasks.isNotEmpty;

  static bool _isSamePath(String a, String b) {
    if (a == b) return true;
    if (a.toLowerCase() == b.toLowerCase()) return true;
    final normA = a.replaceAll('/', '\\').toLowerCase();
    final normB = b.replaceAll('/', '\\').toLowerCase();
    return normA == normB;
  }

  /// 获取指定视频最近一次的任务（如果存在，兼容本地路径与流地址）。
  ///
  /// 若未指定 [type]，在有正在运行的 ASR 任务时优先返回该 ASR 任务，避免被新起的翻译任务掩盖。
  AiTask? getTask(String videoPath, {AiTaskType? type}) {
    if (type != null) {
      for (final task in _tasks.reversed) {
        if (task.taskType == type &&
            (_isSamePath(task.videoPath, videoPath) ||
                _isSamePath(task.cacheKey, videoPath))) {
          return task;
        }
      }
      return null;
    }

    for (final task in _tasks.reversed) {
      if (task.taskType == AiTaskType.transcription &&
          task.isRunning &&
          (_isSamePath(task.videoPath, videoPath) ||
              _isSamePath(task.cacheKey, videoPath))) {
        return task;
      }
    }

    for (final task in _tasks.reversed) {
      if (_isSamePath(task.videoPath, videoPath) ||
          _isSamePath(task.cacheKey, videoPath)) {
        return task;
      }
    }
    return null;
  }

  /// 获取指定视频最近一次的语音识别任务。
  AiTask? getAsrTask(String videoPath) =>
      getTask(videoPath, type: AiTaskType.transcription);

  /// 为指定视频正在运行的 ASR 任务预约识别完成后自动翻译。
  void scheduleTranslationAfterAsr({
    required String videoPath,
    required String targetLang,
  }) {
    final task = getAsrTask(videoPath);
    if (task != null && task.isRunning) {
      task.pendingTranslationLang = targetLang;
      notifyListeners();
    }
  }

  /// 取消指定视频 ASR 任务的预约翻译。
  void cancelPendingTranslation(String videoPath) {
    final task = getAsrTask(videoPath);
    if (task != null && task.hasPendingTranslation) {
      task.pendingTranslationLang = null;
      notifyListeners();
    }
  }

  /// 获取指定视频最近一次的翻译任务（可按来源类型筛选）。
  AiTask? getTranslationTask(String videoPath, {String? sourceType}) {
    for (final task in _tasks.reversed) {
      if (task.taskType != AiTaskType.translation) continue;
      final match = _isSamePath(task.videoPath, videoPath) ||
          _isSamePath(task.cacheKey, videoPath);
      if (!match) continue;
      if (sourceType != null && task.sourceType != sourceType) continue;
      return task;
    }
    return null;
  }

  /// 指定本地路径的视频是否有音频识别任务。
  bool hasTaskForPath(String path) => getTask(path) != null;

  /// 启动某视频的语音识别任务。
  ///
  /// 同一视频已有任务在跑时直接复用，不会重复开任务。
  Future<AiTask> startTask({
    required String videoPath,
    required String videoTitle,
    required String modelId,
    String language = 'auto',
    String? cacheKey,
  }) async {
    final existing = getTask(videoPath);
    if (existing != null && existing.isRunning && existing.taskType == AiTaskType.transcription) {
      return existing;
    }

    final task = AiTask(
      id: '${DateTime.now().millisecondsSinceEpoch}_${_tasks.length}',
      taskType: AiTaskType.transcription,
      videoPath: videoPath,
      cacheKey: cacheKey,
      videoTitle: videoTitle,
      modelId: modelId,
      language: language,
    );

    _addTask(task);

    // 触发执行
    _runTask(task);
    return task;
  }

  /// 启动字幕翻译任务（在全局后台执行，即使切换页面或返回首页也不中断）。
  Future<AiTask> startTranslationTask({
    required String videoPath,
    required String videoTitle,
    required String targetLang,
    required String sourceType, // 例如 'builtin_0' 或 'asr_medium'
    String? cacheKey,
    List<SubtitleEntry>? rawEntries,
    int? builtinTrackIndex,
  }) async {
    final existing = getTranslationTask(videoPath, sourceType: sourceType);
    if (existing != null && existing.isRunning) return existing;

    final engine = TranslationService.instance.getActiveEngine();
    if (!engine.isConfigured) {
      throw TranslationException(engine.configurationError ?? '未配置翻译服务凭据');
    }
    final task = AiTask(
      id: 'trans_${DateTime.now().millisecondsSinceEpoch}_${_tasks.length}',
      taskType: AiTaskType.translation,
      videoPath: videoPath,
      cacheKey: cacheKey,
      videoTitle: videoTitle,
      modelId: sourceType,
      language: targetLang,
      targetLanguage: targetLang,
      sourceType: sourceType,
      engineId: engine.id,
    );

    _addTask(task);

    _runTranslationTask(
      task: task,
      rawEntries: rawEntries,
      builtinTrackIndex: builtinTrackIndex,
    );
    return task;
  }

  Future<void> _runTranslationTask({
    required AiTask task,
    List<SubtitleEntry>? rawEntries,
    int? builtinTrackIndex,
  }) async {
    final targetLang = task.targetLanguage ?? 'zh-Hans';
    final langName = TranslationLanguage.findByCode(targetLang).name;

    task.updateState(
      AsrState.preparing,
      message: '正在准备待翻译字幕...',
    );

    try {
      List<SubtitleEntry> entries = rawEntries ?? [];
      // 若无传入待翻译条目且为内置字幕，则从内置字幕中提取
      if (entries.isEmpty && builtinTrackIndex != null) {
        task.updateState(
          AsrState.preparing,
          message: '正在从视频提取内置字幕文本...',
        );
        entries = await BuiltInSubtitleExtractor.extractSubtitles(
          videoPath: task.videoPath,
          subtitleIndex: builtinTrackIndex,
        );
      } else if (entries.any((e) => e.translatedText != null)) {
        // 剥离已有翻译，保留纯原文用于新翻译
        entries = entries
            .map((e) => SubtitleEntry(
                  start: e.start,
                  end: e.end,
                  text: e.text,
                ))
            .toList();
      }

      if (task.isCancelled) return;

      if (entries.isEmpty) {
        throw const TranslationException('待翻译字幕内容为空');
      }

      task.updateState(
        AsrState.processing,
        message: '正在翻译为 $langName (0/${entries.length})...',
      );
      task.updateTranslationProgress(0, entries.length);

      final translatedEntries = await TranslationService.instance.translateEntries(
        entries: entries,
        targetLanguage: targetLang,
        contextTitle: task.videoTitle,
        onProgress: (cur, total) {
          if (!task.isCancelled) {
            task.updateTranslationProgress(
              cur,
              total,
              message: '正在翻译为 $langName ($cur/$total)...',
            );
          }
        },
        isCancelled: () => task.isCancelled,
      );

      if (task.isCancelled) return;

      // 持久化翻译结果到磁盘缓存
      await TranslationService.instance.saveTranslationCache(
        sourceKey: task.cacheKey,
        sourceType: task.sourceType ?? 'unknown',
        targetLang: targetLang,
        engineId: task.engineId ?? TranslationService.instance.getActiveEngine().id,
        entries: translatedEntries,
      );

      // 如果当前播放器正好承载着该视频，无缝同步到画面显示
      if (SubtitleGenerator.instance.holdsEntriesFor(task.videoPath)) {
        SubtitleGenerator.instance.setEntries(
          translatedEntries,
          videoPath: task.videoPath,
          markCompleted: true,
        );
      }

      task._entries
        ..clear()
        ..addAll(translatedEntries);
      task.updateState(
        AsrState.completed,
        percent: 1.0,
        message: '已成功翻译为 $langName (共 ${translatedEntries.length} 条)',
      );
    } catch (e) {
      if (!task.isCancelled) {
        task.updateState(
          AsrState.error,
          errorMessage: e.toString(),
          message: '翻译失败: $e',
        );
      }
    } finally {
      notifyListeners();
    }
  }

  /// 取消指定视频的任务（兼容 ASR 与翻译任务）。
  void cancelTask(String videoPath) {
    for (final task in _tasks.reversed) {
      final match = _isSamePath(task.videoPath, videoPath) ||
          _isSamePath(task.cacheKey, videoPath);
      if (match && task.isRunning) {
        task.cancel();
      }
    }
    SubtitleGenerator.instance.cancel();
    notifyListeners();
  }

  /// 删除一条任务记录。
  ///
  /// 正在运行的任务不允许直接删除（会留下跑着的后台任务），返回 false；
  /// 需要先取消，再删除。
  bool removeTask(String taskId) {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index < 0) return false;
    if (_tasks[index].isRunning) return false;
    _tasks.removeAt(index);
    notifyListeners();
    return true;
  }

  /// 清空所有已结束的任务记录。
  void clearFinishedTasks() {
    _tasks.removeWhere((t) => t.isFinished);
    notifyListeners();
  }

  /// 清理指定视频在特定模型下的历史任务记录（重置任务状态，防止 completed 状态死锁）。
  void clearTaskFor(String videoPath, {String? modelId}) {
    final mId = modelId?.toLowerCase();
    _tasks.removeWhere((t) {
      if (!t.isFinished) return false;
      final matchPath = _isSamePath(t.videoPath, videoPath) ||
          _isSamePath(t.cacheKey, videoPath);
      if (!matchPath) return false;
      if (mId != null && mId.isNotEmpty) {
        return t.modelId.toLowerCase() == mId;
      }
      return true;
    });
    notifyListeners();
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
      } else if (task.state == AsrState.error) {
        // 内部已置为错误，保持错误状态，避免被识别完成覆盖
      } else {
        task.updateState(
          AsrState.completed,
          percent: 1.0,
          message: '识别完成 (共 ${task.entries.length} 条字幕)',
        );
        // 保存字幕缓存（按模型区分，仅写高效 JSON 缓存，不自动生成冗余 srt）
        // 用 cacheKey 而不是 videoPath：PFLX 的播放地址带随机端口，不能当身份
        await saveCachedSubtitles(
          task.cacheKey,
          task.entries,
          modelId: task.modelId,
        );

        // 检查是否有预约翻译：若有且任务未取消，在全量 ASR 识别落盘后自动无缝触发全量翻译
        if (task.pendingTranslationLang != null &&
            !task.isCancelled &&
            task.entries.isNotEmpty) {
          final targetLang = task.pendingTranslationLang!;
          task.pendingTranslationLang = null;
          // 异步拉起全量翻译任务
          startTranslationTask(
            videoPath: task.videoPath,
            videoTitle: task.videoTitle,
            targetLang: targetLang,
            sourceType: 'asr_${task.modelId}',
            cacheKey: task.cacheKey,
            rawEntries: task.entries,
          );
        }
      }
    } catch (e) {
      final errorMsg = e is StateError ? e.message : e.toString();
      task.updateState(
        AsrState.error,
        errorMessage: errorMsg,
        message: '识别失败: $errorMsg',
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
          return md5
              .convert([...lenBytes, ...bytes])
              .toString()
              .substring(0, 8);
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
    final direct = File(
      '$dirPath${Platform.pathSeparator}${cleanName}_${mId}_$fingerprint.json',
    );
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
    final pathHash6 = md5
        .convert(utf8.encode(videoPath))
        .toString()
        .substring(0, 6);
    final legacyShort = File(
      '$dirPath${Platform.pathSeparator}${cleanName}_${mId}_$pathHash6.json',
    );
    if (legacyShort.existsSync()) return legacyShort;

    return null;
  }

  /// 获取指定视频已缓存过字幕的模型列表（支持跨目录检测已存在缓存）。
  ///
  /// 遍历**完整**模型清单（tiny ~ large-v3 等 40 多个型号），而不是写死
  /// tiny/base/small：用大模型识别过的缓存同样要能查出来，否则"重开视频自动
  /// 恢复上次的 AI 字幕"会漏掉这些缓存，用户还得手动去面板里翻。
  Future<List<String>> getCachedModelIds(String videoPath) async {
    final dir = NativeFileHelper.desktopSubtitleCacheDir();
    if (!dir.existsSync()) return const [];

    final fingerprint = _getVideoFingerprint(videoPath);
    final cached = <String>[];
    for (final info in availableModels) {
      final f = _findCacheFile(videoPath, info.id, fingerprint, dir.path);
      if (f != null && f.existsSync()) {
        cached.add(info.id);
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
        final targetFile = _findCacheFile(
          videoPath,
          modelId,
          fingerprint,
          dir.path,
        );
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
      final oldHash = md5
          .convert(utf8.encode(videoPath))
          .toString()
          .substring(0, 16);
      final oldFile = File(
        '${dir.path}${Platform.pathSeparator}sub_$oldHash.json',
      );
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
      final mId = (modelId != null && modelId.isNotEmpty)
          ? modelId.toLowerCase()
          : 'default';
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final file = File(
        '${dir.path}${Platform.pathSeparator}${cleanName}_${mId}_$fingerprint.json',
      );
      final jsonList = entries.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (_) {}
  }

  /// 删除指定视频的本地字幕缓存文件（全量扫盘清理主缓存与关联翻译缓存）。
  ///
  /// - 若提供 [modelId]，删除该模型下的主缓存与关联翻译缓存；
  /// - 若 [modelId] 为 null 或为空，彻底清除该视频在所有模型下的字幕缓存与翻译缓存。
  /// 返回实际物理删除的文件数量（大于 0 表示成功删除）。
  Future<int> deleteCachedSubtitles(
    String videoPath, {
    String? modelId,
  }) async {
    int deletedCount = 0;
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) return 0;

      final cleanName = _extractCleanBaseName(videoPath);
      final fingerprint = _getVideoFingerprint(videoPath);
      final pathHash6 = md5
          .convert(utf8.encode(videoPath))
          .toString()
          .substring(0, 6);
      final oldHash16 = md5
          .convert(utf8.encode(videoPath))
          .toString()
          .substring(0, 16);
      final mId = (modelId != null && modelId.isNotEmpty)
          ? modelId.toLowerCase()
          : null;

      final entities = dir.listSync();
      for (final item in entities) {
        if (item is! File || !item.path.endsWith('.json')) continue;
        final name = item.uri.pathSegments.last;

        bool shouldDelete = false;

        if (mId != null) {
          // 1. 指定模型的主字幕缓存
          // 规则 A: 包含同指纹+同模型: _${mId}_${fingerprint}.json
          // 规则 B: 包含同短哈希+同模型: _${mId}_${pathHash6}.json
          // 规则 C: 包含 cleanName+同模型: ${cleanName}_${mId}_
          if (name.contains('_${mId}_$fingerprint.json') ||
              name.contains('_${mId}_$pathHash6.json') ||
              (name.startsWith('${cleanName}_${mId}_') && name.endsWith('.json'))) {
            shouldDelete = true;
          }

          // 2. 指定模型的 ASR 翻译缓存: trans_*_asr_${mId}_*.json
          if (name.startsWith('trans_') && name.contains('_asr_${mId}_')) {
            if (name.contains(cleanName) || name.contains(fingerprint)) {
              shouldDelete = true;
            }
          }
        } else {
          // 未指定模型：清空当前视频所有模型的缓存与翻译缓存
          if (name.contains('_$fingerprint.json') ||
              name.contains('_$pathHash6.json') ||
              name.startsWith('${cleanName}_') ||
              name == 'sub_$oldHash16.json') {
            shouldDelete = true;
          }
          if (name.startsWith('trans_') &&
              (name.contains(cleanName) || name.contains(fingerprint))) {
            shouldDelete = true;
          }
        }

        if (shouldDelete) {
          try {
            await item.delete();
            deletedCount++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return deletedCount;
  }
}
