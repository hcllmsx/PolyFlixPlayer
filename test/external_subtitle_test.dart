import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:polyflix_player/subtitle/external_subtitle.dart';
import 'package:polyflix_player/subtitle/subtitle_generator.dart';

void main() {
  group('ExternalSubtitleLoader 基本信息', () {
    test('扩展名 / 渲染类别 / 支持判定', () {
      expect(ExternalSubtitleLoader.extensionOf(r'D:\subs\movie.CHS.SRT'), 'srt');
      expect(ExternalSubtitleLoader.extensionOf('/subs/movie'), isNull);
      expect(ExternalSubtitleLoader.extensionOf('/subs/movie.'), isNull);

      expect(ExternalSubtitleLoader.isSupported('/subs/movie.srt'), isTrue);
      expect(ExternalSubtitleLoader.isSupported('/subs/movie.ASS'), isTrue);
      expect(ExternalSubtitleLoader.isSupported('/subs/movie.vtt'), isTrue);
      expect(ExternalSubtitleLoader.isSupported('/subs/movie.sup'), isTrue);
      expect(ExternalSubtitleLoader.isSupported('/subs/movie.idx'), isTrue);
      expect(ExternalSubtitleLoader.isSupported('/subs/movie.sub'), isTrue);
      expect(ExternalSubtitleLoader.isSupported('/subs/movie.txt'), isFalse);

      expect(
        ExternalSubtitleLoader.kindOf('/subs/movie.srt'),
        ExternalSubtitleKind.text,
      );
      expect(
        ExternalSubtitleLoader.kindOf('/subs/movie.vtt'),
        ExternalSubtitleKind.text,
      );
      expect(
        ExternalSubtitleLoader.kindOf('/subs/movie.ASS'),
        ExternalSubtitleKind.effects,
      );
      expect(
        ExternalSubtitleLoader.kindOf('/subs/movie.ssa'),
        ExternalSubtitleKind.effects,
      );
      // 图形位图字幕：PGS(.sup) / VobSub(.idx + .sub)
      expect(
        ExternalSubtitleLoader.kindOf('/subs/movie.sup'),
        ExternalSubtitleKind.graphics,
      );
      expect(
        ExternalSubtitleLoader.kindOf('/subs/movie.idx'),
        ExternalSubtitleKind.graphics,
      );
      expect(
        ExternalSubtitleLoader.kindOf('/subs/movie.sub'),
        ExternalSubtitleKind.graphics,
      );
    });

    test('交给 mpv 的外挂轨标题带上可识别前缀', () {
      final title = ExternalSubtitleLoader.trackTitleFor(r'D:\subs\movie.srt');
      expect(title.contains('movie.srt'), isTrue);
      // 内置字幕列表就是靠这个前缀把外挂轨剔除掉的
      expect(
        ExternalSubtitleLoader.isExternalTrack(
          SubtitleTrack.uri('/tmp/x.srt', title: title),
        ),
        isTrue,
      );
      expect(
        ExternalSubtitleLoader.isExternalTrack(
          const SubtitleTrack('3', '简体中文', 'zh'),
        ),
        isFalse,
      );
      expect(
        ExternalSubtitleLoader.isExternalTrack(const SubtitleTrack('no', null, null)),
        isFalse,
      );
    });
  });

  group('外挂字幕条目解析', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('polyflix_ext_sub');
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('UTF-8 的 srt：剥样式标签、丢空条目、按开始时间排序', () async {
      final file = File('${dir.path}${Platform.pathSeparator}movie.srt');
      file.writeAsStringSync(
        '2\n'
        '00:00:10,000 --> 00:00:12,000\n'
        '<i>第二条</i>\n'
        '\n'
        '1\n'
        '00:00:01,000 --> 00:00:03,000\n'
        '{\\an8}第一条\\N换行\n'
        '\n'
        '3\n'
        '00:00:20,000 --> 00:00:21,000\n'
        '   \n',
        encoding: utf8,
      );

      final entries = await ExternalSubtitleLoader.loadEntries(file.path);
      expect(entries.length, 2);
      expect(entries[0].text, '第一条\n换行');
      expect(entries[0].start, const Duration(seconds: 1));
      expect(entries[1].text, '第二条');
      expect(entries[1].start, const Duration(seconds: 10));
    });

    test('解析时可以直接带上时间轴偏移', () async {
      final file = File('${dir.path}${Platform.pathSeparator}movie.srt');
      file.writeAsStringSync(
        '1\n'
        '00:00:01,000 --> 00:00:02,000\n'
        '一句话\n',
        encoding: utf8,
      );

      final entries = await ExternalSubtitleLoader.loadEntries(
        file.path,
        offset: const Duration(milliseconds: 1500),
      );
      expect(entries.single.start, const Duration(milliseconds: 2500));
      expect(entries.single.end, const Duration(milliseconds: 3500));
    });

    test('文件不存在时抛出可读异常', () {
      expect(
        () => ExternalSubtitleLoader.loadEntries(
          '${dir.path}${Platform.pathSeparator}nope.srt',
        ),
        throwsA(isA<ExternalSubtitleException>()),
      );
    });
  });

  group('时间轴偏移', () {
    final entries = [
      SubtitleEntry(
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 2),
        text: 'a',
      ),
      SubtitleEntry(
        start: const Duration(seconds: 5),
        end: const Duration(seconds: 6),
        text: 'b',
      ),
    ];

    test('正数整体延后', () {
      final shifted = ExternalSubtitleLoader.applyOffset(
        entries,
        const Duration(milliseconds: 1500),
      );
      expect(shifted[0].start, const Duration(milliseconds: 2500));
      expect(shifted[1].end, const Duration(milliseconds: 7500));
    });

    test('负数整体提前且不出现负时间', () {
      final shifted = ExternalSubtitleLoader.applyOffset(
        entries,
        const Duration(seconds: -3),
      );
      expect(shifted[0].start, Duration.zero);
      expect(shifted[0].end, Duration.zero);
      expect(shifted[1].start, const Duration(seconds: 2));
    });

    test('零偏移原样返回', () {
      final unchanged =
          ExternalSubtitleLoader.applyOffset(entries, Duration.zero);
      expect(unchanged[0], same(entries[0]));
    });
  });

  group('同目录同名外挂字幕匹配', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('polyflix_ext_scan');
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    File touch(String name) =>
        File('${dir.path}${Platform.pathSeparator}$name')..writeAsStringSync('x');

    test('命中同名与语言后缀，忽略其它文件与非字幕扩展名', () async {
      final video = touch('movie.mp4');
      touch('movie.ass');
      touch('movie.zh-cn.srt');
      touch('movie_chs.vtt');
      touch('movie.txt');
      touch('movie2.srt');
      touch('other.srt');

      final found = await ExternalSubtitleLoader.findSiblingSubtitles(
        video.path,
      );
      expect(
        found.map(ExternalSubtitleLoader.fileNameOf).toList(),
        ['movie.ass', 'movie.zh-cn.srt', 'movie_chs.vtt'],
      );
    });

    test('PFLX 产物支持 movie.pflx.srt 这种带全名的写法', () async {
      final video = touch('movie.pflx');
      touch('movie.pflx.srt');

      final found = await ExternalSubtitleLoader.findSiblingSubtitles(
        video.path,
      );
      expect(found.length, 1);
      expect(ExternalSubtitleLoader.fileNameOf(found.first), 'movie.pflx.srt');
    });

    test('图形字幕（.sup）也能被同名匹配到', () async {
      final video = touch('movie.mp4');
      touch('movie.sup');

      final found = await ExternalSubtitleLoader.findSiblingSubtitles(
        video.path,
      );
      expect(
        found.map(ExternalSubtitleLoader.fileNameOf).toList(),
        ['movie.sup'],
      );
    });

    test('VobSub：递过来 .sub 时换成同名的 .idx（有 .idx 才换）', () async {
      final sub = touch('movie.sub');
      expect(
        ExternalSubtitleLoader.fileNameOf(
          await ExternalSubtitleLoader.resolveCompanion(sub.path),
        ),
        'movie.sub',
      );

      touch('movie.idx');
      expect(
        ExternalSubtitleLoader.fileNameOf(
          await ExternalSubtitleLoader.resolveCompanion(sub.path),
        ),
        'movie.idx',
      );
      // 非 .sub 一律原样返回
      final sup = touch('movie.sup');
      expect(await ExternalSubtitleLoader.resolveCompanion(sup.path), sup.path);
    });

    test('目录里没有同名字幕时返回空', () async {
      final video = touch('movie.mp4');
      touch('unrelated.srt');
      expect(
        await ExternalSubtitleLoader.findSiblingSubtitles(video.path),
        isEmpty,
      );
    });

    test('limit 生效', () async {
      final video = touch('movie.mp4');
      touch('movie.ass');
      touch('movie.zh.srt');
      touch('movie.cht.srt');

      final found = await ExternalSubtitleLoader.findSiblingSubtitles(
        video.path,
        limit: 2,
      );
      expect(found.length, 2);
    });
  });
}
