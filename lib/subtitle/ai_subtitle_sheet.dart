import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'ai_task_manager.dart';
import '../settings/app_settings.dart';
import 'model_manager.dart';
import 'subtitle_generator.dart';

/// AI 语音识别字幕控制面板。
///
/// 支持配置识别模型、源语言选择、启动/停止识别、清空字幕与实时状态监控。
class AiSubtitleSheet extends StatefulWidget {
  const AiSubtitleSheet({
    super.key,
    required this.videoPath,
    this.videoTitle,
    required this.isAiSubtitleActive,
    required this.onToggleSubtitleActive,
    this.onSeekTo,
  });

  /// 当前视频源路径（本地文件或 PFLX 流式地址）。
  final String videoPath;

  /// 视频标题（可选，用于任务展示）。
  final String? videoTitle;

  /// 画面上 AI 字幕叠加层是否处于激活显示状态。
  final bool isAiSubtitleActive;

  /// 切换画面字幕显示的开关回调。
  final ValueChanged<bool> onToggleSubtitleActive;

  /// 点击字幕跳转播放进度的回调（可选）。
  final ValueChanged<Duration>? onSeekTo;

  /// 弹出展示面板的标准便捷方法。
  static Future<void> show({
    required BuildContext context,
    required String videoPath,
    String? videoTitle,
    required bool isAiSubtitleActive,
    required ValueChanged<bool> onToggleSubtitleActive,
    ValueChanged<Duration>? onSeekTo,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AiSubtitleSheet(
        videoPath: videoPath,
        videoTitle: videoTitle,
        isAiSubtitleActive: isAiSubtitleActive,
        onToggleSubtitleActive: onToggleSubtitleActive,
        onSeekTo: onSeekTo,
      ),
    );
  }

  @override
  State<AiSubtitleSheet> createState() => _AiSubtitleSheetState();
}

class _AiSubtitleSheetState extends State<AiSubtitleSheet> {
  final SubtitleGenerator _generator = SubtitleGenerator.instance;
  StreamSubscription<AsrProgress>? _progressSub;

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
    } else if (_generator.entries.isEmpty) {
      // 尝试自动读取已有的本地字幕缓存（优先当前默认模型或历史最高精度模型）
      AiTaskManager.instance.loadCachedSubtitles(widget.videoPath, modelId: _selectedModel).then((cached) {
        if (mounted && cached != null && cached.isNotEmpty) {
          _generator.setEntries(cached);
          setState(() {
            _currentState = AsrState.completed;
            _statusMessage = '已载入历史字幕缓存 (共 ${cached.length} 条)';
          });
        }
      });
    }

    AiTaskManager.instance.addListener(_onTaskManagerChanged);

    _progressSub = _generator.progressStream.listen((p) {
      if (!mounted) return;
      setState(() {
        _currentState = p.state;
        _statusMessage = p.message;
      });
    });
    _checkModels();
  }

  void _onTaskManagerChanged() {
    if (!mounted) return;
    final task = AiTaskManager.instance.getTask(widget.videoPath);
    if (task != null) {
      setState(() {
        _currentState = task.state;
        _statusMessage = task.statusMessage;
        if (task.state == AsrState.preparing || task.state == AsrState.processing) {
          _selectedModel = task.modelId;
        }
      });
      if (task.state == AsrState.completed) {
        _checkModels();
      }
    }
  }

  @override
  void dispose() {
    AiTaskManager.instance.removeListener(_onTaskManagerChanged);
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _checkModels() async {
    final tinyReady = await ModelManager.instance.isModelDownloaded('tiny');
    final baseReady = await ModelManager.instance.isModelDownloaded('base');
    final smallReady = await ModelManager.instance.isModelDownloaded('small');
    final cachedList = await AiTaskManager.instance.getCachedModelIds(widget.videoPath);
    if (!mounted) return;
    setState(() {
      _cachedModels = cachedList.toSet();
      _modelAvailability = {
        'tiny': tinyReady,
        'base': baseReady,
        'small': smallReady,
      };
      // 如果当前没有运行中的任务，且选中的模型不可用，切换到首个可用的模型
      final isRunning = _currentState == AsrState.preparing || _currentState == AsrState.processing;
      if (!isRunning && !(_modelAvailability[_selectedModel] ?? false)) {
        for (final m in ['tiny', 'base', 'small']) {
          if (_modelAvailability[m] == true) {
            _selectedModel = m;
            break;
          }
        }
      }
      _checkingModels = false;
    });
  }

  Future<void> _onSelectModel(String id) async {
    final isRunning = _currentState == AsrState.preparing || _currentState == AsrState.processing;
    if (isRunning) return;

    setState(() => _selectedModel = id);
    // 记住用户的选择，下次打开面板时恢复
    setAiAsrModelId(id);

    // 同步状态与字幕：切换到的模型已有缓存则载入，否则清空并回到就绪状态
    final cached = await AiTaskManager.instance.loadCachedSubtitles(
      widget.videoPath,
      modelId: id,
    );
    if (mounted && cached != null && cached.isNotEmpty) {
      _generator.setEntries(cached);
      setState(() {
        _currentState = AsrState.completed;
        _statusMessage = '已切换并载入 ${id.toUpperCase()} 模型历史缓存 (共 ${cached.length} 条)';
      });
    } else {
      _generator.clear();
      setState(() {
        _currentState = AsrState.idle;
        _statusMessage = null;
        _previewExpanded = false;
      });
    }
  }

  void _startTranscribing() {
    final isRunning = _currentState == AsrState.preparing || _currentState == AsrState.processing;
    if (isRunning) return;

    if (!(_modelAvailability[_selectedModel] ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('所选模型 $_selectedModel 尚未就绪，请先在设置页中下载或放置模型')),
      );
      return;
    }

    // 默认确保开启画面字幕显示
    if (!_isAiSubtitleActive) {
      setState(() => _isAiSubtitleActive = true);
      widget.onToggleSubtitleActive(true);
    }

    final title = widget.videoTitle ??
        (widget.videoPath.contains(Platform.pathSeparator)
            ? widget.videoPath.split(Platform.pathSeparator).last
            : widget.videoPath);

    AiTaskManager.instance.startTask(
      videoPath: widget.videoPath,
      videoTitle: title,
      modelId: _selectedModel,
      language: _selectedLanguage,
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
          style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5),
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

    // 1. 删除磁盘物理缓存文件
    await AiTaskManager.instance.deleteCachedSubtitles(
      widget.videoPath,
      modelId: _selectedModel,
    );

    // 2. 清空内存字幕
    _generator.clear();

    // 3. 刷新状态并恢复识别按钮可点击
    if (mounted) {
      setState(() {
        _cachedModels.remove(_selectedModel);
        // 重置状态为就绪，避免仍显示「识别已完成」的提示
        _currentState = AsrState.idle;
        _statusMessage = null;
        _previewExpanded = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已成功删除 $modelName 模型字幕缓存，可重新识别'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _exportSrtFile() async {
    final entries = _generator.entries;
    if (entries.isEmpty) return;

    try {
      final srtContent = SubtitleGenerator.convertToSrt(entries);
      final srtBytes = Uint8List.fromList(utf8.encode(srtContent));

      // 提取建议的导出文件名
      String defaultName = 'subtitle.srt';
      if (widget.videoTitle != null && widget.videoTitle!.trim().isNotEmpty) {
        final sanitized = widget.videoTitle!.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
        defaultName = '$sanitized.srt';
      } else {
        final base = widget.videoPath.split(Platform.isWindows ? r'\' : '/').last;
        final dotIdx = base.lastIndexOf('.');
        if (dotIdx > 0) {
          defaultName = '${base.substring(0, dotIdx)}.srt';
        } else {
          defaultName = '$base.srt';
        }
      }

      final savedUri = await FilePicker.saveFile(
        dialogTitle: '导出 SRT 字幕文件',
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功导出 SRT 字幕至：$displayPath'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导出失败: $e'),
            backgroundColor: Colors.redAccent.shade700,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = _generator.isRunning;
    final entries = _generator.entries;

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AI 语音识别字幕',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '本地离线 Whisper 原声识别，忠实还原原音频字幕',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: .5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
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
                  // 1. 状态看板
                  _buildStatusCard(theme, isRunning, entries.length),

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
      bg = theme.colorScheme.primary.withValues(alpha: .12);
      accent = theme.colorScheme.primary;
      icon = Icons.graphic_eq_rounded;
      text = task?.statusMessage ?? _statusMessage ?? '正在处理音频...';
    } else if (_currentState == AsrState.completed) {
      bg = Colors.green.withValues(alpha: .12);
      accent = Colors.greenAccent;
      icon = Icons.check_circle_rounded;
      text = '识别已完成，已生成 $entryCount 条原语言字幕';
    } else if (_currentState == AsrState.error) {
      bg = Colors.red.withValues(alpha: .12);
      accent = Colors.redAccent;
      icon = Icons.error_outline_rounded;
      text = _statusMessage ?? '识别发生错误';
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

    final isRunning = _currentState == AsrState.preparing || _currentState == AsrState.processing;
    final models = [
      {'id': 'tiny', 'name': 'Tiny 极速版', 'desc': '约75MB · 速度最快'},
      {'id': 'base', 'name': 'Base 标准版', 'desc': '约140MB · 速度平衡'},
      {'id': 'small', 'name': 'Small 精确版', 'desc': '约460MB · 精确度高'},
    ];

    return Row(
      children: models.map((m) {
        final id = m['id']!;
        final isAvailable = _modelAvailability[id] ?? false;
        final isSelected = _selectedModel == id;
        final isCurrentRunning = isRunning && isSelected;
        final hasCache = _cachedModels.contains(id);

        return Expanded(
          child: GestureDetector(
            onTap: (isAvailable && !isRunning) ? () => _onSelectModel(id) : null,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primary.withValues(alpha: .2)
                    : const Color(0xFF262630),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : (isAvailable ? Colors.white12 : Colors.white10),
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          m['name']!,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            color: isAvailable ? Colors.white : Colors.white38,
                          ),
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (isCurrentRunning) ...[
                        const SizedBox(width: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.green,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('运行中', style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ] else if (hasCache) ...[
                        const SizedBox(width: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.teal.shade700,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('已缓存', style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    isAvailable
                        ? (hasCache ? '已生成专属缓存' : m['desc']!)
                        : '未检测到模型',
                    style: TextStyle(
                      fontSize: 10,
                      color: isAvailable ? Colors.white54 : Colors.redAccent.withValues(alpha: .7),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildLanguageSelector(ThemeData theme) {
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF262630),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.closed_caption_rounded, color: Colors.white70, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '在视频画面上显示原声字幕',
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
              tooltip: '导出为 SRT 字幕文件',
              icon: const Icon(Icons.file_download_outlined, color: Colors.white70, size: 20),
              onPressed: _exportSrtFile,
            ),
          ],
          const SizedBox(width: 4),
          IconButton(
            tooltip: '删除字幕缓存',
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.white60, size: 20),
            onPressed: (hasEntries || _cachedModels.contains(_selectedModel))
                ? _deleteSubtitlesWithConfirm
                : null,
          ),
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
              '识别字幕预览 (共 $totalCount 条)',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const Spacer(),
            Text(
              _previewExpanded ? '收起' : '展开查看',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.primary,
              ),
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
      height: 140,
      decoration: BoxDecoration(
        color: const Color(0xFF19191E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
        itemBuilder: (context, idx) {
          final e = entries[idx];
          final startStr = _formatDuration(e.start);
          return InkWell(
            onTap: widget.onSeekTo != null ? () => widget.onSeekTo!(e.start) : null,
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
                    child: Text(
                      e.text,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
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
    if (isRunning) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.redAccent.shade700,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: const Icon(Icons.stop_circle_rounded, size: 20),
        label: const Text('停止识别', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        onPressed: _stopTranscribing,
      );
    }

    final hasModel = _modelAvailability[_selectedModel] ?? false;
    final hasCache = _cachedModels.contains(_selectedModel);

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: hasCache ? Colors.white12 : theme.colorScheme.primary,
              foregroundColor: hasCache ? Colors.white38 : Colors.white,
              disabledBackgroundColor: Colors.white10,
              disabledForegroundColor: Colors.white30,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: Icon(
              hasCache ? Icons.check_circle_outline_rounded : Icons.mic_none_rounded,
              size: 20,
              color: hasCache ? Colors.white38 : Colors.white,
            ),
            label: Text(
              hasModel
                  ? (hasCache ? '已有字幕缓存' : '开始识别原音频')
                  : '未就绪 (缺少模型)',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: hasCache ? Colors.white38 : Colors.white,
              ),
            ),
            onPressed: (hasModel && !hasCache) ? _startTranscribing : null,
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
