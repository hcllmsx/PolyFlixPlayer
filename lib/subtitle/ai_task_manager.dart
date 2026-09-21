/// 全局 AI 语音识别任务管理系统。
///
/// 负责跨页面协调后台转录任务、追踪切片进度、持久化字幕缓存，并向首页与播放页广播状态变更。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../settings/app_settings.dart';
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
  final String? sourceType;

  /// 目标语言（翻译任务）。点「重试」时以当时的设置为准，所以可变。
  String? targetLanguage;

  /// 实际使用的翻译引擎 id。同样允许重试时按当时的设置替换，所以可变。
  String? engineId;

  /// 若在 ASR 识别过程中预约了翻译，记录目标语言（如 'zh-Hans'）
  String? pendingTranslationLang;
  bool get hasPendingTranslation => pendingTranslationLang != null;

  /// 仅用于翻译任务：本条翻译跑完后，自动续跑这条 id 对应的识别任务。
  ///
  /// 即用户点过「翻译已有」的完整流程：先翻已识别的一段，剩下的由程序自动补上，
  /// 补完再做一次增量翻译，全程不用人盯。
  String? autoResumeAfterTaskId;

  /// 阶段翻译已完成，正在等待自动续跑剩余部分。
  bool _autoResumeScheduled = false;
  bool get autoResumeScheduled => _autoResumeScheduled;

  /// 是否在中途被叫停（点过「翻译已有」）：已识别部分已落盘，剩余部分可续跑。
  bool _earlyStopped = false;
  bool get isEarlyStopped => _earlyStopped;

  /// 已识别覆盖到的秒数（续跑起点）。
  int _coveredSeconds = 0;
  int get coveredSeconds => _coveredSeconds;

  /// 音频总秒数（用于展示"已识别 47%"）。
  int _audioTotalSeconds = 0;
  int get audioTotalSeconds => _audioTotalSeconds;

  /// 是否请求"当前片段跑完后就停下"（点「翻译已有」后由生成器在分片边界响应）。
  bool _stopRequested = false;
  bool get stopRequested => _stopRequested;

  /// 点下「翻译已有」的时刻，用来在收尾等待期显示"已等 xx 秒"。
  DateTime? _stopRequestedAt;
  Duration get stopRequestedElapsed =>
      _stopRequestedAt == null ? Duration.zero : DateTime.now().difference(_stopRequestedAt!);

  /// 续跑起点（秒）。0 表示从头识别。
  int get resumeFromSeconds => _earlyStopped ? _coveredSeconds : 0;

  /// 处于"已停止识别、剩余部分可继续"的状态。
  bool get canResume =>
      _earlyStopped &&
      !isRunning &&
      !_isCancelled &&
      _state != AsrState.completed &&
      _state != AsrState.error;

  /// 翻译记录已被后续翻译覆盖（产物已被同名缓存取代，列表里标灰保留）。
  bool _superseded = false;
  bool get isSuperseded => _superseded;

  /// 已识别的百分比（0~1），仅提前停止时有意义。
  double get coveredRatio => _audioTotalSeconds > 0
      ? (_coveredSeconds / _audioTotalSeconds).clamp(0.0, 1.0)
      : 0.0;

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
  /// 识别语言（ASR 用）；翻译任务这里存的是目标语言，仅用于展示与落盘。
  ///
  /// 重试翻译时目标语言可能更换，所以不能是 final。
  String language;
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

  /// 翻译任务专用的"待翻译原文"快照（纯原文，不含译文）。
  ///
  /// 留这份是为了「重试」：翻译成功后 `_entries` 装的是译文，原文就没了；失败时
  /// `_entries` 又是空的。只有留住原文，改好 Key 之后才能原样再跑一遍。
  /// 与 `_entries` 一样只在内存里，不落盘，重启后从缓存/内置字幕重新取。
  List<SubtitleEntry> _translationSource = const [];
  List<SubtitleEntry> get translationSource =>
      List.unmodifiable(_translationSource);

  /// 记下本次翻译的原文，供失败或取消后「重试」复用。
  void cacheTranslationSource(List<SubtitleEntry> source) {
    _translationSource = List.of(source);
  }

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
    _autoResumeScheduled = false;
    _stopRequested = false;
    _stopRequestedAt = null;
    _state = AsrState.idle;
    _statusMessage = '已取消';
    _endTime ??= DateTime.now();
    notifyListeners();
  }

  /// 标记为"阶段翻译已完成，稍后自动续跑剩余识别"（识别任务侧的状态提示）。
  void markAutoResumeScheduled() {
    _autoResumeScheduled = true;
    _statusMessage = '阶段任务已完成，稍后自动开始未完成的任务';
    notifyListeners();
  }

  /// 点「翻译已有」：请求在当前片段跑完后停下，随后立刻拿已识别部分去翻译。
  ///
  /// 识别是一段一段推进的，中途硬停会丢掉正在处理的那一小段，所以这里不立刻停，
  /// 而是等当前这段自然跑完再停（最长约一分钟）。等待期要有明确反馈，否则用户
  /// 会以为按钮没点中。
  void requestStopForTranslation() {
    if (_stopRequested) return;
    _stopRequested = true;
    _stopRequestedAt = DateTime.now();
    _statusMessage = '已收到，正在收尾：识别是一段一段跑的，中途打断会丢内容，'
        '所以等当前这一段跑完就停（最长约 1 分钟），'
        '然后立刻翻译已识别的 $entryCount 条字幕，剩余部分之后自动继续。';
    notifyListeners();
  }

  /// 提前停止完成：记录断点，进入"可继续"状态。
  void markEarlyStopped({required int coveredSeconds, required int totalSeconds}) {
    _earlyStopped = true;
    _stopRequested = false;
    _stopRequestedAt = null;
    _autoResumeScheduled = false;
    _coveredSeconds = coveredSeconds;
    _audioTotalSeconds = totalSeconds;
    _state = AsrState.idle;
    final total = Duration(seconds: totalSeconds);
    final done = Duration(seconds: coveredSeconds);
    _statusMessage = '已暂停识别：已识别 ${(coveredRatio * 100).toStringAsFixed(0)}%'
        '（${AiTask.formatDuration(done)} / ${AiTask.formatDuration(total)}，共 $entryCount 条字幕）。'
        '剩余部分将在翻译完成后自动继续，也可点「继续识别」立即开始。';
    _endTime ??= DateTime.now();
    notifyListeners();
  }

  /// 准备续跑：清掉终态标记，保留已识别的条目，从断点继续。
  void prepareResume() {
    _isCancelled = false;
    _stopRequested = false;
    _stopRequestedAt = null;
    _autoResumeScheduled = false;
    _state = AsrState.preparing;
    _endTime = null;
    _statusMessage = '正在从 ${AiTask.formatDuration(Duration(seconds: _coveredSeconds))} 处继续识别…';
    notifyListeners();
  }

  /// 点「重试」：用当前设置（可能刚改过目标语言 / 翻译引擎）覆盖本条翻译任务。
  void applyTranslationTargets({
    required String targetLang,
    String? engine,
  }) {
    targetLanguage = targetLang;
    language = targetLang;
    if (engine != null) engineId = engine;
  }

  /// 点「重试」：抹掉上一次的取消 / 中断 / 失败痕迹，回到"进行中"。
  ///
  /// 不复用 `prepareResume()`（那是识别续跑专用的，会顺带清覆盖秒数）。
  void prepareRetry() {
    _isCancelled = false;
    _interrupted = false;
    _errorMessage = null;
    _percent = 0.0;
    _completedUnits = 0;
    _totalUnits = 0;
    _endTime = null;
    _state = AsrState.preparing;
    _statusMessage = '正在重新发起翻译...';
    notifyListeners();
  }

  /// 全部音频都已识别完（续跑跑完或首次跑完）：清除断点状态。
  void markFullyRecognized() {
    _earlyStopped = false;
    _stopRequested = false;
    _coveredSeconds = 0;
    _audioTotalSeconds = 0;
  }

  /// 标记为"已被后续翻译取代"（列表里标灰保留，不再代表当前缓存内容）。
  void markSuperseded() {
    if (_superseded) return;
    _superseded = true;
    notifyListeners();
  }

  /// 用去重合并后的结果替换内存中的字幕条目（续跑接缝去重时用）。
  void replaceEntries(List<SubtitleEntry> merged) {
    _entries
      ..clear()
      ..addAll(merged);
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
    'earlyStopped': _earlyStopped,
    'coveredSeconds': _coveredSeconds,
    'audioTotalSeconds': _audioTotalSeconds,
    'superseded': _superseded,
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
      task._earlyStopped = (json['earlyStopped'] as bool?) ?? false;
      task._coveredSeconds = (json['coveredSeconds'] as num?)?.toInt() ?? 0;
      task._audioTotalSeconds = (json['audioTotalSeconds'] as num?)?.toInt() ?? 0;
      task._superseded = (json['superseded'] as bool?) ?? false;
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

  /// 获取指定视频**正在运行**的任务（语音识别或字幕翻译均计入）。
  ///
  /// 只看真正还在跑的任务：已完成 / 失败 / 取消 / 中断的历史记录留在任务列表里
  /// 供回看，不应该再影响播放列表的增删。
  AiTask? getRunningTask(String videoPath) {
    for (final task in _tasks.reversed) {
      if (!task.isRunning) continue;
      if (_isSamePath(task.videoPath, videoPath) ||
          _isSamePath(task.cacheKey, videoPath)) {
        return task;
      }
    }
    return null;
  }

  /// 指定路径的视频是否还有**正在运行**的任务。
  bool hasRunningTaskForPath(String path) => getRunningTask(path) != null;

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
  ///
  /// [incremental] 为 true 时做增量翻译：先读回已有的译文缓存，原文相同的条目
  /// 直接复用旧译文，只把新增的条目送去翻译引擎，最后整体覆盖回同一个缓存文件。
  /// [supersedeExisting] 为 true 时，把同来源同语言的旧翻译记录标灰（产物已被覆盖）。
  Future<AiTask> startTranslationTask({
    required String videoPath,
    required String videoTitle,
    required String targetLang,
    required String sourceType, // 例如 'builtin_0' 或 'asr_medium'
    String? cacheKey,
    List<SubtitleEntry>? rawEntries,
    int? builtinTrackIndex,
    bool incremental = false,
    bool supersedeExisting = false,
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

    if (supersedeExisting) {
      for (final old in _tasks) {
        if (old.taskType != AiTaskType.translation) continue;
        if (old.sourceType != task.sourceType) continue;
        if (old.targetLanguage != task.targetLanguage) continue;
        if (!_isSamePath(old.videoPath, videoPath) &&
            !_isSamePath(old.cacheKey, videoPath)) {
          continue;
        }
        old.markSuperseded();
      }
    }

    _addTask(task);

    _runTranslationTask(
      task: task,
      rawEntries: rawEntries,
      builtinTrackIndex: builtinTrackIndex,
      incremental: incremental,
    );
    return task;
  }

  /// 重试一条失败 / 被取消的翻译任务。
  ///
  /// 典型场景：翻译服务的 Key 填错 → 任务报失败 → 去设置页改好 Key，顺手换个目标
  /// 语言 → 回到任务列表点「重试」。所以这里刻意**重新读一次当前设置**：目标语言
  /// 和翻译引擎都以"点重试那一刻"的值为准，而不是沿用上次失败时的旧值。
  ///
  /// 重试用的还是同一批原文字幕（任务自己记着），已经翻好的条目按原文复用，
  /// 不会重复消耗翻译额度。
  ///
  /// 引擎未配置、或原文已经找不回来时抛 [TranslationException]。
  Future<AiTask> retryTranslationTask(AiTask task) async {
    if (task.taskType != AiTaskType.translation) {
      throw const TranslationException('只有翻译任务支持重试');
    }
    if (task.isRunning) return task;

    final engine = TranslationService.instance.getActiveEngine();
    if (!engine.isConfigured) {
      throw TranslationException(
          engine.configurationError ?? '未配置翻译服务凭据');
    }

    var entries = task.translationSource;
    if (entries.isEmpty) {
      // 应用重启过：内存里的原文快照没了，按来源把它找回来
      try {
        entries = await _resolveTranslationSource(task);
      } catch (_) {
        entries = const <SubtitleEntry>[];
      }
    }
    if (entries.isEmpty) {
      throw const TranslationException(
          '找不到原字幕（缓存已被删除或视频不在了），请重新识别后再翻译');
    }

    final oldLang = task.targetLanguage;
    final newLang = aiTranslationTargetLang.value;
    task.applyTranslationTargets(targetLang: newLang, engine: engine.id);

    // 「翻译已有」的闭环：预约语言也得跟着改，否则后续那段会被翻回旧语言
    final resumeId = task.autoResumeAfterTaskId;
    if (resumeId != null) {
      for (final t in _tasks) {
        if (t.id == resumeId) {
          t.pendingTranslationLang = newLang;
          break;
        }
      }
    }

    task.prepareRetry();
    notifyListeners();

    final langName = TranslationLanguage.findByCode(newLang).name;
    if (oldLang != null && oldLang != newLang) {
      final oldName = TranslationLanguage.findByCode(oldLang).name;
      onInfo?.call(
        '已改用新设置重试翻译：$oldName → $langName',
        duration: const Duration(seconds: 6),
      );
    } else {
      onInfo?.call('已重新发起翻译（目标语言：$langName）');
    }

    _runTranslationTask(
      task: task,
      rawEntries: entries,
      incremental: true,
    );
    return task;
  }

  /// 重试时把原字幕找回来：识别字幕读缓存，内置字幕重新从视频里提取。
  Future<List<SubtitleEntry>> _resolveTranslationSource(AiTask task) async {
    final src = task.sourceType ?? '';
    if (src.startsWith('builtin_')) {
      final idx = int.tryParse(src.substring('builtin_'.length));
      if (idx == null) return const <SubtitleEntry>[];
      return BuiltInSubtitleExtractor.extractSubtitles(
        videoPath: task.videoPath,
        subtitleIndex: idx,
      );
    }
    if (src.startsWith('asr_')) {
      final modelId = src.substring('asr_'.length);
      return (await loadCachedSubtitles(task.cacheKey, modelId: modelId)) ??
          const <SubtitleEntry>[];
    }
    return const <SubtitleEntry>[];
  }

  Future<void> _runTranslationTask({
    required AiTask task,
    List<SubtitleEntry>? rawEntries,
    int? builtinTrackIndex,
    bool incremental = false,
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
      // 留住纯原文，失败 / 取消后「重试」要用（此刻 entries 已剥离过译文）
      task.cacheTranslationSource(entries);

      // 增量翻译：读回已有译文缓存，原文相同的条目直接复用，只把新增的送去翻译
      final reuseMap = <String, String>{};
      if (incremental) {
        final cached = await TranslationService.instance.loadTranslationCache(
          sourceKey: task.cacheKey,
          sourceType: task.sourceType ?? 'unknown',
          targetLang: targetLang,
          engineId:
              task.engineId ?? TranslationService.instance.getActiveEngine().id,
        );
        for (final e in cached ?? const <SubtitleEntry>[]) {
          final t = e.translatedText;
          if (t == null || t.isEmpty) continue;
          reuseMap.putIfAbsent(_normalizeForMatch(e.text), () => t);
        }
      }

      final pending = reuseMap.isEmpty
          ? entries
          : entries
              .where((e) => !reuseMap.containsKey(_normalizeForMatch(e.text)))
              .toList();
      final reusedCount = entries.length - pending.length;

      task.updateState(
        AsrState.processing,
        message: reusedCount > 0
            ? '正在翻译为 $langName (复用已译 $reusedCount 条，待翻 ${pending.length} 条)...'
            : '正在翻译为 $langName (0/${entries.length})...',
      );
      task.updateTranslationProgress(0, pending.length);

      final fresh = pending.isEmpty
          ? const <SubtitleEntry>[]
          : await TranslationService.instance.translateEntries(
              entries: pending,
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

      // 按顺序回填：复用的走 reuseMap，新翻的按顺序取（translateEntries 保持输入顺序）
      final translatedEntries = <SubtitleEntry>[];
      var freshIndex = 0;
      for (final e in entries) {
        final reused = reuseMap[_normalizeForMatch(e.text)];
        String? translated;
        if (reused != null) {
          translated = reused;
        } else if (freshIndex < fresh.length) {
          translated = fresh[freshIndex++].translatedText;
        }
        translatedEntries.add(SubtitleEntry(
          start: e.start,
          end: e.end,
          text: e.text,
          translatedText: translated,
        ));
      }

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
        message: reusedCount > 0
            ? '已成功翻译为 $langName (共 ${translatedEntries.length} 条，其中复用已译 $reusedCount 条)'
            : '已成功翻译为 $langName (共 ${translatedEntries.length} 条)',
      );

      // 阶段翻译完成：自动把剩下的识别续跑起来，跑完再做一次增量翻译
      final resumeId = task.autoResumeAfterTaskId;
      if (resumeId != null) {
        task.autoResumeAfterTaskId = null;
        try {
          await _scheduleAutoResume(resumeId);
        } catch (_) {
          // 续跑拉不起来不该把已经成功的翻译打成错误态
        }
      }
    } catch (e) {
      if (!task.isCancelled) {
        task.updateState(
          AsrState.error,
          errorMessage: e.toString(),
          message: _translationFailureMessage(e),
        );
      }
    } finally {
      notifyListeners();
    }
  }

  /// 翻译失败的展示文案。
  ///
  /// 纯粹的报错原文用户看不懂也不知道接下来干嘛，所以凭据类问题（Key 没填、
  /// 填错、过期、额度用尽）直接告诉他去哪儿改 + 改完点「重试」就行。
  /// [errorMessage] 里仍保留原始异常，方便排查。
  String _translationFailureMessage(Object e) {
    final raw = e.toString();
    const credentialHints = [
      '未配置',
      '凭据',
      'Key',
      '401',
      '403',
      '54003', // 百度：访问频率受限 / 鉴权失败
      '52003', // 百度：未授权用户或无效参数
      'Auth',
      'auth',
    ];
    for (final hint in credentialHints) {
      if (raw.contains(hint)) {
        return '翻译失败: $e\n翻译服务的 Key 可能没填或不对：'
            '到「设置 → 翻译服务」改好后，点这条任务的「重试」即可';
      }
    }
    return '翻译失败: $e';
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
  ///
  /// 两种收尾：
  ///  - 跑完全程（[ChunkedTranscribeResult.stoppedEarly] 为 false）；
  ///  - 被「翻译已有」在分片边界叫停（为 true）：已识别部分照常落盘并立刻送去翻译，
  ///    任务转为"可继续"状态，之后可从断点把剩余部分补上。
  Future<void> _runTask(AiTask task) async {
    try {
      final result = await SubtitleGenerator.instance.transcribeVideoChunked(
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
        isStopRequested: () => task.stopRequested,
        startSeconds: task.resumeFromSeconds,
      );

      if (task.isCancelled) {
        task.updateState(AsrState.idle, message: '任务已取消');
      } else if (task.state == AsrState.error) {
        // 内部已置为错误，保持错误状态，避免被识别完成覆盖
      } else if (result.stoppedEarly &&
          result.coveredSeconds < result.totalSeconds) {
        await _stopEarlyAndTranslate(task, result);
      } else {
        await _finishRecognition(task);
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

  /// 提前停止收尾：保存已识别部分 → 落盘断点 → 立刻拿已识别的部分去翻译。
  ///
  /// 写的是**同一个**字幕缓存文件（不加后缀），续跑完成后再覆盖一次，
  /// 所以整个视频始终只有一份字幕、一份译文，字幕管理也只需删一次。
  Future<void> _stopEarlyAndTranslate(
    AiTask task,
    ChunkedTranscribeResult result,
  ) async {
    task.markEarlyStopped(
      coveredSeconds: result.coveredSeconds,
      totalSeconds: result.totalSeconds,
    );
    await saveCachedSubtitles(task.cacheKey, task.entries, modelId: task.modelId);
    await _saveAsrProgress(task);

    // 沿用已预约的语言；没预约过就用设置里的默认目标语言。
    // 这里**不清空**预约：续跑跑完剩余部分后，还要靠它自动拉起增量翻译。
    final targetLang = task.pendingTranslationLang ?? aiTranslationTargetLang.value;
    task.pendingTranslationLang = targetLang;

    if (task.entries.isNotEmpty) {
      try {
        // 记下"这条翻译跑完就自动续跑本任务"，形成
        // 识别一段 → 翻译一段 → 自动续跑 → 增量翻译 的完整闭环
        final translationTask = await startTranslationTask(
          videoPath: task.videoPath,
          videoTitle: task.videoTitle,
          targetLang: targetLang,
          sourceType: 'asr_${task.modelId}',
          cacheKey: task.cacheKey,
          rawEntries: task.entries,
          supersedeExisting: true,
        );
        translationTask.autoResumeAfterTaskId = task.id;
      } catch (_) {
        // 翻译拉不起来（几率极低：引擎配置在按钮点击时已校验过）
        // 不该把"已停止识别"的任务打成错误态，用户仍可手动续跑
      }
    }
    notifyListeners();
  }

  /// 识别跑完全程的收尾：落盘 + 触发（增量）翻译。
  Future<void> _finishRecognition(AiTask task) async {
    final wasResumed = task.isEarlyStopped;
    if (wasResumed) {
      // 续跑：追加式合并，接缝处去掉重复的那一条
      final merged = mergeWithSeamDedupe(task.entries);
      if (merged.length != task.entries.length) {
        task.replaceEntries(merged);
      }
    }
    task.markFullyRecognized();
    await _clearAsrProgress(task);

    task.updateState(
      AsrState.completed,
      percent: 1.0,
      message: '识别完成 (共 ${task.entries.length} 条字幕)',
    );
    // 保存字幕缓存（按模型区分，仅写高效 JSON 缓存，不自动生成冗余 srt）
    // 用 cacheKey 而不是 videoPath：PFLX 的播放地址带随机端口，不能当身份
    await saveCachedSubtitles(task.cacheKey, task.entries, modelId: task.modelId);

    // 检查是否有预约翻译：若有且任务未取消，在全量 ASR 识别落盘后自动无缝触发翻译
    if (task.pendingTranslationLang != null &&
        !task.isCancelled &&
        task.entries.isNotEmpty) {
      final targetLang = task.pendingTranslationLang!;
      task.pendingTranslationLang = null;
      // 续跑完成的走增量翻译：已译过的条目按原文复用，只翻新增部分
      startTranslationTask(
        videoPath: task.videoPath,
        videoTitle: task.videoTitle,
        targetLang: targetLang,
        sourceType: 'asr_${task.modelId}',
        cacheKey: task.cacheKey,
        rawEntries: task.entries,
        incremental: wasResumed,
        supersedeExisting: wasResumed,
      );
    }
  }

  /// 需要弹给用户的提示（如"阶段任务已完成，稍后自动开始未完成的任务"）。
  ///
  /// 任务是在后台跑的，跑到哪一步用户不一定盯着任务列表，所以既写进任务状态，
  /// 也允许 UI 层注册这里弹一条浮层提示；[duration] 用于让长提示多留一会儿。
  void Function(String message, {Duration? duration})? onInfo;

  /// 让正在运行的识别任务在当前片段跑完后停下，并立刻用已识别的部分发起翻译。
  ///
  /// 翻译服务未配置时抛 [TranslationException]，由调用方提示用户。
  /// 短音频（≤120 秒）是整体一次性识别，中途停不下来，UI 层不会给出该按钮。
  void requestTranslateExisting(AiTask task) {
    if (task.taskType != AiTaskType.transcription || !task.isRunning) return;
    final engine = TranslationService.instance.getActiveEngine();
    if (!engine.isConfigured) {
      throw TranslationException(engine.configurationError ?? '未配置翻译服务凭据');
    }
    task.requestStopForTranslation();
    // 收尾最长要等约一分钟，这里必须立刻给反馈，否则像没点中
    onInfo?.call(
      '已收到：识别是一段一段跑的，等当前这一段跑完就停（最长约 1 分钟），'
      '然后立刻翻译已识别的 ${task.entryCount} 条字幕，剩余部分之后自动继续。',
      duration: const Duration(seconds: 8),
    );
    notifyListeners();
  }

  /// 阶段翻译完成后自动续跑剩余识别。
  ///
  /// 先给识别任务挂上"稍后自动开始"的提示并弹一条浮层，留几秒缓冲：
  /// 一是让用户看清提示，二是等翻译的收尾 I/O 落盘，三是这段时间内用户
  /// 想立即开始可以直接点「继续识别」（点过就不会重复启动）。
  Future<void> _scheduleAutoResume(String asrTaskId) async {
    AiTask? asrTask;
    for (final t in _tasks) {
      if (t.id == asrTaskId) {
        asrTask = t;
        break;
      }
    }
    if (asrTask == null || !asrTask.canResume) return;

    asrTask.markAutoResumeScheduled();
    notifyListeners();
    onInfo?.call(
      '阶段任务已完成，稍后自动开始未完成的任务',
      duration: const Duration(seconds: 8),
    );

    await Future.delayed(const Duration(seconds: 5));
    // 期间用户可能手动点了「继续识别」或取消了，这里再确认一次
    if (!asrTask.canResume) return;
    await resumeTask(asrTask);
  }

  /// 续跑：从上次停止的时间点把剩余部分识别完。
  ///
  /// 完成后会做接缝去重并覆盖同一个字幕缓存；若该任务预约过翻译，
  /// 则只翻译新增的条目（已译过的按原文复用）。
  Future<AiTask?> resumeTask(AiTask task) async {
    if (!task.canResume) return null;
    // 应用重启后内存里的条目已丢失（历史记录只存条数），
    // 这里先把缓存里的前半段读回来，否则续跑会把前半段覆盖掉。
    if (task.entries.isEmpty) {
      final cached =
          await loadCachedSubtitles(task.cacheKey, modelId: task.modelId);
      if (cached != null && cached.isNotEmpty) {
        task.addEntries(cached);
      }
    }
    task.prepareResume();
    notifyListeners();
    _runTask(task);
    return task;
  }

  /// 断点进度文件：与主字幕缓存同名 + `.progress.json`，
  /// 清理字幕缓存时会被一并删掉（deleteCachedSubtitles 按前缀匹配 .json）。
  File _progressFile(AiTask task) {
    final dir = NativeFileHelper.desktopSubtitleCacheDir();
    final cleanName = _extractCleanBaseName(task.cacheKey);
    final fingerprint = _getVideoFingerprint(task.cacheKey);
    final mId = task.modelId.isEmpty ? 'default' : task.modelId.toLowerCase();
    return File(
      '${dir.path}${Platform.pathSeparator}${cleanName}_${mId}_$fingerprint.progress.json',
    );
  }

  Future<void> _saveAsrProgress(AiTask task) async {
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await _progressFile(task).writeAsString(jsonEncode({
        'coveredSeconds': task.coveredSeconds,
        'totalSeconds': task.audioTotalSeconds,
        'modelId': task.modelId,
        'updatedAt': DateTime.now().toIso8601String(),
      }));
    } catch (_) {}
  }

  Future<void> _clearAsrProgress(AiTask task) async {
    try {
      final file = _progressFile(task);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 追加式合并的接缝去重：删掉跨批次重复的那一条。
  ///
  /// 续跑时新片段的开头可能与上一段的结尾是同一句话（Whisper 的分片边界句），
  /// 时间上重叠且文本高度相似时保留更早那条（上下文更完整）。
  static List<SubtitleEntry> mergeWithSeamDedupe(List<SubtitleEntry> source) {
    final sorted = [...source]..sort((a, b) => a.start.compareTo(b.start));
    final out = <SubtitleEntry>[];
    for (final e in sorted) {
      if (out.isNotEmpty && _isSeamDuplicate(out.last, e)) continue;
      out.add(e);
    }
    return out;
  }

  static bool _isSeamDuplicate(SubtitleEntry prev, SubtitleEntry next) {
    final a = _normalizeForMatch(prev.text);
    final b = _normalizeForMatch(next.text);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    // 时间不重叠：视为两句不同的话，不处理
    if (next.start >= prev.end) return false;
    return _textSimilarity(a, b) >= 0.7;
  }

  /// 归一化文本，用于"原文是否相同"的匹配（忽略标点与空白差异）。
  static String _normalizeForMatch(String text) =>
      text.replaceAll(RegExp(r'[\s，。！？、,.!?;；:："“”‘’\)\(]'), '');

  /// 简易文本相似度（字符二元组 Dice 系数），用于判断接缝重复。
  static double _textSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.length < 2 || b.length < 2) return 0.0;
    final gramsA = <String, int>{};
    for (int i = 0; i < a.length - 1; i++) {
      final g = a.substring(i, i + 2);
      gramsA[g] = (gramsA[g] ?? 0) + 1;
    }
    var hits = 0;
    for (int i = 0; i < b.length - 1; i++) {
      final g = b.substring(i, i + 2);
      final n = gramsA[g] ?? 0;
      if (n > 0) {
        gramsA[g] = n - 1;
        hits++;
      }
    }
    return (2 * hits) / ((a.length - 1) + (b.length - 1));
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

  /// 缓存文件归属判定结果：不属于本视频 / 主字幕缓存 / 翻译缓存。
  static const int _cacheKindNone = 0;
  static const int _cacheKindSubtitle = 1;
  static const int _cacheKindTranslation = 2;

  /// 判定一个缓存文件名是否属于待清理目标（与 [deleteCachedSubtitles] 同一套规则）。
  ///
  /// 抽出来是为了让"删除"与"删除前统计数量"共用规则，避免两处各写一份、
  /// 久而久之对不上（弹窗报 2 份、实际删 3 份这种）。
  static int _classifyCacheFile(
    String name, {
    required String cleanName,
    required String fingerprint,
    required String pathHash6,
    required String oldHash16,
    String? mId,
  }) {
    if (mId != null) {
      // 指定模型的主字幕缓存
      // 规则 A: 包含同指纹+同模型: _${mId}_${fingerprint}.json
      // 规则 B: 包含同短哈希+同模型: _${mId}_${pathHash6}.json
      // 规则 C: 包含 cleanName+同模型: ${cleanName}_${mId}_
      if (name.contains('_${mId}_$fingerprint.json') ||
          name.contains('_${mId}_$pathHash6.json') ||
          (name.startsWith('${cleanName}_${mId}_') && name.endsWith('.json'))) {
        return _cacheKindSubtitle;
      }
      // 该模型识别字幕衍生出的翻译缓存: trans_*_asr_${mId}_*.json
      if (name.startsWith('trans_') &&
          name.contains('_asr_${mId}_') &&
          (name.contains(cleanName) || name.contains(fingerprint))) {
        return _cacheKindTranslation;
      }
      return _cacheKindNone;
    }

    // 未指定模型：该视频所有模型的缓存与翻译缓存
    if (name.contains('_$fingerprint.json') ||
        name.contains('_$pathHash6.json') ||
        name.startsWith('${cleanName}_') ||
        name == 'sub_$oldHash16.json') {
      return _cacheKindSubtitle;
    }
    if (name.startsWith('trans_') &&
        (name.contains(cleanName) || name.contains(fingerprint))) {
      return _cacheKindTranslation;
    }
    return _cacheKindNone;
  }

  /// 统计"删除字幕缓存"会波及的文件数：主字幕缓存 [subtitle] 份、翻译缓存
  /// [translation] 份。供确认弹窗把话说清楚（翻译是跟着原字幕一起没的）。
  Future<({int subtitle, int translation})> countCachedFiles(
    String videoPath, {
    String? modelId,
  }) async {
    var subtitle = 0;
    var translation = 0;
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) return (subtitle: subtitle, translation: translation);

      final cleanName = _extractCleanBaseName(videoPath);
      final fingerprint = _getVideoFingerprint(videoPath);
      final pathHash6 = md5.convert(utf8.encode(videoPath)).toString().substring(0, 6);
      final oldHash16 = md5.convert(utf8.encode(videoPath)).toString().substring(0, 16);
      final mId = (modelId != null && modelId.isNotEmpty)
          ? modelId.toLowerCase()
          : null;

      for (final item in dir.listSync()) {
        if (item is! File || !item.path.endsWith('.json')) continue;
        final name = item.uri.pathSegments.last;
        switch (_classifyCacheFile(
          name,
          cleanName: cleanName,
          fingerprint: fingerprint,
          pathHash6: pathHash6,
          oldHash16: oldHash16,
          mId: mId,
        )) {
          case _cacheKindSubtitle:
            subtitle++;
          case _cacheKindTranslation:
            translation++;
          default:
            break;
        }
      }
    } catch (_) {}
    return (subtitle: subtitle, translation: translation);
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

        final kind = _classifyCacheFile(
          name,
          cleanName: cleanName,
          fingerprint: fingerprint,
          pathHash6: pathHash6,
          oldHash16: oldHash16,
          mId: mId,
        );
        if (kind == _cacheKindNone) continue;

        try {
          await item.delete();
          deletedCount++;
        } catch (_) {}
      }
    } catch (_) {}
    return deletedCount;
  }
}
