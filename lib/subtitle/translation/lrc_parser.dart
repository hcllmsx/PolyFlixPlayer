/// LRC 歌词解析、序列化与双语合并工具。
library;

import '../subtitle_generator.dart';

/// LRC 歌词解析器与序列化器。
class LrcParser {
  const LrcParser._();

  static final RegExp _timeTagRegex = RegExp(
    r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _offsetTagRegex = RegExp(
    r'^\[offset:\s*([+-]?\d+)\s*\]$',
    caseSensitive: false,
  );
  static final RegExp _metaTagRegex = RegExp(r'^\[[a-zA-Z]{1,12}:.*\]$');
  static final RegExp _inlineWordTagRegex = RegExp(
    r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>',
  );

  /// 解析 LRC 文本为 [SubtitleEntry] 列表。
  ///
  /// 支持：
  /// - 标准 `[mm:ss.xx]` 与毫秒 `[mm:ss.xxx]` 时间标签
  /// - 单行多时间标签（如 `[00:12.00][01:20.00]副歌`）
  /// - `[offset:±ms]` 全局偏移
  /// - 同时间戳双行自动合并为原文 `text` 与译文 `translatedText`
  static List<SubtitleEntry> parse(String content) {
    if (content.trim().isEmpty) return const [];

    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    var offsetMs = 0;
    final rawItems = <({Duration start, int order, String text})>[];
    var orderSeq = 0;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final offsetMatch = _offsetTagRegex.firstMatch(line);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
        continue;
      }

      final tagMatches = _timeTagRegex.allMatches(line).toList();
      if (tagMatches.isEmpty) {
        // 纯元数据标签（[ti:..]、[ar:..] 等）直接跳过
        if (_metaTagRegex.hasMatch(line)) continue;
        continue;
      }

      final lyricText = line
          .replaceAll(_timeTagRegex, '')
          .replaceAll(_inlineWordTagRegex, '')
          .trim();
      if (lyricText.isEmpty) continue;

      for (final m in tagMatches) {
        final ts = _parseTimeMatch(m);
        if (ts == null) continue;
        rawItems.add((start: ts, order: orderSeq++, text: lyricText));
      }
    }

    if (rawItems.isEmpty) return const [];

    // 应用全局偏移（正数表示歌词提前，负数为延后）并保证不小于 0
    final adjusted = rawItems.map((item) {
      var ms = item.start.inMilliseconds - offsetMs;
      if (ms < 0) ms = 0;
      return (
        start: Duration(milliseconds: ms),
        order: item.order,
        text: item.text,
      );
    }).toList();

    adjusted.sort((a, b) {
      final byTime = a.start.compareTo(b.start);
      return byTime != 0 ? byTime : a.order.compareTo(b.order);
    });

    // 同时间戳（或差值 <= 20ms）的连续两行合并为原文 + 译文
    final merged = <({Duration start, String text, String? translatedText})>[];
    for (final item in adjusted) {
      if (merged.isNotEmpty) {
        final prev = merged.last;
        final diffMs = (item.start - prev.start).inMilliseconds.abs();
        if (diffMs <= 20 &&
            prev.translatedText == null &&
            item.text != prev.text) {
          merged[merged.length - 1] = (
            start: prev.start,
            text: prev.text,
            translatedText: item.text,
          );
          continue;
        }
      }
      merged.add((start: item.start, text: item.text, translatedText: null));
    }

    // 推算每条结束时间（供二分查找叠层渲染与时间区间对齐使用）
    final entries = <SubtitleEntry>[];
    for (var i = 0; i < merged.length; i++) {
      final cur = merged[i];
      final Duration end;
      if (i + 1 < merged.length) {
        final nextStart = merged[i + 1].start;
        end = nextStart > cur.start
            ? nextStart
            : cur.start + const Duration(seconds: 3);
      } else {
        end = cur.start + const Duration(seconds: 5);
      }
      entries.add(SubtitleEntry(
        start: cur.start,
        end: end,
        text: cur.text,
        translatedText: cur.translatedText,
      ));
    }
    return entries;
  }

  /// 序列化为标准 LRC 格式文本。
  static String serialize(
    List<SubtitleEntry> entries, {
    bool bilingual = false,
    bool translationOnly = false,
    String? headerComment,
  }) {
    final buffer = StringBuffer();
    final comment = headerComment?.trim() ?? '';
    if (comment.isNotEmpty) {
      for (final line in comment.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          buffer.writeln('[by:$trimmed]');
        }
      }
      buffer.writeln();
    }

    for (final entry in entries) {
      final ts = formatTimestamp(entry.start);
      final orig = _flattenLine(entry.text);
      final trans = _flattenLine(entry.translatedText ?? '');

      if (translationOnly) {
        final display = trans.isNotEmpty ? trans : orig;
        if (display.isNotEmpty) {
          buffer.writeln('$ts$display');
        }
      } else if (bilingual) {
        if (orig.isNotEmpty) {
          buffer.writeln('$ts$orig');
        }
        if (trans.isNotEmpty && trans != orig) {
          buffer.writeln('$ts$trans');
        }
      } else {
        if (orig.isNotEmpty) {
          buffer.writeln('$ts$orig');
        }
      }
    }

    return buffer.toString();
  }

  /// 将主/副字幕条目列表合成为供 `flutter_lyric` 解析的 LRC 字符串。
  ///
  /// - 若提供非空的 [secondary] 列表，按时间重叠 / 最邻近起点为每条 [primary] 匹配翻译行；
  /// - 若未提供 [secondary] 且 [primary] 条目自身带有 `translatedText`，同样写入翻译行。
  static String toLyricDocumentString({
    required List<SubtitleEntry> primary,
    List<SubtitleEntry>? secondary,
  }) {
    if (primary.isEmpty) return '';
    final buffer = StringBuffer();
    final hasSecondary = secondary != null && secondary.isNotEmpty;

    for (final entry in primary) {
      final mainText = _flattenLine(entry.text);
      if (mainText.isEmpty) continue;

      String? subText;
      if (hasSecondary) {
        final matched = _findMatchingEntry(entry, secondary);
        if (matched != null) {
          subText = _flattenLine(matched.text);
        }
      } else if (entry.translatedText != null &&
          entry.translatedText!.trim().isNotEmpty) {
        subText = _flattenLine(entry.translatedText!);
      }

      final ts = formatTimestamp(entry.start);
      buffer.writeln('$ts$mainText');
      if (subText != null && subText.isNotEmpty && subText != mainText) {
        buffer.writeln('$ts$subText');
      }
    }

    return buffer.toString();
  }

  /// 格式化时间为 `[mm:ss.xx]`。
  static String formatTimestamp(Duration d) {
    final safe = d.isNegative ? Duration.zero : d;
    final minutes = safe.inMinutes.toString().padLeft(2, '0');
    final seconds = (safe.inSeconds % 60).toString().padLeft(2, '0');
    final centis = ((safe.inMilliseconds % 1000) ~/ 10)
        .toString()
        .padLeft(2, '0');
    return '[$minutes:$seconds.$centis]';
  }

  static Duration? _parseTimeMatch(RegExpMatch match) {
    final minutes = int.tryParse(match.group(1) ?? '');
    final seconds = int.tryParse(match.group(2) ?? '');
    if (minutes == null || seconds == null) return null;

    var millis = 0;
    final frac = match.group(3);
    if (frac != null && frac.isNotEmpty) {
      final value = int.tryParse(frac);
      if (value == null) return null;
      if (frac.length == 1) {
        millis = value * 100;
      } else if (frac.length == 2) {
        millis = value * 10;
      } else {
        millis = value;
      }
    }

    return Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: millis,
    );
  }

  static String _flattenLine(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join(' ')
        .trim();
  }

  static SubtitleEntry? _findMatchingEntry(
    SubtitleEntry target,
    List<SubtitleEntry> candidates,
  ) {
    // 1. 优先找时间区间重叠最大的条目
    SubtitleEntry? bestOverlap;
    var maxOverlapMs = 0;
    for (final c in candidates) {
      final overlapStart = target.start > c.start ? target.start : c.start;
      final overlapEnd = target.end < c.end ? target.end : c.end;
      final overlapMs = (overlapEnd - overlapStart).inMilliseconds;
      if (overlapMs > maxOverlapMs) {
        maxOverlapMs = overlapMs;
        bestOverlap = c;
      }
    }
    if (bestOverlap != null) return bestOverlap;

    // 2. 回退：找开始时间差在 800ms 以内且最接近的条目
    SubtitleEntry? nearest;
    var minDiffMs = 801;
    for (final c in candidates) {
      final diffMs = (target.start - c.start).inMilliseconds.abs();
      if (diffMs < minDiffMs) {
        minDiffMs = diffMs;
        nearest = c;
      }
    }
    return nearest;
  }
}
