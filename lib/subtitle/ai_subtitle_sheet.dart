import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'ai_task_manager.dart';
import '../main.dart';
import '../settings/app_settings.dart';
import '../utils/app_toast.dart';
import 'device_capability.dart';
import 'engine_pack.dart';
import 'model_catalog_sheet.dart';
import 'model_manager.dart';
import 'subtitle_generator.dart';
import 'translation/builtin_subtitle_extractor.dart';
import 'translation/srt_parser.dart';
import 'translation/translation_engine.dart';
import 'translation/translation_service.dart';

/// AI 语音识别与字幕翻译控制面板。
///
/// 支持配置识别模型、源语言选择、视频内置字幕提取、目标语言翻译及双语字幕导出。
class AiSubtitleSheet extends StatefulWidget {
  const AiSubtitleSheet({
    super.key,
    required this.videoPath,
    this.videoTitle,
    this.cacheKey,
    required this.isAiSubtitleActive,
    required this.onToggleSubtitleActive,
    this.onSeekTo,
    this.subtitleTracks,
    this.activeSubtitleId,
  });

  /// 当前视频源路径（本地文件或 PFLX 流式地址），用于提取音频或字幕。
  final String videoPath;

  /// 字幕缓存的稳定身份键（本地文件路径 / .pflx 文件路径）。
  final String? cacheKey;

  /// 视频标题（可选，用于任务展示）。
  final String? videoTitle;

  /// 画面上 AI 字幕叠加层是否处于激活显示状态。
  final bool isAiSubtitleActive;

  /// 切换画面字幕显示的开关回调。
  final ValueChanged<bool> onToggleSubtitleActive;

  /// 点击字幕跳转播放进度的回调（可选）。
  final ValueChanged<Duration>? onSeekTo;

  /// 视频内置的字幕轨列表（用于内置字幕翻译）。
  final List<SubtitleTrack>? subtitleTracks;

  /// 当前激活的内置字幕轨 ID。
  final String? activeSubtitleId;

  /// 弹出展示面板的标准便捷方法。
  static Future<void> show({
    required BuildContext context,
    required String videoPath,
    String? videoTitle,
    String? cacheKey,
    required bool isAiSubtitleActive,
    required ValueChanged<bool> onToggleSubtitleActive,
    ValueChanged<Duration>? onSeekTo,
    List<SubtitleTrack>? subtitleTracks,
    String? activeSubtitleId,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) => AiSubtitleSheet(
        videoPath: videoPath,
        videoTitle: videoTitle,
        cacheKey: cacheKey,
        isAiSubtitleActive: isAiSubtitleActive,
        onToggleSubtitleActive: onToggleSubtitleActive,
        onSeekTo: onSeekTo,
        subtitleTracks: subtitleTracks,
        activeSubtitleId: activeSubtitleId,
      ),
    );
  }

  @override
  State<AiSubtitleSheet> createState() => _AiSubtitleSheetState();
}

class _AiSubtitleSheetState extends State<AiSubtitleSheet> {
  final SubtitleGenerator _generator = SubtitleGenerator.instance;
  StreamSubscription<AsrProgress>? _progressSub;

  /// 字幕缓存读写统一走这个键。
  ///
  /// PFLX 时它是 .pflx 文件路径（稳定），而 [AiSubtitleSheet.videoPath] 是
  /// 带随机端口的本次会话流地址 —— 拿后者当缓存键就再也找不到上次的缓存。
  String get _cacheKey => widget.cacheKey ?? widget.videoPath;

  String _selectedModel = aiAsrModelId.value;
  String _selectedLanguage = 'auto';
  late bool _isAiSubtitleActive;
  bool _previewExpanded = false;
  Map<String, bool> _modelAvailability = {
    'tiny': false,
    'base': false,
    'small': false,
  };
  bool _checkingModels = true;
  String? _statusMessage;
  AsrState _currentState = AsrState.idle;
  Set<String> _cachedModels = {};

  // 翻译与内置字幕提取状态
  bool _isTranslating = false;
  int _translatedCount = 0;
  int _totalTranslateCount = 0;
  bool _cancelTranslation = false;
  String _selectedSource = 'asr'; // 'asr' 或 'builtin'
  int _selectedBuiltinTrackIndex = 0;

  bool get _hasAnyTranslation =>
      _currentDisplayEntries.any((e) => e.translatedText != null && e.translatedText!.isNotEmpty);

  /// 本地面板自身维护的当前视频字幕缓存列表，防止被后台其他视频的识别任务污染。
  List<SubtitleEntry> _localEntries = [];

  /// 获取当前面板应展示的字幕条目列表（严格限定当前视频）。
  List<SubtitleEntry> get _currentDisplayEntries {
    final task = AiTaskManager.instance.getTask(widget.videoPath);
    if (task != null && task.isRunning) {
      return task.entries;
    }
    if (_localEntries.isNotEmpty) {
      return _localEntries;
    }
    if (_generator.holdsEntriesFor(widget.videoPath)) {
      return _generator.entries;
    }
    return const <SubtitleEntry>[];
  }

  /// 设备能力检测结果；为 null 表示还在检测中。
  ///
  /// 明确不做降级兼容：不满足最低要求（内存 / 核数）的设备直接提示"不支持"，
  /// 不为老旧低端设备投入适配成本。
  DeviceCapabilities? _deviceCaps;

  /// 预探测到的识别引擎名称（引擎包 / 内置 CPU）。
  String? _engineLabel;

  final List<Map<String, String>> _languageOptions = const [
    {'code': 'auto', 'label': '自动侦测（原音频语言）'},
    {'code': 'zh', 'label': '中文 (Chinese)'},
    {'code': 'en', 'label': '英语 (English)'},
    {'code': 'ja', 'label': '日语 (Japanese)'},
    {'code': 'ko', 'label': '韩语 (Korean)'},
  ];

  @override
  void initState() {
    super.initState();
    _isAiSubtitleActive = widget.isAiSubtitleActive;

    // 若识别关闭但翻译开启，或当前视频有内置字幕轨，智能初始化来源
    if (!aiSubtitleEnabled.value && aiTranslationEnabled.value) {
      _selectedSource = 'builtin';
    }
    if (widget.subtitleTracks != null && widget.activeSubtitleId != null) {
      final idx = widget.subtitleTracks!.indexWhere((t) => t.id == widget.activeSubtitleId);
      if (idx >= 0) _selectedBuiltinTrackIndex = idx;
    }

    // 单例里可能还留着"上一个视频"的字幕：先清掉，否则面板会显示别的视频的
    // 状态与条数（表现为"串台"），甚至把上一个视频的字幕当成当前视频的缓存。
    if (_generator.entries.isNotEmpty &&
        _generator.entriesVideoPath != widget.videoPath) {
      _generator.clear();
    }
    _currentState = _generator.state;

    // 检查并优先同步当前视频正在执行的后台任务
    final runningTask = AiTaskManager.instance.getTask(widget.videoPath);
    if (runningTask != null &&
        !runningTask.isCancelled &&
        (runningTask.state == AsrState.preparing ||
            runningTask.state == AsrState.processing)) {
      _selectedModel = runningTask.modelId;
      _selectedLanguage = runningTask.language;
      _currentState = runningTask.state;
      _statusMessage = runningTask.statusMessage;
    } else if (_generator.holdsEntriesFor(widget.videoPath) &&
        _generator.entriesModelId != null &&
        _generator.entriesModelId!.isNotEmpty) {
      // 关键对齐：当前视频在播放器中已经展示/载入了字幕，
      // 必须精准对齐到生成该字幕的模型（彻底解决“展示着模型2字幕，点进面板却选中模型1”的问题）
      _selectedModel = _generator.entriesModelId!;
      _localEntries = _generator.entries;
      _currentState = _generator.state;
      _statusMessage = '已载入 ${_selectedModel.toUpperCase()} 模型字幕 (共 ${_localEntries.length} 条)';
    } else {
      // 尝试自动读取当前视频的本地字幕缓存（按模型精准匹配）
      AiTaskManager.instance
          .loadCachedSubtitles(_cacheKey, modelId: _selectedModel)
          .then((cached) {
            if (mounted && cached != null && cached.isNotEmpty) {
              setState(() {
                _localEntries = cached;
                _currentState = AsrState.completed;
                _statusMessage = '已载入历史字幕缓存 (共 ${cached.length} 条)';
              });
              _generator.setEntries(
                cached,
                videoPath: widget.videoPath,
                modelId: _selectedModel,
                markCompleted: true,
              );
            }
          });
    }

    AiTaskManager.instance.addListener(_onTaskManagerChanged);

    _progressSub = _generator.progressStream.listen((p) {
      if (!mounted) return;
      // 串台拦截：只有当生成器当前确属本视频时才同步单例进度
      if (_generator.entriesVideoPath != null &&
          _generator.entriesVideoPath != widget.videoPath) {
        return;
      }
      setState(() {
        _currentState = p.state;
        _statusMessage = p.message;
      });
    });
    _checkModels(autoLoadCached: true);

    // 设备能力检测：不满足最低要求时禁用识别入口并给出明确提示
    detectDeviceCapabilities().then((caps) {
      if (mounted) setState(() => _deviceCaps = caps);
    });

    // 预先探测将要使用的识别引擎（引擎包 / 内置 CPU 插件），供界面展示
    EnginePackManager.instance
        .resolvePreferred(allowGpu: !aiAsrForceCpu.value)
        .then((pack) {
          if (!mounted) return;
          setState(() {
            _engineLabel = pack == null ? '内置 CPU 引擎' : pack.displayName;
          });
        });
  }

  /// 获取当前正在后台运行且非本视频的识别任务。
  AiTask? get _otherRunningTask {
    final activeKey = widget.videoPath;
    final cacheKey = _cacheKey;
    for (final task in AiTaskManager.instance.activeTasks) {
      if (task.videoPath != activeKey && task.videoPath != cacheKey) {
        return task;
      }
    }
    return null;
  }

  void _onTaskManagerChanged() {
    if (!mounted) return;
    final task = AiTaskManager.instance.getTask(widget.videoPath);
    if (task != null && task.isRunning) {
      setState(() {
        _currentState = task.state;
        _statusMessage = task.statusMessage;
        _selectedModel = task.modelId;
      });
    } else {
      // 任务结束或非运行状态时，触发重绘更新通知横幅与操作按钮，不强行覆盖 _currentState
      setState(() {});
    }
  }

  @override
  void dispose() {
    AiTaskManager.instance.removeListener(_onTaskManagerChanged);
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _checkModels({bool autoLoadCached = false}) async {
    // 扫一遍模型目录，记下"哪些模型已导入"。
    //
    // 注意：这里必须记录**全部**模型的可用性，不能只记当前选中的那一个 ——
    // 之前只写 `{当前选中: 是否可用}`，一旦 _selectedModel 与这次探测结果不同步
    // （例如打开面板时刚好有别的识别任务在跑、导致下面的 `_selectedModel = activeId`
    // 被跳过），卡片查表就会查到空值，误报"尚未导入模型"。
    final imported = (await ModelManager.instance.getDownloadedModels())
        .toSet();

    // 顺便确认当前视频有哪些模型留下了字幕缓存（界面标记用）
    final cachedList = await AiTaskManager.instance.getCachedModelIds(
      _cacheKey,
    );
    if (!mounted) return;

    var activeId = _selectedModel;

    // 优先级 1：若生成器正在承载当前视频的字幕，锁定为该字幕的归属模型
    if (_generator.holdsEntriesFor(widget.videoPath) &&
        _generator.entriesModelId != null &&
        _generator.entriesModelId!.isNotEmpty) {
      activeId = _generator.entriesModelId!;
    } else if (autoLoadCached && _localEntries.isEmpty && cachedList.isNotEmpty) {
      // 优先级 2：仅在面板首次打开初始化时，若尚未载入字幕，智能预选已有缓存的模型并载入
      if (!cachedList.contains(activeId)) {
        activeId = cachedList.first;
        final cached = await AiTaskManager.instance.loadCachedSubtitles(
          _cacheKey,
          modelId: activeId,
        );
        if (mounted && cached != null && cached.isNotEmpty) {
          setState(() {
            _localEntries = cached;
            _currentState = AsrState.completed;
            _statusMessage = '已载入历史字幕缓存 (共 ${cached.length} 条)';
          });
          _generator.setEntries(
            cached,
            videoPath: widget.videoPath,
            modelId: activeId,
            markCompleted: true,
          );
        }
      }
    }

    // 选中的模型没导入时，回落到第一个已导入的模型；一个都没导入则保持原选择，
    // 由界面提示去设置页导入。
    if (!imported.contains(activeId)) {
      final fallback = availableModels
          .where((m) => imported.contains(m.id))
          .toList();
      if (fallback.isNotEmpty) activeId = fallback.first.id;
    }

    setState(() {
      _cachedModels = cachedList.toSet();
      _modelAvailability = {
        for (final m in availableModels) m.id: imported.contains(m.id),
      };
      // 选中的模型确实已导入时才落位。正在识别时 _selectedModel 已经是任务用的
      // 那个模型（同样已导入），所以这里无条件同步是安全的，也不会打断识别。
      if (imported.contains(activeId)) _selectedModel = activeId;
      _checkingModels = false;
    });
    _syncEnglishOnlyLanguage();
  }

  /// 英语专用模型（.en）只能识别英语：选中它时把语言锁定为英语。
  void _syncEnglishOnlyLanguage() {
    final info = ModelManager.instance.infoOf(_selectedModel);
    if (info != null && info.isEnglishOnly && _selectedLanguage != 'en') {
      setState(() => _selectedLanguage = 'en');
    }
  }

  Future<void> _onSelectModel(String id) async {
    final isRunning =
        _currentState == AsrState.preparing ||
        _currentState == AsrState.processing;
    if (isRunning) return;

    setState(() => _selectedModel = id);
    // 记住用户的选择，下次打开面板时恢复
    setAiAsrModelId(id);
    // 英语专用模型：语言锁定为英语
    _syncEnglishOnlyLanguage();

    // 同步状态与字幕：切换到的模型已有缓存则载入，否则清空并回到就绪状态
    final cached = await AiTaskManager.instance.loadCachedSubtitles(
      _cacheKey,
      modelId: id,
    );
    if (mounted && cached != null && cached.isNotEmpty) {
      setState(() {
        _localEntries = cached;
        _currentState = AsrState.completed;
        _statusMessage =
            '已切换并载入 ${id.toUpperCase()} 模型历史缓存 (共 ${cached.length} 条)';
      });
      _generator.setEntries(
        cached,
        videoPath: widget.videoPath,
        modelId: id,
        markCompleted: true,
      );
    } else {
      setState(() {
        _localEntries = [];
        _currentState = AsrState.idle;
        _statusMessage = null;
        _previewExpanded = false;
      });
      if (_generator.holdsEntriesFor(widget.videoPath)) {
        _generator.clear();
      }
    }
  }

  void _startTranscribing() {
    final isRunning =
        _currentState == AsrState.preparing ||
        _currentState == AsrState.processing;
    if (isRunning) return;

    // 低端/老旧设备不做兼容降级，直接明确拒绝
    final caps = _deviceCaps;
    if (caps != null && !caps.meetsMinimumRequirements) {
      AppToast.show(
        context,
        '当前设备不支持 AI 语音识别：${caps.unsupportedReason ?? '硬件不满足最低要求'}',
        isError: true,
      );
      return;
    }

    if (!(_modelAvailability[_selectedModel] ?? false)) {
      AppToast.show(
        context,
        '所选模型 $_selectedModel 尚未导入：请在设置页「浏览全部模型」里按文件名对照，'
        '从网盘下载后用「导入模型」导入',
        isError: true,
      );
      return;
    }

    // 默认确保开启画面字幕显示
    if (!_isAiSubtitleActive) {
      setState(() => _isAiSubtitleActive = true);
      widget.onToggleSubtitleActive(true);
    }

    final title =
        widget.videoTitle ??
        (widget.videoPath.contains(Platform.pathSeparator)
            ? widget.videoPath.split(Platform.pathSeparator).last
            : widget.videoPath);

    AiTaskManager.instance.startTask(
      videoPath: widget.videoPath,
      videoTitle: title,
      modelId: _selectedModel,
      language: _selectedLanguage,
      // 缓存按下这个稳定键落盘（PFLX 时视频地址带随机端口，不能当身份）
      cacheKey: _cacheKey,
    );
  }

  void _stopTranscribing() {
    AiTaskManager.instance.cancelTask(widget.videoPath);
  }

  Future<void> _deleteSubtitlesWithConfirm() async {
    final modelName = _selectedModel.toUpperCase();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF262630),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 22),
            SizedBox(width: 8),
            Text('删除字幕缓存', style: TextStyle(fontSize: 16, color: Colors.white)),
          ],
        ),
        content: Text(
          '确定要删除当前 $modelName 模型的字幕缓存吗？\n删除后可重新识别原音频。',
          style: const TextStyle(
            fontSize: 13,
            color: Colors.white70,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // 1. 删除当前选定模型的磁盘物理缓存文件（主缓存 + 关联翻译缓存全量扫盘清理）
    await AiTaskManager.instance.deleteCachedSubtitles(
      _cacheKey,
      modelId: _selectedModel,
    );
    if (widget.videoPath != _cacheKey) {
      await AiTaskManager.instance.deleteCachedSubtitles(
        widget.videoPath,
        modelId: _selectedModel,
      );
    }

    // 2. 清理任务管理器中该模型的历史任务记录（解除 completed 状态死锁）
    AiTaskManager.instance.clearTaskFor(
      _cacheKey,
      modelId: _selectedModel,
    );
    if (widget.videoPath != _cacheKey) {
      AiTaskManager.instance.clearTaskFor(
        widget.videoPath,
        modelId: _selectedModel,
      );
    }

    // 3. 清空内存字幕（若当前内存中的字幕归属是被删除的模型，清空并关闭画面显示）
    final isCurrentGenModel = _generator.entriesModelId == null ||
        _generator.entriesModelId!.toLowerCase() == _selectedModel.toLowerCase();
    if (isCurrentGenModel) {
      _localEntries = [];
      _generator.clear();
      widget.onToggleSubtitleActive(false);
    }

    // 4. 重新扫描磁盘缓存与可用模型（不自动回填其他模型缓存）
    await _checkModels(autoLoadCached: false);

    // 5. 立即刷新界面状态：回到就绪状态，确保「开始识别」按钮恢复可点击
    if (mounted) {
      setState(() {
        if (isCurrentGenModel) {
          _localEntries = [];
          _isAiSubtitleActive = false;
        }
        _currentState = AsrState.idle;
        _statusMessage = null;
        _previewExpanded = false;
      });
      AppToast.show(context, '已成功删除 $modelName 模型字幕缓存，可重新识别');
    }
  }

  Future<void> _exportSrtFile() async {
    final entries = _currentDisplayEntries;
    if (entries.isEmpty) return;

    try {
      final hasTrans = entries.any((e) => e.translatedText != null && e.translatedText!.isNotEmpty);
      final srtContent = hasTrans
          ? SrtParser.serialize(entries, bilingual: true)
          : SubtitleGenerator.convertToSrt(entries);
      final srtBytes = Uint8List.fromList(utf8.encode(srtContent));

      // 提取建议的导出文件名
      String defaultName = hasTrans ? 'subtitle_bilingual.srt' : 'subtitle.srt';
      if (widget.videoTitle != null && widget.videoTitle!.trim().isNotEmpty) {
        final sanitized = widget.videoTitle!
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
            .trim();
        defaultName = hasTrans ? '${sanitized}_bilingual.srt' : '$sanitized.srt';
      } else {
        final base = widget.videoPath
            .split(Platform.isWindows ? r'\' : '/')
            .last;
        final dotIdx = base.lastIndexOf('.');
        if (dotIdx > 0) {
          final prefix = base.substring(0, dotIdx);
          defaultName = hasTrans ? '${prefix}_bilingual.srt' : '$prefix.srt';
        } else {
          defaultName = hasTrans ? '${base}_bilingual.srt' : '$base.srt';
        }
      }

      final savedUri = await FilePicker.saveFile(
        dialogTitle: hasTrans ? '导出双语 SRT 字幕文件' : '导出 SRT 字幕文件',
        fileName: defaultName,
        bytes: srtBytes,
        type: FileType.custom,
        allowedExtensions: ['srt'],
      );

      if (savedUri == null) return; // 用户取消

      String displayPath;
      try {
        displayPath = savedUri.toFilePath(windows: Platform.isWindows);
      } catch (_) {
        displayPath = savedUri.path;
      }

      if (mounted) {
        AppToast.show(context, '已成功导出字幕至：$displayPath');
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '导出失败: $e', isError: true);
      }
    }
  }

  String _trackDisplayLabel(SubtitleTrack t) {
    final parts = <String>[];
    if (t.title != null && t.title!.isNotEmpty) parts.add(t.title!);
    if (t.language != null && t.language!.isNotEmpty) parts.add('[${t.language}]');
    if (t.codec != null && t.codec!.isNotEmpty) parts.add(t.codec!);
    return parts.isEmpty ? '轨道 ${t.id}' : parts.join(' · ');
  }

  /// 提取并翻译选中的内置字幕轨
  Future<void> _extractAndTranslateBuiltin() async {
    if (_isTranslating) return;
    final tracks = widget.subtitleTracks;
    if (tracks == null || tracks.isEmpty) {
      AppToast.show(context, '当前视频未检测到内置字幕轨', isError: true);
      return;
    }

    final targetLang = aiTranslationTargetLang.value;
    final langInfo = TranslationLanguage.findByCode(targetLang);

    setState(() {
      _isTranslating = true;
      _cancelTranslation = false;
      _translatedCount = 0;
      _totalTranslateCount = 0;
      _statusMessage = '正在从视频提取内置字幕文本...';
    });

    try {
      final rawEntries = await BuiltInSubtitleExtractor.extractSubtitles(
        videoPath: widget.videoPath,
        subtitleIndex: _selectedBuiltinTrackIndex,
      );

      if (!mounted || _cancelTranslation) return;

      setState(() {
        _statusMessage = '已提取 ${rawEntries.length} 条字幕，正在翻译为 ${langInfo.name}...';
        _totalTranslateCount = rawEntries.length;
      });

      final translatedEntries = await TranslationService.instance.translateEntries(
        entries: rawEntries,
        targetLanguage: targetLang,
        onProgress: (cur, total) {
          if (mounted) {
            setState(() {
              _translatedCount = cur;
              _totalTranslateCount = total;
            });
          }
        },
        isCancelled: () => _cancelTranslation,
      );

      if (!mounted || _cancelTranslation) return;

      setState(() {
        _localEntries = translatedEntries;
        _currentState = AsrState.completed;
        _statusMessage = '内置字幕已成功翻译为 ${langInfo.name} (共 ${translatedEntries.length} 条)';
        _isAiSubtitleActive = true;
      });

      _generator.setEntries(
        translatedEntries,
        videoPath: widget.videoPath,
        markCompleted: true,
      );
      widget.onToggleSubtitleActive(true);

      await TranslationService.instance.saveTranslationCache(
        sourceKey: _cacheKey,
        sourceType: 'builtin_$_selectedBuiltinTrackIndex',
        targetLang: targetLang,
        engineId: TranslationService.instance.getActiveEngine().id,
        entries: translatedEntries,
      );

      if (mounted) {
        AppToast.show(context, '内置字幕已成功翻译，已在画面叠加呈现');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = '翻译失败: $e';
        });
        AppToast.show(context, '翻译失败: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isTranslating = false);
    }
  }

  /// 翻译当前已识别生成的字幕条目
  Future<void> _translateCurrentEntries() async {
    final entries = _currentDisplayEntries;
    if (entries.isEmpty || _isTranslating) return;

    final targetLang = aiTranslationTargetLang.value;
    final langInfo = TranslationLanguage.findByCode(targetLang);

    setState(() {
      _isTranslating = true;
      _cancelTranslation = false;
      _translatedCount = 0;
      _totalTranslateCount = entries.length;
      _statusMessage = '正在将字幕翻译为 ${langInfo.name}...';
    });

    try {
      final translatedEntries = await TranslationService.instance.translateEntries(
        entries: entries,
        targetLanguage: targetLang,
        onProgress: (cur, total) {
          if (mounted) {
            setState(() {
              _translatedCount = cur;
              _totalTranslateCount = total;
            });
          }
        },
        isCancelled: () => _cancelTranslation,
      );

      if (!mounted || _cancelTranslation) return;

      setState(() {
        _localEntries = translatedEntries;
        _statusMessage = '字幕已成功翻译为 ${langInfo.name} (共 ${translatedEntries.length} 条)';
        _isAiSubtitleActive = true;
      });

      _generator.setEntries(
        translatedEntries,
        videoPath: widget.videoPath,
        modelId: _selectedModel,
        markCompleted: true,
      );
      widget.onToggleSubtitleActive(true);

      // 持久化到 ASR 缓存与翻译缓存
      await AiTaskManager.instance.saveCachedSubtitles(
        _cacheKey,
        translatedEntries,
        modelId: _selectedModel,
      );
      await TranslationService.instance.saveTranslationCache(
        sourceKey: _cacheKey,
        sourceType: 'asr_$_selectedModel',
        targetLang: targetLang,
        engineId: TranslationService.instance.getActiveEngine().id,
        entries: translatedEntries,
      );

      if (mounted) {
        AppToast.show(context, '字幕翻译完成，画面已开启双语显示');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = '翻译失败: $e';
        });
        AppToast.show(context, '翻译失败: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isTranslating = false);
    }
  }

  void _cancelCurrentTranslation() {
    _cancelTranslation = true;
    setState(() {
      _isTranslating = false;
      _statusMessage = '翻译已取消';
    });
    AppToast.show(context, '已取消翻译');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentTask = AiTaskManager.instance.getTask(widget.videoPath);
    final isRunning = currentTask != null && currentTask.isRunning;
    final entries = _currentDisplayEntries;

    final hasBuiltinTracks = widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty;
    final canUseAsr = aiSubtitleEnabled.value;
    final canTranslate = aiTranslationEnabled.value;

    String sheetTitle;
    if (canUseAsr && canTranslate) {
      sheetTitle = 'AI 语音字幕 · 识别与翻译';
    } else if (canTranslate) {
      sheetTitle = 'AI 字幕翻译';
    } else {
      sheetTitle = 'AI 语音字幕识别';
    }

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E24),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 4),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶端拖拽柄
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // 标题栏
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: .15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.subtitles_rounded,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      sheetTitle,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            const Divider(color: Colors.white12, height: 1),

            // 内容可滚动区域
            Flexible(
              child: ListView(
                padding: const EdgeInsets.all(20),
                shrinkWrap: true,
                children: [
                  // 来源切换（仅当识别与翻译同时开启、且视频有内置字幕时显示）
                  if (canUseAsr && canTranslate && hasBuiltinTracks) ...[
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'asr',
                          icon: Icon(Icons.mic_none_rounded, size: 16),
                          label: Text('AI 语音识别'),
                        ),
                        ButtonSegment(
                          value: 'builtin',
                          icon: Icon(Icons.subtitles_rounded, size: 16),
                          label: Text('翻译内置字幕'),
                        ),
                      ],
                      selected: {_selectedSource},
                      onSelectionChanged: (set) => setState(() => _selectedSource = set.first),
                    ),
                    const SizedBox(height: 16),
                  ],

                  if (_selectedSource == 'builtin' || (!canUseAsr && canTranslate)) ...[
                    // ---------------- 内置字幕翻译流程 ----------------
                    _buildTranslationStatusCard(theme, entries.length),
                    const SizedBox(height: 16),
                    _buildSectionHeader(Icons.subtitles_outlined, '选择要翻译的内置字幕轨'),
                    const SizedBox(height: 8),
                    _buildBuiltinTrackSelector(theme),
                    const SizedBox(height: 16),

                    if (entries.isNotEmpty) ...[
                      _buildSectionHeader(Icons.visibility_rounded, '字幕显示与管理'),
                      const SizedBox(height: 8),
                      _buildSubtitleControls(theme),
                      const SizedBox(height: 16),
                      _buildCollapsiblePreviewHeader(theme, entries.length),
                      if (_previewExpanded) ...[
                        const SizedBox(height: 8),
                        _buildSubtitlePreviewList(entries),
                      ],
                    ],
                  ] else ...[
                    // ---------------- AI 语音识别流程 ----------------
                    if (_otherRunningTask != null)
                      _buildOtherTaskNotice(_otherRunningTask!),
                    // 1. 状态看板
                    _buildStatusCard(theme, isRunning, entries.length),
                    const SizedBox(height: 6),
                    _buildEngineCaption(),

                    const SizedBox(height: 16),

                    // 2. 模型选择
                    _buildSectionHeader(Icons.memory_rounded, '语音识别模型'),
                    const SizedBox(height: 8),
                    _buildModelSelector(theme),

                    const SizedBox(height: 16),

                    // 3. 语言选择
                    _buildSectionHeader(Icons.translate_rounded, '识别原音频语言'),
                    const SizedBox(height: 8),
                    _buildLanguageSelector(theme),

                    const SizedBox(height: 16),

                    // 4. 字幕显示开关与管理
                    if (entries.isNotEmpty) ...[
                      _buildSectionHeader(Icons.visibility_rounded, '字幕显示与管理'),
                      const SizedBox(height: 8),
                      _buildSubtitleControls(theme),
                      const SizedBox(height: 16),
                      _buildCollapsiblePreviewHeader(theme, entries.length),
                      if (_previewExpanded) ...[
                        const SizedBox(height: 8),
                        _buildSubtitlePreviewList(entries),
                      ],
                    ],
                  ],
                ],
              ),
            ),

            // 底部操作按钮栏
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: _buildBottomActions(theme, isRunning),
            ),
          ],
        ),
      ),
    );
  }

  /// 内置字幕轨下拉选择器
  Widget _buildBuiltinTrackSelector(ThemeData theme) {
    final tracks = widget.subtitleTracks;
    if (tracks == null || tracks.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF262630),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: Colors.white54),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '当前视频未检测到内置字幕轨。若是外部视频文件，可尝试使用 AI 语音识别生成字幕。',
                style: TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF262630),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _selectedBuiltinTrackIndex.clamp(0, tracks.length - 1),
          isExpanded: true,
          focusColor: Colors.transparent,
          dropdownColor: const Color(0xFF262630),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
          items: List.generate(tracks.length, (idx) {
            final track = tracks[idx];
            return DropdownMenuItem<int>(
              value: idx,
              child: Text(
                _trackDisplayLabel(track),
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
            );
          }),
          onChanged: _isTranslating
              ? null
              : (val) {
                  if (val != null) setState(() => _selectedBuiltinTrackIndex = val);
                },
        ),
      ),
    );
  }

  /// 翻译状态看板
  Widget _buildTranslationStatusCard(ThemeData theme, int entryCount) {
    final targetLang = aiTranslationTargetLang.value;
    final langName = TranslationLanguage.findByCode(targetLang).name;

    Color bg = const Color(0xFF262630);
    Color accent = Colors.white54;
    IconData icon = Icons.translate_rounded;
    String text = '选择内置字幕轨，点击下方提取并翻译为 $langName';

    if (_isTranslating) {
      bg = PolyFlixColors.violet.withValues(alpha: .15);
      accent = const Color(0xFF9D91FF);
      icon = Icons.sync_rounded;
      text = _statusMessage ?? '正在处理内置字幕...';
    } else if (entryCount > 0) {
      bg = Colors.green.withValues(alpha: .12);
      accent = Colors.greenAccent;
      icon = Icons.check_circle_rounded;
      text = _statusMessage ?? '已生成 $entryCount 条字幕并就绪';
    } else if (_statusMessage != null && _statusMessage!.contains('失败')) {
      bg = Colors.red.withValues(alpha: .12);
      accent = Colors.redAccent;
      icon = Icons.error_outline_rounded;
      text = _statusMessage!;
    }

    final double? progressPercent = (_totalTranslateCount > 0 && _isTranslating)
        ? (_translatedCount / _totalTranslateCount).clamp(0.0, 1.0)
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: .3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_isTranslating)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: accent,
                  ),
                )
              else
                Icon(icon, color: accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    color: _isTranslating || entryCount > 0 ? Colors.white : Colors.white70,
                    fontWeight: _isTranslating ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
          if (_isTranslating && progressPercent != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progressPercent,
                minHeight: 5,
                backgroundColor: Colors.white12,
                color: accent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 识别引擎说明行：让用户知道这次识别是走 GPU 引擎包还是内置 CPU。
  Widget _buildEngineCaption() {
    final label = SubtitleGenerator.lastEngineLabel ?? _engineLabel;
    return Row(
      children: [
        const Icon(Icons.memory_rounded, size: 13, color: Colors.white38),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label == null ? '识别引擎：正在检测…' : '识别引擎：$label',
            style: const TextStyle(fontSize: 11.5, color: Colors.white38),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white70),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusCard(ThemeData theme, bool isRunning, int entryCount) {
    final task = AiTaskManager.instance.getTask(widget.videoPath);
    Color bg = const Color(0xFF262630);
    Color accent = Colors.white54;
    IconData icon = Icons.info_outline_rounded;
    String text = '就绪，点击下方开始识别原音频';

    if (isRunning) {
      bg = PolyFlixColors.violet.withValues(alpha: .15);
      accent = const Color(0xFF9D91FF);
      icon = Icons.graphic_eq_rounded;
      text = task?.statusMessage ?? _statusMessage ?? '正在处理音频...';
    } else if (_currentState == AsrState.completed && entryCount > 0) {
      bg = Colors.green.withValues(alpha: .12);
      accent = Colors.greenAccent;
      icon = Icons.check_circle_rounded;
      text = '识别已完成，已生成 $entryCount 条原语言字幕';
    } else if (_currentState == AsrState.error) {
      bg = Colors.red.withValues(alpha: .12);
      accent = Colors.redAccent;
      icon = Icons.error_outline_rounded;
      text = _statusMessage ?? '识别发生错误';
    } else if (_otherRunningTask != null) {
      bg = const Color(0xFF262630);
      accent = Colors.amber.shade300;
      icon = Icons.hourglass_top_rounded;
      text = '其他视频正在识别，当前视频已暂停新识别';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: .3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isRunning)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: accent,
                  ),
                )
              else
                Icon(icon, color: accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    color: isRunning || _currentState != AsrState.idle
                        ? Colors.white
                        : Colors.white70,
                    fontWeight: isRunning ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
          if (isRunning && task != null && task.percent > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.percent > 0 ? task.percent : null,
                minHeight: 5,
                backgroundColor: Colors.white12,
                color: accent,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 当前模型卡片：展示所选模型 + 状态标记，点击打开"模型选择/下载"面板。
  ///
  /// 模型清单有二十多个，不再用并排卡片（放不下），统一收敛到选择面板里。
  Widget _buildModelSelector(ThemeData theme) {
    if (_checkingModels) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final isRunning =
        _currentState == AsrState.preparing ||
        _currentState == AsrState.processing;
    final info = ModelManager.instance.infoOf(_selectedModel);
    final isAvailable = _modelAvailability[_selectedModel] ?? false;
    final hasCache = _cachedModels.contains(_selectedModel);

    return InkWell(
      onTap: isRunning ? null : _openModelPicker,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF262630),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isAvailable
                ? Colors.white12
                : Colors.redAccent.withValues(alpha: .5),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isAvailable
                  ? Icons.check_circle_outline_rounded
                  : Icons.error_outline_rounded,
              size: 20,
              color: isAvailable ? Colors.green : Colors.redAccent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          info?.displayName ?? _selectedModel,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isRunning) ...[
                        const SizedBox(width: 6),
                        _tag('运行中', Colors.green),
                      ] else if (hasCache) ...[
                        const SizedBox(width: 6),
                        _tag('已缓存字幕', Colors.teal.shade700),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _modelSubtitle(
                      info: info,
                      isRunning: isRunning,
                      isAvailable: isAvailable,
                      hasCache: hasCache,
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: isAvailable
                          ? Colors.white54
                          : Colors.redAccent.withValues(alpha: .8),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '更换',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  /// 当前模型卡片下方的状态说明。
  String _modelSubtitle({
    required WhisperModelInfo? info,
    required bool isRunning,
    required bool isAvailable,
    required bool hasCache,
  }) {
    if (isRunning) return '识别进行中，暂不能切换模型';
    if (!isAvailable) return '尚未导入模型，点击右侧选择（需先在设置页导入）';

    final buffer = StringBuffer(info?.sizeLabel ?? '');
    if (hasCache) buffer.write(' · 已生成该模型字幕缓存');
    return buffer.toString();
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 打开模型选择面板；选中的模型会立即生效（有缓存则载入该模型缓存）。
  Future<void> _openModelPicker() async {
    final result = await ModelCatalogSheet.show(
      context,
      selectedId: _selectedModel,
      mode: ModelSheetMode.picker,
    );
    if (result == null || !mounted) return;

    await _checkModels();
    if (!mounted) return;
    await _onSelectModel(result.modelId);
  }

  Widget _buildLanguageSelector(ThemeData theme) {
    final englishOnly =
        ModelManager.instance.infoOf(_selectedModel)?.isEnglishOnly ?? false;

    if (englishOnly) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF262630),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: const Row(
          children: [
            Icon(Icons.lock_outline_rounded, size: 16, color: Colors.white54),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '英语（当前模型为英语专用，只能识别英语）',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF262630),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedLanguage,
          isExpanded: true,
          focusColor: Colors.transparent,
          dropdownColor: const Color(0xFF262630),
          icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
          items: _languageOptions.map((opt) {
            return DropdownMenuItem<String>(
              value: opt['code'],
              child: Text(
                opt['label']!,
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
            );
          }).toList(),
          onChanged: _generator.isRunning
              ? null
              : (val) {
                  if (val != null) setState(() => _selectedLanguage = val);
                },
        ),
      ),
    );
  }

  Widget _buildSubtitleControls(ThemeData theme) {
    final hasEntries = _generator.entries.isNotEmpty;
    final targetLang = aiTranslationTargetLang.value;
    final langName = TranslationLanguage.findByCode(targetLang).name;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF262630),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.closed_caption_rounded,
                color: Colors.white70,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '在视频画面上显示字幕',
                  style: TextStyle(fontSize: 13, color: Colors.white),
                ),
              ),
              Switch.adaptive(
                value: _isAiSubtitleActive,
                activeTrackColor: theme.colorScheme.primary,
                onChanged: (val) {
                  setState(() => _isAiSubtitleActive = val);
                  widget.onToggleSubtitleActive(val);
                },
              ),
              if (hasEntries) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _hasAnyTranslation ? '导出双语 SRT 字幕' : '导出为 SRT 字幕',
                  icon: const Icon(
                    Icons.file_download_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                  onPressed: _exportSrtFile,
                ),
              ],
              const SizedBox(width: 4),
              IconButton(
                tooltip: '删除字幕缓存',
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.white60,
                  size: 20,
                ),
                onPressed: _cachedModels.contains(_selectedModel)
                    ? _deleteSubtitlesWithConfirm
                    : null,
              ),
            ],
          ),
          // 若启用了翻译，且当前处于 ASR 模式、条目已有，展示一键翻译按钮
          if (aiTranslationEnabled.value && hasEntries && _selectedSource == 'asr') ...[
            const SizedBox(height: 8),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _isTranslating ? _cancelCurrentTranslation : _translateCurrentEntries,
                    icon: _isTranslating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.g_translate_rounded, size: 16),
                    label: Text(
                      _isTranslating
                          ? '取消翻译 ($_translatedCount/$_totalTranslateCount)'
                          : (_hasAnyTranslation
                              ? '重新翻译为 $langName'
                              : '一键翻译为 $langName'),
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCollapsiblePreviewHeader(ThemeData theme, int totalCount) {
    return InkWell(
      onTap: () => setState(() => _previewExpanded = !_previewExpanded),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.list_alt_rounded, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Text(
              '字幕条目预览 (共 $totalCount 条)',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const Spacer(),
            Text(
              _previewExpanded ? '收起' : '展开查看',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 4),
            Icon(
              _previewExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitlePreviewList(List<SubtitleEntry> entries) {
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: const Color(0xFF19191E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: entries.length,
        separatorBuilder: (_, _) =>
            const Divider(color: Colors.white10, height: 1),
        itemBuilder: (context, idx) {
          final e = entries[idx];
          final startStr = _formatDuration(e.start);
          return InkWell(
            onTap: widget.onSeekTo != null
                ? () => widget.onSeekTo!(e.start)
                : null,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    startStr,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.text,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                        if (e.translatedText != null && e.translatedText!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            e.translatedText!,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomActions(ThemeData theme, bool isRunning) {
    if (_selectedSource == 'builtin') {
      if (_isTranslating) {
        return FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.redAccent.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: const Icon(Icons.close_rounded, size: 20),
          label: Text(
            '取消翻译 ($_translatedCount/$_totalTranslateCount)',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          onPressed: _cancelCurrentTranslation,
        );
      }

      final hasTracks = widget.subtitleTracks != null && widget.subtitleTracks!.isNotEmpty;
      final targetLang = aiTranslationTargetLang.value;
      final langName = TranslationLanguage.findByCode(targetLang).name;

      return Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: hasTracks ? PolyFlixColors.violet : Colors.white12,
                foregroundColor: hasTracks ? Colors.white : Colors.white38,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.g_translate_rounded, size: 20),
              label: Text(
                hasTracks ? '提取并翻译为 $langName' : '无内置字幕可提取',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              onPressed: hasTracks ? _extractAndTranslateBuiltin : null,
            ),
          ),
        ],
      );
    }

    if (isRunning) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.redAccent.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: const Icon(Icons.stop_circle_rounded, size: 20),
        label: const Text(
          '停止识别',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        onPressed: _stopTranscribing,
      );
    }

    final hasModel = _modelAvailability[_selectedModel] ?? false;
    final hasCache = _cachedModels.contains(_selectedModel);
    final unsupported =
        _deviceCaps != null && !_deviceCaps!.meetsMinimumRequirements;
    final otherRunning = _otherRunningTask;
    final isOtherBusyAction =
        !hasCache && !unsupported && hasModel && otherRunning != null;

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: hasCache
                  ? Colors.white12
                  : (isOtherBusyAction
                        ? const Color(0xFF382E1E)
                        : PolyFlixColors.violet),
              foregroundColor: hasCache
                  ? Colors.white38
                  : (isOtherBusyAction ? Colors.amberAccent : Colors.white),
              disabledBackgroundColor: Colors.white10,
              disabledForegroundColor: Colors.white30,
              side: isOtherBusyAction
                  ? const BorderSide(color: Color(0xFF6B582E), width: 1)
                  : null,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: Icon(
              unsupported
                  ? Icons.block_rounded
                  : (hasCache
                        ? Icons.check_circle_outline_rounded
                        : (isOtherBusyAction
                              ? Icons.hourglass_top_rounded
                              : Icons.mic_none_rounded)),
              size: 20,
              color: hasCache
                  ? Colors.white38
                  : (isOtherBusyAction ? Colors.amberAccent : Colors.white),
            ),
            label: Text(
              unsupported
                  ? '当前设备不支持此功能'
                  : (hasModel
                        ? (hasCache
                              ? '已有字幕缓存'
                              : (isOtherBusyAction
                                    ? '其他视频识别中 (点击处理)'
                                    : '开始识别原音频'))
                        : '未就绪 (缺少模型)'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: hasCache
                    ? Colors.white38
                    : (isOtherBusyAction ? Colors.amberAccent : Colors.white),
              ),
            ),
            onPressed: unsupported
                ? null
                : (!hasModel
                      ? null
                      : (hasCache
                            ? null
                            : (isOtherBusyAction
                                  ? () => _handleStartWithOtherBusy(otherRunning)
                                  : _startTranscribing))),
          ),
        ),
      ],
    );
  }

  /// 顶部醒目提示：后台有其他视频正在进行识别任务。
  Widget _buildOtherTaskNotice(AiTask other) {
    final percent = other.percent > 0
        ? '已完成 ${(other.percent * 100).toStringAsFixed(0)}%'
        : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.amber.withValues(alpha: .35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.hourglass_top_rounded,
              size: 18,
              color: Colors.amberAccent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '「${other.videoTitle}」正在识别中${percent != null ? '（$percent）' : ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '后台已有识别任务。您仍可自由切换和查看本视频已有的字幕缓存；同一时间只支持一个视频识别。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.amberAccent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _confirmCancelOtherTask(other),
            child: const Text('取消任务', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 确认取消其他视频正在执行的后台识别任务。
  Future<void> _confirmCancelOtherTask(AiTask other) async {
    final percent = other.percent > 0
        ? '已完成 ${(other.percent * 100).toStringAsFixed(0)}%'
        : null;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .62),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF202027),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '取消识别任务？',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        content: Text(
          '当前正在后台识别「${other.videoTitle}」${percent != null ? '（$percent）' : ''}，'
          '取消后该任务将中断。\n\n确认取消该任务吗？',
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Colors.white70,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('暂不取消', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取消任务'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      AiTaskManager.instance.cancelTask(other.videoPath);
      AppToast.show(context, '已取消「${other.videoTitle}」的识别任务');
      setState(() {});
    }
  }

  /// 点击"其他视频识别中"按钮时的处理逻辑。
  Future<void> _handleStartWithOtherBusy(AiTask other) async {
    final percent = other.percent > 0
        ? '已完成 ${(other.percent * 100).toStringAsFixed(0)}%'
        : null;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .62),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF202027),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(
          Icons.hourglass_top_rounded,
          size: 34,
          color: Colors.amberAccent,
        ),
        title: const Text(
          '当前有其他视频正在识别',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '「${other.videoTitle}」的字幕识别还没结束'
              '${percent != null ? '（$percent）' : ''}。',
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '同一时间只能识别一个视频。\n是否取消该任务，并立即开始当前视频的识别？',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Colors.white70,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '暂不识别',
              style: TextStyle(color: Colors.white60),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: PolyFlixColors.violet,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              '取消并开始当前识别',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      AiTaskManager.instance.cancelTask(other.videoPath);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      _startTranscribing();
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
