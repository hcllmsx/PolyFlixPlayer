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
              label: const Text('清空已完成', style: TextStyle(fontSize: 12)),
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

    return Container(
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
          Row(
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
              const Spacer(),
              if (task.hasPendingTranslation) ...[
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: .2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '已预约翻译',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.tealAccent,
                    ),
                  ),
                ),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isTranslation
                      ? Colors.deepPurple.withValues(alpha: .2)
                      : scheme.primary.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  task.modelDisplayName,
                  style: TextStyle(
                    fontSize: 11,
                    color: isTranslation
                        ? Colors.deepPurpleAccent.shade100
                        : scheme.primary,
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
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (running) ...[
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                  ),
                  icon: const Icon(Icons.cancel_outlined, size: 16),
                  label: const Text('取消'),
                  onPressed: () =>
                      AiTaskManager.instance.cancelTask(task.videoPath),
                ),
                const SizedBox(width: 4),
              ] else ...[
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('删除'),
                  onPressed: onRemove,
                ),
                const SizedBox(width: 4),
              ],
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
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
