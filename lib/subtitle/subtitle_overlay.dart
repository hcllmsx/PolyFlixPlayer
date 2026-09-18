/// AI 字幕叠加层 Widget。
///
/// 独立于 media_kit 的内置字幕渲染，叠加在视频画面上方。
/// 两者可以同时显示：内置字幕由 media_kit 渲染在视频帧上，
/// AI 字幕由 Flutter Widget 叠加在 Video Widget 上层。
///
/// 第一阶段：单行显示（仅识别文本）。
/// 第二阶段扩展为双行（原文 + 译文）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'subtitle_generator.dart';

/// AI 字幕叠加层。
///
/// 用法：将此 Widget 放在 Video Widget 上方的 Stack 中。
/// 通过 [position] 驱动字幕内容随播放进度更新。
class SubtitleOverlay extends StatefulWidget {
  const SubtitleOverlay({
    super.key,
    required this.generator,
    required this.position,
    this.videoPath,
    this.visible = true,
    this.isPrimary = true,
    this.bottomOffset = 80,
  });

  /// 字幕生成器实例。
  final SubtitleGenerator generator;

  /// 当前播放位置（由外部持续更新）。
  final Duration position;

  /// 当前播放视频路径/地址，用于确认生成器里的字幕是否真正属于本视频。
  final String? videoPath;

  /// 是否显示。
  final bool visible;

  /// 是否作为"主字幕"呈现。
  ///
  /// 只有当视频没有内置字幕（也没有翻译字幕）在显示时，AI 字幕才会升为主字幕，
  /// 此时字号更大、位置更贴近画面底部；否则作为副字幕抬头显示、字号略小。
  final bool isPrimary;

  /// 叠层距底部的间距，由外部按主/副身份给出，避免与 mpv 渲染的内置字幕重叠。
  final double bottomOffset;

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  SubtitleEntry? _currentEntry;
  StreamSubscription<AsrProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _progressSub = widget.generator.progressStream.listen(_onProgress);
    _updateEntry();
  }

  @override
  void didUpdateWidget(SubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position ||
        oldWidget.videoPath != widget.videoPath) {
      _updateEntry();
    }
    if (oldWidget.generator != widget.generator) {
      _progressSub?.cancel();
      _progressSub = widget.generator.progressStream.listen(_onProgress);
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  void _onProgress(AsrProgress progress) {
    if (!mounted) return;
    if (progress.state == AsrState.completed || progress.state == AsrState.idle) {
      _updateEntry();
    }
  }

  void _updateEntry() {
    // 画面字幕严格归属校验：如果生成器里当前装的不是本视频的字幕，绝对不在画面上显示！
    if (widget.videoPath != null &&
        !widget.generator.holdsEntriesFor(widget.videoPath!)) {
      if (_currentEntry != null) {
        setState(() => _currentEntry = null);
      }
      return;
    }
    final entry = widget.generator.getEntryAt(widget.position);
    if (entry != _currentEntry) {
      setState(() => _currentEntry = entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    // 没有字幕内容
    if (_currentEntry == null) return const SizedBox.shrink();

    final entry = _currentEntry!;
    final text = entry.text;
    if (text.isEmpty) return const SizedBox.shrink();

    return Positioned(
      left: 16,
      right: 16,
      bottom: widget.bottomOffset, // 留出控制条空间
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 原始文本
            _buildSubtitleText(text, isPrimary: widget.isPrimary),
            // 翻译文本（第二阶段启用）
            if (entry.translatedText != null && entry.translatedText!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _buildSubtitleText(
                  entry.translatedText!,
                  isPrimary: false,
                ),
              ),
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
          // 副字幕略小一档，与主字幕在视觉上分层
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
