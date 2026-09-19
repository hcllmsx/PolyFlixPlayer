/// 画面字幕叠加层 Widget。
///
/// 统一由 Flutter 渲染在视频画面上方，支持独立的主字幕（上方，大号纯白）
/// 与副字幕（下方，略小分层），彻底杜绝与视频底层原生字幕的重叠冲突。
library;

import 'package:flutter/material.dart';

import 'subtitle_generator.dart';

/// 画面字幕叠加层。
///
/// 用法：将此 Widget 放在 Video Widget 上方的 Stack 中。
/// 通过 [position] 驱动字幕内容随播放进度高效更新。
class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    super.key,
    required this.position,
    this.primaryEntries,
    this.secondaryEntries,
    this.visible = true,
    this.bottomOffset = 80,
  });

  /// 当前播放位置。
  final Duration position;

  /// 主字幕条目列表（显示在上方，大字号、主要阅读）。
  final List<SubtitleEntry>? primaryEntries;

  /// 副字幕条目列表（显示在下方，略小字号、辅助对照）。
  final List<SubtitleEntry>? secondaryEntries;

  /// 是否显示。
  final bool visible;

  /// 叠层距底部的间距（默认 80，当主字幕走底层的图形字幕时可抬高为 132）。
  final double bottomOffset;

  /// 基于二分查找高效匹配当前时间戳所对应的字幕文本。
  static String? _findTextAt(List<SubtitleEntry>? entries, Duration pos) {
    if (entries == null || entries.isEmpty) return null;
    int low = 0;
    int high = entries.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final e = entries[mid];
      if (pos < e.start) {
        high = mid - 1;
      } else if (pos > e.end) {
        low = mid + 1;
      } else {
        return e.text;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final primaryText = _findTextAt(primaryEntries, position);
    final secondaryText = _findTextAt(secondaryEntries, position);

    final hasPrimary = primaryText != null && primaryText.isNotEmpty;
    final hasSecondary = secondaryText != null && secondaryText.isNotEmpty;

    if (!hasPrimary && !hasSecondary) return const SizedBox.shrink();

    return Positioned(
      left: 16,
      right: 16,
      bottom: bottomOffset,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. 主字幕（显示在上方，字号 16，纯白高亮）
            if (hasPrimary)
              _buildSubtitleText(primaryText, isPrimary: true),

            // 两行之间的视觉微间距
            if (hasPrimary && hasSecondary)
              const SizedBox(height: 4),

            // 2. 副字幕（显示在下方，字号 14.5，微暗白色分层）
            if (hasSecondary)
              _buildSubtitleText(secondaryText, isPrimary: false),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitleText(String text, {required bool isPrimary}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .68),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isPrimary ? Colors.white : Colors.white.withValues(alpha: .88),
          // 主字幕 16px w500，副字幕 14.5px w400，从上往下清晰分层
          fontSize: isPrimary ? 16 : 14.5,
          fontWeight: isPrimary ? FontWeight.w500 : FontWeight.w400,
          height: 1.4,
          shadows: const [
            Shadow(offset: Offset(1, 1), blurRadius: 3, color: Colors.black54),
          ],
        ),
      ),
    );
  }
}
