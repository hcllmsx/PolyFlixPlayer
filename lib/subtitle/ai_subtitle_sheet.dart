import 'dart:async';

import 'package:flutter/material.dart';

import 'model_manager.dart';
import 'subtitle_generator.dart';

/// AI 语音识别字幕控制面板。
///
/// 支持配置识别模型、源语言选择、启动/停止识别、清空字幕与实时状态监控。
class AiSubtitleSheet extends StatefulWidget {
  const AiSubtitleSheet({
    super.key,
    required this.videoPath,
    required this.isAiSubtitleActive,
    required this.onToggleSubtitleActive,
    this.onSeekTo,
  });

  /// 当前视频源路径（本地文件或 PFLX 流式地址）。
  final String videoPath;

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

  String _selectedModel = 'tiny';
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
    _progressSub = _generator.progressStream.listen((p) {
      if (!mounted) return;
      setState(() {
        _currentState = p.state;
        _statusMessage = p.message;
      });
    });
    _checkModels();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _checkModels() async {
    final tinyReady = await ModelManager.instance.isModelDownloaded('tiny');
    final baseReady = await ModelManager.instance.isModelDownloaded('base');
    final smallReady = await ModelManager.instance.isModelDownloaded('small');
    if (!mounted) return;
    setState(() {
      _modelAvailability = {
        'tiny': tinyReady,
        'base': baseReady,
        'small': smallReady,
      };
      // 如果默认选中的模型不可用，自动切换到首个可用的模型
      if (!(_modelAvailability[_selectedModel] ?? false)) {
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

  void _startTranscribing() {
    if (_generator.isRunning) return;

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

    _generator.transcribeVideo(
      videoPath: widget.videoPath,
      modelId: _selectedModel,
      language: _selectedLanguage,
    );
  }

  void _stopTranscribing() {
    _generator.cancel();
  }

  void _clearSubtitles() {
    _generator.clear();
    setState(() {});
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
    Color bg = const Color(0xFF262630);
    Color accent = Colors.white54;
    IconData icon = Icons.info_outline_rounded;
    String text = '就绪，点击下方开始识别原音频';

    if (isRunning) {
      bg = theme.colorScheme.primary.withValues(alpha: .12);
      accent = theme.colorScheme.primary;
      icon = Icons.graphic_eq_rounded;
      text = _statusMessage ?? '正在处理音频...';
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
      child: Row(
        children: [
          if (isRunning)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
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

        return Expanded(
          child: GestureDetector(
            onTap: isAvailable ? () => setState(() => _selectedModel = id) : null,
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
                  Text(
                    m['name']!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      color: isAvailable ? Colors.white : Colors.white38,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    isAvailable ? m['desc']! : '未检测到模型',
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
          const SizedBox(width: 6),
          IconButton(
            tooltip: '清空字幕',
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.white60, size: 20),
            onPressed: _clearSubtitles,
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

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.mic_none_rounded, size: 20),
            label: Text(
              hasModel ? '开始识别原音频' : '未就绪 (缺少模型)',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            onPressed: hasModel ? _startTranscribing : null,
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
