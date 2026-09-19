/// SRT 格式字幕解析与导出工具。
library;

import '../subtitle_generator.dart';

/// SRT 解析器与序列化器。
class SrtParser {
  const SrtParser._();

  /// 解析 SRT 文本为 [SubtitleEntry] 列表。
  static List<SubtitleEntry> parse(String content) {
    if (content.trim().isEmpty) return const [];

    final lines = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final entries = <SubtitleEntry>[];

    int i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        i++;
        continue;
      }

      // 如果当前行是序号数字，看下一行是否是时间戳；如果当前行本身就是时间戳，也支持容错
      String timeLine = '';
      if (_isTimestampLine(line)) {
        timeLine = line;
        i++;
      } else if (int.tryParse(line) != null && (i + 1) < lines.length && _isTimestampLine(lines[i + 1].trim())) {
        timeLine = lines[i + 1].trim();
        i += 2;
      } else {
        i++;
        continue;
      }

      final timestamps = _parseTimestamps(timeLine);
      if (timestamps == null) {
        continue;
      }

      // 收集内容文本行，直到遇到空行或文件结尾
      final textLines = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        textLines.add(lines[i]);
        i++;
      }

      final text = textLines.join('\n').trim();
      if (text.isNotEmpty) {
        entries.add(SubtitleEntry(
          start: timestamps.$1,
          end: timestamps.$2,
          text: text,
        ));
      }
    }

    return entries;
  }

  /// 序列化为 SRT 格式。
  ///
  /// [bilingual]: 是否输出双语（译文 + 换行 + 原文）
  /// [translationOnly]: 是否仅输出译文（当译文为空时回退原文）
  /// [headerComment]: 写在文件开头（第一条字幕之前）的说明文字，
  /// 播放器会忽略第一条字幕前的内容，不会显示；用文本编辑器打开可见。
  static String serialize(
    List<SubtitleEntry> entries, {
    bool bilingual = false,
    bool translationOnly = false,
    String? headerComment,
  }) {
    final buffer = StringBuffer();

    if (headerComment != null && headerComment.trim().isNotEmpty) {
      buffer.writeln(headerComment.trim());
      buffer.writeln();
    }

    int index = 1;

    for (final entry in entries) {
      String display;
      if (translationOnly) {
        display = (entry.translatedText != null && entry.translatedText!.isNotEmpty)
            ? entry.translatedText!
            : entry.text;
      } else if (bilingual && entry.translatedText != null && entry.translatedText!.isNotEmpty) {
        display = '${entry.translatedText!}\n${entry.text}';
      } else {
        display = entry.text;
      }

      buffer.writeln(index);
      buffer.writeln('${_formatTimestamp(entry.start)} --> ${_formatTimestamp(entry.end)}');
      buffer.writeln(display);
      buffer.writeln();
      index++;
    }

    return buffer.toString();
  }

  static bool _isTimestampLine(String line) {
    return line.contains('-->');
  }

  /// 解析 "00:01:23,456 --> 00:01:26,789"
  static (Duration, Duration)? _parseTimestamps(String line) {
    final parts = line.split('-->');
    if (parts.length != 2) return null;

    final start = _parseSingleTimestamp(parts[0].trim());
    final end = _parseSingleTimestamp(parts[1].trim());
    if (start == null || end == null) return null;

    return (start, end);
  }

  static Duration? _parseSingleTimestamp(String s) {
    // 兼容 00:00:00,000 或 00:00:00.000
    final normalized = s.replaceAll(',', '.');
    final segs = normalized.split(':');
    if (segs.length < 2) return null;

    try {
      int hours = 0;
      int minutes = 0;
      double seconds = 0.0;

      if (segs.length == 3) {
        hours = int.parse(segs[0]);
        minutes = int.parse(segs[1]);
        seconds = double.parse(segs[2]);
      } else if (segs.length == 2) {
        minutes = int.parse(segs[0]);
        seconds = double.parse(segs[1]);
      }

      final totalMs = (hours * 3600000) + (minutes * 60000) + (seconds * 1000).round();
      return Duration(milliseconds: totalMs);
    } catch (_) {
      return null;
    }
  }

  static String _formatTimestamp(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds,$ms';
  }
}
