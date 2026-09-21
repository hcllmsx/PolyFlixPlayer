/// 「任务列表」面板：AI 语音识别任务的进行中状态与历史记录。
///
/// 设计要点：
///  - 任务完成后**不会自动消失**，记录一直留在这里，由用户点「删除」清理；
///  - 进行中的任务显示实时进度与**已耗时**（每秒刷新），结束后显示总耗时；
///  - 同一个视频重新识别会产生新记录，旧记录保留可回看。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../subtitle/ai_task_manager.dart';
import '../subtitle/subtitle_generator.dart';
import '../utils/app_toast.dart';

/// 任务列表面板（首页「任务列表」选项卡的内容）。
class AiTaskPanel extends StatefulWidget {
  const AiTaskPanel({
    super.key,
    required this.onOpenVideo,
    this.shrinkWrap = false,
    this.onCardTouch,
  });

  /// 点「播放」时用视频路径 + 标题打开播放页。
  final void Function(String path, String name) onOpenVideo;

  /// 嵌在外层滚动视图里时置 true：内容用 Column 排布，自己不滚动。
  final bool shrinkWrap;

  /// 点在任务卡片上时的回调（供外层手势识别排除卡片区域）。
  final VoidCallback? onCardTouch;

  @override
  State<AiTaskPanel> createState() => _AiTaskPanelState();
}

class _AiTaskPanelState extends State<AiTaskPanel> {
  /// 有正在跑的任务时每秒刷新一次，让"已耗时"实时走动。
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    AiTaskManager.instance.addListener(_onManagerChanged);
    _syncTicker();
  }

  @override
  void dispose() {
    AiTaskManager.instance.removeListener(_onManagerChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onManagerChanged() {
    _syncTicker();
    if (mounted) setState(() {});
  }

  void _syncTicker() {
    final needTick = AiTaskManager.instance.hasActiveTasks;
    if (needTick && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needTick && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  Future<void> _confirmClearFinished() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空任务记录'),
        content: const Text(
          '确定要清空所有已结束的任务记录吗？\n'
          '（已生成的字幕缓存不受影响）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      AiTaskManager.instance.clearFinishedTasks();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tasks = AiTaskManager.instance.allTasks;
    final finishedCount = tasks.where((t) => t.isFinished).length;

    if (tasks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.checklist_rtl_rounded,
                size: 44,
                color: scheme.onSurfaceVariant.withValues(alpha: .5),
              ),
              const SizedBox(height: 12),
              Text(
                '暂无识别任务',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                '在播放页点 AI 语音字幕按钮开始识别，任务会出现在这里。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: .75),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final children = <Widget>[
      if (finishedCount > 0)
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.cleaning_services_outlined, size: 16),
              label: const Text('一键清空', style: TextStyle(fontSize: 12)),
              onPressed: _confirmClearFinished,
            ),
          ),
        ),
      for (final task in tasks)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Listener(
            onPointerDown: (_) => widget.onCardTouch?.call(),
            child: _AiTaskTile(
              task: task,
              onOpenVideo: widget.onOpenVideo,
              onRemove: () => AiTaskManager.instance.removeTask(task.id),
            ),
          ),
        ),
      const SizedBox(height: 24),
    ];

    if (widget.shrinkWrap) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return ListView(padding: EdgeInsets.zero, children: children);
  }
}

/// 单条任务卡片。
class _AiTaskTile extends StatelessWidget {
  const _AiTaskTile({
    required this.task,
    required this.onOpenVideo,
    required this.onRemove,
  });

  final AiTask task;
  final void Function(String path, String name) onOpenVideo;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = task.isRunning;

    final isTranslation = task.taskType == AiTaskType.translation;
    final (
      Color stateColor,
      IconData stateIcon,
      String stateLabel,
    ) = switch (task) {
      // 中断 / 取消的任务状态是 idle，必须排在最后的默认分支之前
      _ when task.isInterrupted => (
        scheme.onSurfaceVariant,
        Icons.hourglass_disabled_rounded,
        '已中断',
      ),
      _ when task.isCancelled => (
        scheme.onSurfaceVariant,
        Icons.cancel_outlined,
        '已取消',
      ),
      // 点过「翻译已有」：正在等当前这一段跑完就停（带等待秒数，免得像卡住了）
      _ when task.stopRequested && running => (
        Colors.amber.shade700,
        Icons.hourglass_top_rounded,
        '收尾中 · 已等 ${task.stopRequestedElapsed.inSeconds}s',
      ),
      // 阶段翻译已完成，正在等自动续跑剩余部分
      _ when task.autoResumeScheduled => (
        Colors.amber.shade700,
        Icons.hourglass_bottom_rounded,
        '待自动继续',
      ),
      // 点过「翻译已有」：识别停在断点上，剩余部分可以续跑
      _ when task.canResume => (
        Colors.amber.shade700,
        Icons.pause_circle_outline_rounded,
        '已暂停识别',
      ),
      _ when task.state == AsrState.completed => (
        Colors.green,
        Icons.check_circle_rounded,
        isTranslation ? '翻译完成' : '已完成',
      ),
      _ when task.state == AsrState.error => (
        scheme.error,
        Icons.error_outline_rounded,
        isTranslation ? '翻译失败' : '识别失败',
      ),
      _ => (
        scheme.primary,
        isTranslation ? Icons.g_translate_rounded : Icons.autorenew_rounded,
        isTranslation ? '翻译中' : '识别中',
      ),
    };

    final card = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: running
              ? scheme.primary.withValues(alpha: .45)
              : scheme.outlineVariant.withValues(alpha: .35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态标签可能同时挤着好几个（待自动继续 + 已预约翻译 + 模型名…），
          // 小屏一行放不下会横向溢出，所以用 Wrap：放不下自动换到下一行。
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(stateIcon, size: 16, color: stateColor),
                  const SizedBox(width: 6),
                  Text(
                    stateLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: stateColor,
                    ),
                  ),
                ],
              ),
              if (task.hasPendingTranslation)
                Builder(
                  builder: (context) {
                    final isDark = Theme.of(context).brightness == Brightness.dark;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.teal.shade900.withValues(alpha: 0.65)
                            : Colors.teal.shade100,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isDark
                              ? Colors.teal.shade300.withValues(alpha: 0.6)
                              : Colors.teal.shade600.withValues(alpha: 0.6),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        '已预约翻译',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isDark ? const Color(0xFF64FFDA) : const Color(0xFF004D40),
                        ),
                      ),
                    );
                  },
                ),
              if (task.autoResumeScheduled)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '稍后自动继续',
                    style: TextStyle(fontSize: 11, color: Colors.amber.shade800),
                  ),
                ),
              if (task.isSuperseded)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '已被新版本取代',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              // 徽章本身可能很长（翻译任务会带上"来源 → 目标语言"），限个宽，
              // 超出省略，免得单个徽章就超过整行可用宽度
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isTranslation
                        ? Colors.deepPurple.withValues(alpha: .2)
                        : scheme.primary.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    task.modelDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: isTranslation
                          ? Colors.deepPurpleAccent.shade100
                          : scheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            task.videoTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          if (running) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.percent > 0 ? task.percent : null,
                minHeight: 5,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            task.statusMessage ?? (task.isFinished ? stateLabel : '正在处理中…'),
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            // 进行中显示实时耗时，结束后为固定总耗时
            '已耗时 ${AiTask.formatDuration(task.elapsed)}'
            ' · 开始于 ${_hhmm(task.startTime)}'
            '${task.entryCount > 0 ? (isTranslation ? ' · 已翻译 ${task.entryCount} 条字幕' : ' · 已生成 ${task.entryCount} 条字幕') : ''}',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: scheme.onSurfaceVariant.withValues(alpha: .75),
            ),
          ),
          const SizedBox(height: 4),
          // 用 Wrap 而不是 Row：窄面板里按钮宁可换行也不要挤成溢出
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              // 已停在断点上：把剩余的音频继续识别完
              if (task.canResume)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.fast_forward_rounded, size: 16),
                  label: const Text('继续识别'),
                  onPressed: () => AiTaskManager.instance.resumeTask(task),
                ),
              // 点过「翻译已有」，正在等当前片段跑完：给一个明确的"已收到"信号，
              // 否则按钮一消失、进度条正常在动，用户会以为没点中
              if (task.stopRequested && running)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  label: Text('收尾中 ${task.stopRequestedElapsed.inSeconds}s…'),
                  onPressed: null,
                ),
              // 翻译没跑成的重来一次：先去设置页把 Key 改对，顺手也能换个目标语言
              if (_canRetryTranslation(task))
                Tooltip(
                  message: '按当前设置重新翻译同一批字幕：\n'
                      '· 目标语言取现在设置里的值，改过就按新的来\n'
                      '· 已经翻好的条目按原文复用，不会重复消耗额度',
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('重试'),
                    onPressed: () => _onRetryTranslation(context, task),
                  ),
                ),
              // 识别途中：停止后续识别，先拿已识别的部分去翻译
              if (_canTranslateExisting(task))
                Tooltip(
                  message: '先用已识别的 ${task.entryCount} 条字幕开始翻译：'
                      '识别是一段一段跑的，等当前这一段跑完就停（最长约 1 分钟）；'
                      '剩余部分之后会自动继续识别',
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.g_translate_rounded, size: 16),
                    label: const Text('翻译已有'),
                    onPressed: () => _onTranslateExisting(context, task),
                  ),
                ),
              if (running)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                  ),
                  icon: const Icon(Icons.cancel_outlined, size: 16),
                  label: const Text('取消'),
                  onPressed: () =>
                      AiTaskManager.instance.cancelTask(task.videoPath),
                )
              else
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('删除'),
                  onPressed: onRemove,
                ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: const Text('播放'),
                // 用 cacheKey（源文件路径）而不是 videoPath 打开：PFLX 任务的
                // videoPath 是当次会话的随机端口流地址，事后再点必然打不开。
                // 普通视频两者相同，行为不变。
                onPressed: () => onOpenVideo(task.cacheKey, task.videoTitle),
              ),
            ],
          ),
        ],
      ),
    );

    // 已被后续翻译覆盖的记录：标灰保留，供回看但不代表当前缓存内容
    if (task.isSuperseded) {
      return Opacity(opacity: 0.5, child: card);
    }
    return card;
  }

  /// 是否给出「翻译已有」按钮。
  ///
  /// 短音频（≤120 秒）是整体一次性识别，中途停不下来，所以不给这个按钮；
  /// 另外音频总时长要等进度回调上来才知道，开头几秒同样不显示。
  static bool _canTranslateExisting(AiTask task) =>
      task.taskType == AiTaskType.transcription &&
      task.isRunning &&
      !task.stopRequested &&
      task.entryCount > 0 &&
      task.totalDuration.inSeconds > 120;

  /// 翻译失败 / 被取消 / 被退出打断的记录允许重试。
  ///
  /// 已被后续翻译取代的记录不给：它的产物早被覆盖，重试没有意义。
  static bool _canRetryTranslation(AiTask task) =>
      task.taskType == AiTaskType.translation &&
      !task.isRunning &&
      !task.isSuperseded &&
      (task.state == AsrState.error || task.isCancelled || task.isInterrupted);

  /// 翻译 Key 填错是最常见的失败原因，提示里直接指到设置页，省得用户自己猜。
  static String _describeTranslationError(Object e) {
    final raw = e.toString();
    if (raw.contains('未配置') || raw.contains('凭据')) {
      return '翻译服务还没配好：请到「设置 → 翻译服务」填写正确的 Key 后重试';
    }
    return '重试失败：$raw';
  }

  static Future<void> _onTranslateExisting(
    BuildContext context,
    AiTask task,
  ) async {
    try {
      AiTaskManager.instance.requestTranslateExisting(task);
      // 浮层提示由 requestTranslateExisting 里的 onInfo 统一弹出（AppToast 同一
      // 时刻只保留一条，这里再弹会把那条带秒数说明的长提示顶掉）。
    } catch (e) {
      if (context.mounted) {
        AppToast.show(context, _describeTranslationError(e), isError: true);
      }
    }
  }

  static Future<void> _onRetryTranslation(
    BuildContext context,
    AiTask task,
  ) async {
    try {
      await AiTaskManager.instance.retryTranslationTask(task);
      // 成功 / 语言变更的反馈由管理器里的 onInfo 统一弹
    } catch (e) {
      if (context.mounted) {
        AppToast.show(
          context,
          _describeTranslationError(e),
          isError: true,
          duration: const Duration(seconds: 8),
        );
      }
    }
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
