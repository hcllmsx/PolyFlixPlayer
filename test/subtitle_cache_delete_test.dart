import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:polyflix_player/subtitle/ai_task_manager.dart';
import 'package:polyflix_player/subtitle/subtitle_generator.dart';
import 'package:polyflix_player/utils/native_file_helper.dart';

void main() {
  group('SubtitleGenerator 路径规范化比对测试', () {
    test('isSameVideoPath 跨平台与斜杠容错', () {
      expect(
        SubtitleGenerator.isSameVideoPath(
          r'D:\Videos\Movie.mp4',
          'd:/videos/movie.mp4',
        ),
        isTrue,
      );

      expect(
        SubtitleGenerator.isSameVideoPath(
          'D:/Projects/Player/temp/test.mp4',
          r'd:\projects\player\temp\test.mp4',
        ),
        isTrue,
      );

      expect(
        SubtitleGenerator.isSameVideoPath(
          'http://127.0.0.1:8080/pflx',
          'http://127.0.0.1:8080/pflx',
        ),
        isTrue,
      );

      expect(
        SubtitleGenerator.isSameVideoPath(
          r'D:\Videos\Movie1.mp4',
          r'D:\Videos\Movie2.mp4',
        ),
        isFalse,
      );
    });

    test('holdsEntriesFor 支持不同斜杠比对', () {
      final gen = SubtitleGenerator.instance;
      gen.clear();

      final entries = [
        const SubtitleEntry(
          start: Duration.zero,
          end: Duration(seconds: 2),
          text: '测试字幕',
        ),
      ];

      gen.setEntries(
        entries,
        videoPath: r'D:\Videos\TestVideo.mp4',
        modelId: 'large-v3',
        markCompleted: true,
      );

      expect(gen.holdsEntriesFor('d:/videos/testvideo.mp4'), isTrue);
      expect(gen.entriesModelId, equals('large-v3'));

      gen.clear();
      expect(gen.holdsEntriesFor('d:/videos/testvideo.mp4'), isFalse);
      expect(gen.entriesModelId, isNull);
    });
  });

  group('AiTaskManager deleteCachedSubtitles 物理删除测试', () {
    late Directory cacheDir;
    final testVideoPath = r'D:\Mock\Video_Sample_2026.mp4';

    setUp(() {
      cacheDir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!cacheDir.existsSync()) {
        cacheDir.createSync(recursive: true);
      }
    });

    test('全量扫盘彻底删除指定模型的主缓存与翻译缓存', () async {
      final manager = AiTaskManager.instance;

      // 1. 模拟保存主缓存
      final entries = [
        const SubtitleEntry(
          start: Duration.zero,
          end: Duration(seconds: 1),
          text: 'Hello world',
        ),
      ];
      await manager.saveCachedSubtitles(
        testVideoPath,
        entries,
        modelId: 'large-v3',
      );

      // 验证保存成功且能被检测到
      var cachedIds = await manager.getCachedModelIds(testVideoPath);
      expect(cachedIds, contains('large-v3'));

      // 2. 模拟伪造关联翻译缓存
      final transFile = File(
        '${cacheDir.path}${Platform.pathSeparator}trans_Video_Sample_2026_asr_large-v3_zh_baidu_12345678.json',
      );
      await transFile.writeAsString(jsonEncode([entries.first.toJson()]));
      expect(transFile.existsSync(), isTrue);

      // 3. 执行 deleteCachedSubtitles
      final deleted = await manager.deleteCachedSubtitles(
        testVideoPath,
        modelId: 'large-v3',
      );
      expect(deleted, greaterThanOrEqualTo(1));

      // 4. 验证主缓存与翻译缓存均被物理删除
      cachedIds = await manager.getCachedModelIds(testVideoPath);
      expect(cachedIds.contains('large-v3'), isFalse);
      expect(transFile.existsSync(), isFalse);
    });
  });

  group('AiTaskManager clearTaskFor 历史任务清理测试', () {
    test('clearTaskFor 能精准清理指定视频与模型的已结束任务', () async {
      final manager = AiTaskManager.instance;

      // 启动一个虚拟任务并将其标记为已结束
      final task = await manager.startTask(
        videoPath: r'D:\Mock\TestTaskVideo.mp4',
        videoTitle: 'Test Video',
        modelId: 'large-v3',
      );
      task.updateState(AsrState.completed);

      expect(manager.getTask(r'd:/mock/testtaskvideo.mp4'), isNotNull);

      // 执行清理
      manager.clearTaskFor(r'D:\Mock\TestTaskVideo.mp4', modelId: 'large-v3');

      // 验证已从任务管理器移除
      expect(manager.getTask(r'd:/mock/testtaskvideo.mp4'), isNull);
    });
  });
}
