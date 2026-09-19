import 'package:flutter_test/flutter_test.dart';
import 'package:polyflix_player/subtitle/subtitle_generator.dart';
import 'package:polyflix_player/subtitle/translation/translation_engine.dart';
import 'package:polyflix_player/subtitle/translation/srt_parser.dart';
import 'package:polyflix_player/subtitle/translation/baidu_translation_engine.dart';
import 'package:polyflix_player/subtitle/translation/azure_translation_engine.dart';
import 'package:polyflix_player/subtitle/translation/adaptive_http_client.dart';
import 'package:polyflix_player/subtitle/translation/translation_service.dart';
import 'package:polyflix_player/subtitle/translation/builtin_subtitle_extractor.dart';
import 'package:polyflix_player/subtitle/ai_task_manager.dart';

void main() {
  group('SRT Parser & Serializer Tests', () {
    const rawSrt = '''1
00:00:01,000 --> 00:00:04,500
Hello, world!
This is a test.

2
00:00:05,123 --> 00:00:08,999
Second subtitle entry.
''';

    test('Parse standard SRT string into SubtitleEntries', () {
      final entries = SrtParser.parse(rawSrt);
      expect(entries.length, 2);

      expect(entries[0].start, const Duration(seconds: 1));
      expect(entries[0].end, const Duration(seconds: 4, milliseconds: 500));
      expect(entries[0].text, 'Hello, world!\nThis is a test.');

      expect(entries[1].start, const Duration(seconds: 5, milliseconds: 123));
      expect(entries[1].end, const Duration(seconds: 8, milliseconds: 999));
      expect(entries[1].text, 'Second subtitle entry.');
    });

    test('Serialize SubtitleEntries to bilingual and translation-only SRT', () {
      final entries = [
        SubtitleEntry(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 3),
          text: 'Hello world',
          translatedText: '你好世界',
        ),
        SubtitleEntry(
          start: const Duration(seconds: 4),
          end: const Duration(seconds: 6),
          text: 'Goodbye',
          translatedText: '再见',
        ),
      ];

      final bilingual = SrtParser.serialize(entries, bilingual: true);
      expect(bilingual.contains('1\n00:00:01,000 --> 00:00:03,000\nHello world\n你好世界'), isTrue);
      expect(bilingual.contains('2\n00:00:04,000 --> 00:00:06,000\nGoodbye\n再见'), isTrue);

      final translationOnly = SrtParser.serialize(entries, translationOnly: true);
      expect(translationOnly.contains('1\n00:00:01,000 --> 00:00:03,000\n你好世界'), isTrue);
      expect(translationOnly.contains('Hello world'), isFalse);

      final originalOnly = SrtParser.serialize(entries, bilingual: false, translationOnly: false);
      expect(originalOnly.contains('1\n00:00:01,000 --> 00:00:03,000\nHello world'), isTrue);
      expect(originalOnly.contains('你好世界'), isFalse);
    });
  });

  group('Language Code Mapping Tests', () {
    test('Language code mapping for zh-Hans', () {
      final zh = TranslationLanguage.findByCode('zh-Hans');
      expect(zh.code, 'zh-Hans');
      expect(zh.baiduCode, 'zh');
      expect(zh.azureCode, 'zh-Hans');
    });

    test('Language code mapping for zh-Hant', () {
      final zhTw = TranslationLanguage.findByCode('zh-Hant');
      expect(zhTw.code, 'zh-Hant');
      expect(zhTw.baiduCode, 'cht');
      expect(zhTw.azureCode, 'zh-Hant');
    });

    test('Language code mapping for Japanese and Korean', () {
      final ja = TranslationLanguage.findByCode('ja');
      expect(ja.baiduCode, 'jp');
      expect(ja.azureCode, 'ja');

      final ko = TranslationLanguage.findByCode('ko');
      expect(ko.baiduCode, 'kor');
      expect(ko.azureCode, 'ko');
    });
  });

  group('Engine Configuration & Exception Tests', () {
    test('Baidu engine throws TranslationException when unconfigured', () async {
      final engine = BaiduTranslationEngine(appId: '', secretKey: '');
      expect(engine.id, 'baidu');
      expect(
        () => engine.testConnection(),
        throwsA(isA<TranslationException>()),
      );
    });

    test('Azure engine throws TranslationException when unconfigured', () async {
      final engine = AzureTranslationEngine(key: '');
      expect(engine.id, 'azure');
      expect(
        () => engine.testConnection(),
        throwsA(isA<TranslationException>()),
      );
    });
  });

  group('AdaptiveHttpClient Tests', () {
    test('detectLocalProxyPort runs without throwing', () async {
      final port = await AdaptiveHttpClient.detectLocalProxyPort();
      // 在开启代理时返回数字端口，未开启时返回 null
      expect(port == null || port > 0, isTrue);
    });
  });

  group('Translation Cache Storage & Deletion Tests', () {
    test('saveTranslationCache, loadTranslationCache and deleteTranslationCache work correctly', () async {
      final service = TranslationService.instance;
      const testKey = 'test_video_builtin_123';
      const testSourceType = 'builtin_1';
      const testLang = 'zh-Hans';
      const testEngine = 'local';
      final testEntries = [
        const SubtitleEntry(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'Hello world',
          translatedText: '你好世界',
        ),
      ];

      // 1. 保存缓存
      await service.saveTranslationCache(
        sourceKey: testKey,
        sourceType: testSourceType,
        targetLang: testLang,
        engineId: testEngine,
        entries: testEntries,
      );

      // 2. 读取缓存
      final loaded = await service.loadTranslationCache(
        sourceKey: testKey,
        sourceType: testSourceType,
        targetLang: testLang,
        engineId: testEngine,
      );
      expect(loaded, isNotNull);
      expect(loaded!.length, 1);
      expect(loaded.first.text, 'Hello world');
      expect(loaded.first.translatedText, '你好世界');

      // 3. 删除缓存
      await service.deleteTranslationCache(
        sourceKey: testKey,
        sourceType: testSourceType,
        targetLang: testLang,
        engineId: testEngine,
      );

      // 4. 再次读取应为 null
      final reloaded = await service.loadTranslationCache(
        sourceKey: testKey,
        sourceType: testSourceType,
        targetLang: testLang,
        engineId: testEngine,
      );
      expect(reloaded, isNull);
    });
  });

  group('BuiltInSubtitleExtractor Disk Cache Tests', () {
    test('saveCachedSubtitles and loadCachedSubtitles persist entries to disk', () async {
      const testPath = 'C:\\Videos\\Movie.mkv';
      const testTrack = 0;
      final testEntries = [
        const SubtitleEntry(
          start: Duration(seconds: 5),
          end: Duration(seconds: 10),
          text: 'Built-in subtitle text line',
        ),
      ];

      // 保存提取结果缓存
      await BuiltInSubtitleExtractor.saveCachedSubtitles(
        videoPath: testPath,
        subtitleIndex: testTrack,
        entries: testEntries,
      );

      // 读取缓存
      final cached = await BuiltInSubtitleExtractor.loadCachedSubtitles(
        videoPath: testPath,
        subtitleIndex: testTrack,
      );
      expect(cached, isNotNull);
      expect(cached!.length, 1);
      expect(cached.first.text, 'Built-in subtitle text line');
    });
  });

  group('AiTaskManager Translation Task Tests', () {
    test('startTranslationTask creates task with AiTaskType.translation and adds to activeTasks', () async {
      final manager = AiTaskManager.instance;
      const testPath = 'C:\\Videos\\Sample.mp4';
      const testTitle = 'Sample.mp4';
      const testLang = 'zh-Hans';
      const testSource = 'builtin_0';

      final task = await manager.startTranslationTask(
        videoPath: testPath,
        videoTitle: testTitle,
        targetLang: testLang,
        sourceType: testSource,
        rawEntries: [
          const SubtitleEntry(
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            text: 'Test',
          ),
        ],
      );

      expect(task.taskType, AiTaskType.translation);
      expect(task.targetLanguage, testLang);
      expect(task.sourceType, testSource);
      expect(task.modelDisplayName, contains('内置字幕翻译'));

      final queried = manager.getTranslationTask(testPath, sourceType: testSource);
      expect(queried, isNotNull);
      expect(queried!.id, task.id);
    });
  });
}
