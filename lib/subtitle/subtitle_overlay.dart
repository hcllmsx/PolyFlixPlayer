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
    this.visible = true,
  });

  /// 字幕生成器实例。
  final SubtitleGenerator generator;

  /// 当前播放位置（由外部持续更新）。
  final Duration position;

  /// 是否显示。
  final bool visible;

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  SubtitleEntry? _currentEntry;
  StreamSubscription<AsrProgress>? _progressSub;
  String? _statusText;

  @override
  void initState() {
    super.initState();
    _progressSub = widget.generator.progressStream.listen(_onProgress);
    _updateEntry();
  }

  @override
  void didUpdateWidget(SubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
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
    setState(() {
      switch (progress.state) {
        case AsrState.preparing:
        case AsrState.processing:
          _statusText = progress.message;
          break;
        case AsrState.completed:
          _statusText = null;
          _updateEntry();
          break;
        case AsrState.error:
          _statusText = progress.message;
          break;
        case AsrState.idle:
          _statusText = null;
          break;
      }
    });
  }

  void _updateEntry() {
    final entry = widget.generator.getEntryAt(widget.position);
    if (entry != _currentEntry) {
      setState(() => _currentEntry = entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    // 正在处理中，显示状态提示
    if (_statusText != null && widget.generator.isRunning) {
      return _buildStatusBadge(_statusText!);
    }

    // 没有字幕内容
    if (_currentEntry == null) return const SizedBox.shrink();

    final entry = _currentEntry!;
    final text = entry.text;
    if (text.isEmpty) return const SizedBox.shrink();

    return Positioned(
      left: 16,
      right: 16,
      bottom: 80, // 留出控制条空间
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 原始文本
            _buildSubtitleText(text, isPrimary: true),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isPrimary ? Colors.white : Colors.white70,
          fontSize: isPrimary ? 16 : 14,
          fontWeight: isPrimary ? FontWeight.w500 : FontWeight.w400,
          height: 1.4,
          shadows: const [
            Shadow(offset: Offset(1, 1), blurRadius: 3, color: Colors.black54),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String text) {
    return Positioned(
      right: 16,
      top: 16,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
