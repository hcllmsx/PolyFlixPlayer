import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:polyflix_player/subtitle/subtitle_generator.dart';
import 'package:polyflix_player/subtitle/translation/builtin_subtitle_extractor.dart';

void main() {
  group('BuiltInSubtitleExtractor isGraphicSubtitle Tests', () {
    test('Correctly identifies graphical subtitle codecs', () {
      final pgsTrack = SubtitleTrack(
        '1',
        'Chinese (PGS)',
        'chi',
        codec: 'hdmv_pgs_subtitle',
      );
      expect(BuiltInSubtitleExtractor.isGraphicSubtitle(pgsTrack), isTrue);

      final vobsubTrack = SubtitleTrack(
        '2',
        'English (VobSub)',
        'eng',
        codec: 'dvd_subtitle',
      );
      expect(BuiltInSubtitleExtractor.isGraphicSubtitle(vobsubTrack), isTrue);

      final dvbTrack = SubtitleTrack(
        '3',
        'DVB Subtitle',
        'eng',
        codec: 'dvb_subtitle',
      );
      expect(BuiltInSubtitleExtractor.isGraphicSubtitle(dvbTrack), isTrue);

      final titlePgsTrack = SubtitleTrack(
        '4',
        'PGS Subtitle Track',
        'eng',
        codec: null,
      );
      expect(BuiltInSubtitleExtractor.isGraphicSubtitle(titlePgsTrack), isTrue);
    });

    test('Correctly identifies text subtitle codecs', () {
      final srtTrack = SubtitleTrack(
        '1',
        'Chinese (SRT)',
        'chi',
        codec: 'subrip',
      );
      expect(BuiltInSubtitleExtractor.isGraphicSubtitle(srtTrack), isFalse);

      final assTrack = SubtitleTrack(
        '2',
        'Japanese (ASS)',
        'jpn',
        codec: 'ass',
      );
      expect(BuiltInSubtitleExtractor.isGraphicSubtitle(assTrack), isFalse);

      final vttTrack = SubtitleTrack(
        '3',
        'English (VTT)',
        'eng',
        codec: 'webvtt',
      );
      expect(BuiltInSubtitleExtractor.isGraphicSubtitle(vttTrack), isFalse);
    });
  });

  group('SubtitleEntry Time Range Matching Tests', () {
    final List<SubtitleEntry> entries = [
      const SubtitleEntry(
        start: Duration(seconds: 1),
        end: Duration(seconds: 4),
        text: '第一行原声字幕',
        translatedText: 'Line 1 Original',
      ),
      const SubtitleEntry(
        start: Duration(seconds: 5),
        end: Duration(seconds: 8),
        text: '第二行原声字幕',
        translatedText: 'Line 2 Original',
      ),
    ];

    test('Finds correct subtitle entry at given timestamp', () {
      // 0s -> no subtitle
      final entryAt0 = _findActiveEntry(entries, Duration.zero);
      expect(entryAt0, isNull);

      // 2s -> matches entry 1
      final entryAt2 = _findActiveEntry(entries, const Duration(seconds: 2));
      expect(entryAt2, isNotNull);
      expect(entryAt2!.text, '第一行原声字幕');

      // 4.5s -> between entries, no subtitle
      final entryAt4Point5 = _findActiveEntry(
        entries,
        const Duration(milliseconds: 4500),
      );
      expect(entryAt4Point5, isNull);

      // 6s -> matches entry 2
      final entryAt6 = _findActiveEntry(entries, const Duration(seconds: 6));
      expect(entryAt6, isNotNull);
      expect(entryAt6!.text, '第二行原声字幕');
    });
  });
}

SubtitleEntry? _findActiveEntry(List<SubtitleEntry>? list, Duration pos) {
  if (list == null || list.isEmpty) return null;
  var low = 0;
  var high = list.length - 1;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    final item = list[mid];
    if (pos < item.start) {
      high = mid - 1;
    } else if (pos >= item.end) {
      low = mid + 1;
    } else {
      return item;
    }
  }
  return null;
}
