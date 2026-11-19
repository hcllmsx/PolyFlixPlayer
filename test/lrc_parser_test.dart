import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_lyric/flutter_lyric.dart' hide LrcParser;
import 'package:flutter_test/flutter_test.dart';
import 'package:polyflix_player/player/audio_stage_view.dart';
import 'package:polyflix_player/subtitle/subtitle_generator.dart';
import 'package:polyflix_player/subtitle/translation/lrc_parser.dart';
import 'package:polyflix_player/utils/native_file_helper.dart';

void main() {
  group('媒体路径格式判定', () {
    test('区分音频与视频路径', () {
      expect(isAudioPath('/music/song.mp3'), isTrue);
      expect(isAudioPath(r'D:\Audio\track.FLAC'), isTrue);
      expect(isAudioPath('/music/voice.m4a'), isTrue);
      expect(isAudioPath('/music/clip.mp4'), isFalse);
      expect(isVideoPath('/music/clip.mp4'), isTrue);
      expect(isVideoPath('/music/song.mp3'), isFalse);
      expect(isMediaPath('/music/song.wav'), isTrue);
      expect(isMediaPath('/music/movie.mkv'), isTrue);
      expect(isMediaPath('/music/readme.txt'), isFalse);
    });
  });

  group('LrcParser 解析', () {
    test('解析标准时间标签、多时间戳复用行、逐字标签剥离与 offset', () {
      const raw = '''
[ti:Test Song]
[ar:Artist]
[offset:500]
[00:02.50][00:20.00]副歌一句
[00:05.500]这是<00:05.600>逐字歌词
[00:10.0]十分之一秒格式
''';
      final entries = LrcParser.parse(raw);
      expect(entries.length, 4);

      expect(entries[0].text, '副歌一句');
      expect(entries[0].start, const Duration(milliseconds: 2000));
      expect(entries[0].end, const Duration(milliseconds: 5000));

      expect(entries[1].text, '这是逐字歌词');
      expect(entries[1].start, const Duration(milliseconds: 5000));

      expect(entries[2].text, '十分之一秒格式');
      expect(entries[2].start, const Duration(milliseconds: 9500));

      expect(entries[3].text, '副歌一句');
      expect(entries[3].start, const Duration(milliseconds: 19500));
      expect(entries[3].end, const Duration(milliseconds: 24500));
    });

    test('合并同时间戳的双语歌词行', () {
      const raw = '''
[00:01.00]Hello world
[00:01.00]你好世界
[00:04.20]Second line
[00:04.20]第二行
''';
      final entries = LrcParser.parse(raw);
      expect(entries.length, 2);
      expect(entries[0].text, 'Hello world');
      expect(entries[0].translatedText, '你好世界');
      expect(entries[1].text, 'Second line');
      expect(entries[1].translatedText, '第二行');
    });
  });

  group('LrcParser 序列化与合并', () {
    final entries = [
      const SubtitleEntry(
        start: Duration(seconds: 1, milliseconds: 230),
        end: Duration(seconds: 4),
        text: 'Hello\nworld',
        translatedText: '你好\n世界',
      ),
      const SubtitleEntry(
        start: Duration(seconds: 5),
        end: Duration(seconds: 8),
        text: 'Second line',
      ),
    ];

    test('导出原词 LRC', () {
      final out = LrcParser.serialize(entries, headerComment: 'PolyFlix');
      expect(out, contains('[by:PolyFlix]'));
      expect(out, contains('[00:01.23]Hello world'));
      expect(out, contains('[00:05.00]Second line'));
      expect(out, isNot(contains('你好')));
    });

    test('导出仅译文 LRC（无译文条目回退原文）', () {
      final out = LrcParser.serialize(entries, translationOnly: true);
      expect(out, contains('[00:01.23]你好 世界'));
      expect(out, contains('[00:05.00]Second line'));
      expect(out, isNot(contains('Hello world')));
    });

    test('导出双语 LRC（同时间戳上下两行）', () {
      final out = LrcParser.serialize(entries, bilingual: true);
      expect(out, contains('[00:01.23]Hello world\n[00:01.23]你好 世界'));
      expect(out, contains('[00:05.00]Second line'));
    });

    test('toLyricDocumentString 合并主副字幕列表', () {
      const primary = [
        SubtitleEntry(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'Line one',
        ),
        SubtitleEntry(
          start: Duration(seconds: 5),
          end: Duration(seconds: 8),
          text: 'Line two',
        ),
      ];
      const secondary = [
        SubtitleEntry(
          start: Duration(seconds: 1, milliseconds: 100),
          end: Duration(seconds: 3, milliseconds: 200),
          text: '第一行',
        ),
      ];
      final lrc = LrcParser.toLyricDocumentString(
        primary: primary,
        secondary: secondary,
      );
      expect(lrc, contains('[00:01.00]Line one\n[00:01.00]第一行'));
      expect(lrc, contains('[00:05.00]Line two'));
    });
  });

  group('AudioStageView 视图切换测试', () {
    testWidgets('无字幕显示动态频谱；有字幕切换为 LyricView', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AudioStageView(
              sourcePath: '/nonexistent/song.mp3',
              title: 'Test Song.mp3',
              position: const Duration(seconds: 10),
              duration: const Duration(seconds: 100),
              playing: false,
              onSeek: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AudioSpectrumView), findsOneWidget);
      expect(find.byType(LyricView), findsNothing);

      // 传入字幕/歌词后切为 LyricView
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AudioStageView(
              sourcePath: '/nonexistent/song.mp3',
              title: 'Test Song.mp3',
              position: const Duration(seconds: 2),
              duration: const Duration(seconds: 100),
              playing: true,
              primaryEntries: const [
                SubtitleEntry(
                  start: Duration(seconds: 1),
                  end: Duration(seconds: 5),
                  text: 'First line',
                  translatedText: '第一行',
                ),
              ],
              onSeek: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LyricView), findsOneWidget);
      expect(find.byType(AudioSpectrumView), findsNothing);
    });

    test('AudioStageLoader.analyzePcmFrames 计算频谱时间轴并插值采样', () {
      const sampleRate = 4000;
      const totalSamples = 800; // 200ms = 4 帧（每帧 50ms）
      final bd = ByteData(totalSamples * 2);
      for (var i = 0; i < totalSamples; i++) {
        // 前半段低频正弦，后半段高频高频信号
        final val = i < 400
            ? (sin(2 * pi * 120 * i / sampleRate) * 20000).round()
            : (sin(2 * pi * 1500 * i / sampleRate) * 20000).round();
        bd.setInt16(i * 2, val.clamp(-32768, 32767), Endian.little);
      }

      final timeline = AudioStageLoader.analyzePcmFrames(
        bd.buffer.asUint8List(),
        sampleRate: sampleRate,
      );
      expect(timeline, isNotNull);
      expect(timeline!.frameCount, 4);

      final early = timeline.sampleAt(25);
      final late = timeline.sampleAt(150);
      // 前半段低频能量显著高于后半段，后半段高频能量显著高于前半段
      expect(early.$1, greaterThan(late.$1));
      expect(late.$3, greaterThan(early.$3));
    });

    testWidgets('AudioSpectrumView 播放时推进帧动画，暂停后自动停止 Ticker', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AudioSpectrumView(
              width: 320,
              height: 100,
              barCount: 24,
              playing: true,
              position: Duration(seconds: 1),
              primaryColor: Colors.purpleAccent,
              secondaryColor: Colors.deepPurple,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // 切换为暂停，等待回落动画完成并自动停止 Ticker
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AudioSpectrumView(
              width: 320,
              height: 100,
              barCount: 24,
              playing: false,
              position: Duration(seconds: 1),
              primaryColor: Colors.purpleAccent,
              secondaryColor: Colors.deepPurple,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.byType(AudioSpectrumView), findsOneWidget);
    });
  });
}
