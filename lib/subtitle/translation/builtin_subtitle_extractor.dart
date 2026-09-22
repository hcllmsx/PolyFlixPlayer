/// 视频内置字幕流提取器。
///
/// 利用 ffmpeg 将视频内嵌的文本字幕流（SRT / ASS / SSA / VTT / MOV_TEXT 等）
/// 提取并无损转为标准的 SRT 文本条目列表。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import 'package:media_kit/media_kit.dart';

import '../../utils/native_file_helper.dart';
import '../subtitle_generator.dart';
import 'srt_parser.dart';
import 'translation_engine.dart';

class BuiltInSubtitleExtractor {
  const BuiltInSubtitleExtractor._();

  /// 判断指定的字幕轨是否为位图图形字幕（如 PGS、VobSub、DVB 等）。
  static bool isGraphicSubtitle(SubtitleTrack track) {
    final codec = (track.codec ?? '').toLowerCase();
    final title = (track.title ?? '').toLowerCase();
    const graphicKeywords = [
      'pgs',
      'hdmv',
      'dvd_subtitle',
      'vobsub',
      'dvb_subtitle',
      'dvb_teletext',
      'xsub',
      'subpicture',
    ];
    for (final kw in graphicKeywords) {
      if (codec.contains(kw) || title.contains(kw)) {
        return true;
      }
    }
    return false;
  }

  static String _cacheFileName(String videoPath, int subtitleIndex) {
    final normalized = videoPath.replaceAll('\\', '/');
    final seg = normalized.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => 'video');
    final dot = seg.lastIndexOf('.');
    final cleanName = (dot > 0 ? seg.substring(0, dot) : seg)
        .replaceAll(RegExp(r'[\\/:*?"<>| ]'), '_');
    final hash = md5.convert(utf8.encode('$videoPath#sub_$subtitleIndex')).toString().substring(0, 10);
    return 'builtin_raw_${cleanName}_sub_${subtitleIndex}_$hash.json';
  }

  /// 加载磁盘中已持久化的内置字幕原始文本缓存。
  static Future<List<SubtitleEntry>?> loadCachedSubtitles({
    required String videoPath,
    required int subtitleIndex,
  }) async {
    try {
      final cacheDir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!cacheDir.existsSync()) return null;
      final fileName = _cacheFileName(videoPath, subtitleIndex);
      final file = File('${cacheDir.path}${Platform.pathSeparator}$fileName');
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(content);
      final rawList = data['entries'] as List<dynamic>?;
      if (rawList == null || rawList.isEmpty) return null;

      return rawList.map((j) => SubtitleEntry.fromJson(j as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }

  /// 保存提取出的内置字幕条目到磁盘持久化缓存。
  static Future<void> saveCachedSubtitles({
    required String videoPath,
    required int subtitleIndex,
    required List<SubtitleEntry> entries,
  }) async {
    try {
      final cacheDir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final fileName = _cacheFileName(videoPath, subtitleIndex);
      final file = File('${cacheDir.path}${Platform.pathSeparator}$fileName');

      final data = {
        'version': 1,
        'videoPath': videoPath,
        'subtitleIndex': subtitleIndex,
        'createdAt': DateTime.now().toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(growable: false),
      };
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  /// 从视频中提取指定字幕轨索引的文本字幕。
  ///
  /// [videoPath]: 视频本地路径或 PFLX 本地流地址。
  /// [subtitleIndex]: 字幕轨在视频所有字幕流中的索引（0 代表第一条字幕流）。
  ///
  /// 成功时返回解析好的 [SubtitleEntry] 列表。
  /// 优先命中磁盘缓存（0ms 响应）；未命中时通过 ffmpeg 提取并自动落盘缓存。
  static Future<List<SubtitleEntry>> extractSubtitles({
    required String videoPath,
    required int subtitleIndex,
  }) async {
    // 1. 优先读取磁盘持久化缓存，避免重复调用 ffmpeg
    final cached = await loadCachedSubtitles(videoPath: videoPath, subtitleIndex: subtitleIndex);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final tempDir = NativeFileHelper.desktopSubtitleCacheDir();
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    final hash = md5.convert(utf8.encode('$videoPath#sub_$subtitleIndex')).toString().substring(0, 10);
    final tempSrtPath = '${tempDir.path}${Platform.pathSeparator}temp_extract_$hash.srt';
    final tempFile = File(tempSrtPath);

    try {
      // 全平台统一走内置 FFmpegKit（Windows/Linux 的原生库由插件在构建期提供）。
      // 用参数列表而非命令行字符串，避免路径含空格/中文时还要自己转义。
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        videoPath,
        '-map',
        '0:s:$subtitleIndex',
        '-f',
        'srt',
        tempSrtPath,
      ]);
      final returnCode = await session.getReturnCode();

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        throw TranslationException(_analyzeFfmpegError(logs ?? ''));
      }

      if (!await tempFile.exists() || await tempFile.length() == 0) {
        throw const TranslationException('未能从选中的字幕流中提取出有效字幕内容。');
      }

      final content = await tempFile.readAsString();
      final entries = SrtParser.parse(content);
      if (entries.isEmpty) {
        throw const TranslationException('选中的字幕轨内容为空或未能识别出文本时间轴。');
      }

      // 提取成功后自动写入磁盘持久化缓存
      await saveCachedSubtitles(
        videoPath: videoPath,
        subtitleIndex: subtitleIndex,
        entries: entries,
      );

      return entries;
    } finally {
      // 临时转换文件已解析并持久化，安全删除临时文件
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  static String _analyzeFfmpegError(String log) {
    final lower = log.toLowerCase();
    if (lower.contains('subtitle encoding currently only possible from text to text') ||
        lower.contains('hdmv_pgs_subtitle') ||
        lower.contains('dvd_subtitle') ||
        lower.contains('dvb_subtitle') ||
        lower.contains('xsub')) {
      return '该内置字幕为图形位图字幕（如 PGS/DVDSub），无法直接提取纯文本进行翻译。';
    }
    if (lower.contains('matches no streams') || lower.contains('stream map')) {
      return '未找到对应的字幕流，该视频可能没有该序号的字幕轨。';
    }
    return '提取内置字幕失败，格式可能不支持。';
  }

}
