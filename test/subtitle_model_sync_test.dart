import 'package:flutter_test/flutter_test.dart';
import 'package:polyflix_player/subtitle/subtitle_generator.dart';

void main() {
  group('SubtitleGenerator entriesModelId Tests', () {
    final generator = SubtitleGenerator.instance;

    setUp(() {
      generator.clear();
    });

    test('setEntries records entriesModelId correctly', () {
      expect(generator.entriesModelId, isNull);

      final entries = [
        const SubtitleEntry(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'Test Subtitle',
        ),
      ];

      generator.setEntries(
        entries,
        videoPath: 'test_video_2.mp4',
        modelId: 'small',
        markCompleted: true,
      );

      expect(generator.holdsEntriesFor('test_video_2.mp4'), isTrue);
      expect(generator.entriesModelId, 'small');
      expect(generator.state, AsrState.completed);
    });

    test('clear resets entriesModelId to null', () {
      generator.setEntries(
        [
          const SubtitleEntry(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'Test Subtitle',
          ),
        ],
        videoPath: 'test_video_1.mp4',
        modelId: 'tiny',
      );

      expect(generator.entriesModelId, 'tiny');
      generator.clear();
      expect(generator.entriesModelId, isNull);
      expect(generator.holdsEntriesFor('test_video_1.mp4'), isFalse);
    });
  });
}
