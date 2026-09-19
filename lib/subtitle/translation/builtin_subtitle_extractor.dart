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

import '../../utils/native_file_helper.dart';
import '../subtitle_generator.dart';
import 'srt_parser.dart';
import 'translation_engine.dart';

class BuiltInSubtitleExtractor {
  const BuiltInSubtitleExtractor._();

  /// 从视频中提取指定字幕轨索引的文本字幕。
  ///
  /// [videoPath]: 视频本地路径或 PFLX 本地流地址。
  /// [subtitleIndex]: 字幕轨在视频所有字幕流中的索引（0 代表第一条字幕流）。
  ///
  /// 成功时返回解析好的 [SubtitleEntry] 列表。
  /// 若字幕为位图图形格式（如 PGS / VobSub）或提取失败，抛出 [TranslationException]。
  static Future<List<SubtitleEntry>> extractSubtitles({
    required String videoPath,
    required int subtitleIndex,
  }) async {
    final tempDir = NativeFileHelper.desktopSubtitleCacheDir();
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    final hash = md5.convert(utf8.encode('$videoPath#sub_$subtitleIndex')).toString().substring(0, 10);
    final tempSrtPath = '${tempDir.path}${Platform.pathSeparator}builtin_sub_$hash.srt';
    final tempFile = File(tempSrtPath);

    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        final ffmpegArgs = '-y -i "$videoPath" -map 0:s:$subtitleIndex -f srt "$tempSrtPath"';
        final session = await FFmpegKit.execute(ffmpegArgs);
        final returnCode = await session.getReturnCode();
        final logs = await session.getAllLogsAsString();

        if (!ReturnCode.isSuccess(returnCode)) {
          final errorMsg = _analyzeFfmpegError(logs ?? '');
          throw TranslationException(errorMsg);
        }
      } else {
        final ffmpegCmd = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
        final result = await Process.run(
          ffmpegCmd,
          [
            '-y',
            '-i',
            videoPath,
            '-map',
            '0:s:$subtitleIndex',
            '-f',
            'srt',
            tempSrtPath,
          ],
          runInShell: false,
        );

        if (result.exitCode != 0) {
          final stderr = result.stderr.toString();
          final errorMsg = _analyzeFfmpegError(stderr);
          throw TranslationException(errorMsg);
        }
      }

      if (!await tempFile.exists() || await tempFile.length() == 0) {
        throw const TranslationException('未能从选中的字幕流中提取出有效字幕内容。');
      }

      final content = await tempFile.readAsString();
      final entries = SrtParser.parse(content);
      if (entries.isEmpty) {
        throw const TranslationException('选中的字幕轨内容为空或未能识别出文本时间轴。');
      }

      return entries;
    } finally {
      // 临时文件已读取解析完毕，安全删除
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
