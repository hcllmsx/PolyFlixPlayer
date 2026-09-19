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
import 'package:polyflix_player/settings/app_settings.dart';

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
      // 双语导出：译文在上，原文在下
      expect(bilingual.contains('1\n00:00:01,000 --> 00:00:03,000\n你好世界\nHello world'), isTrue);
      expect(bilingual.contains('2\n00:00:04,000 --> 00:00:06,000\n再见\nGoodbye'), isTrue);

      // 头部注释：播放器不显示，文本打开可见
      final withHeader = SrtParser.serialize(
        entries,
        bilingual: false,
        headerComment: '导出说明',
      );
      expect(withHeader.startsWith('导出说明\n\n1\n'), isTrue);
      expect(SrtParser.parse(withHeader).length, 2);

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
    test('Unconfigured engine check throws TranslationException and reports error', () async {
      aiTranslationMode.value = 'cloud';
      aiTranslationProvider.value = 'baidu';
      aiBaiduAppId.value = '';
      aiBaiduSecretKey.value = '';

      final check = TranslationService.instance.checkConfiguration();
      expect(check.isConfigured, isFalse);
      expect(check.errorMessage, contains('未配置百度翻译'));

      final manager = AiTaskManager.instance;
      expect(
        () => manager.startTranslationTask(
          videoPath: 'test.mp4',
          videoTitle: 'test',
          targetLang: 'zh-Hans',
          sourceType: 'builtin_0',
        ),
        throwsA(isA<TranslationException>()),
      );
    });

    test('startTranslationTask creates task with AiTaskType.translation and adds to activeTasks', () async {
      aiBaiduAppId.value = 'test_app_id';
      aiBaiduSecretKey.value = 'test_secret_key';

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

    test('Pending translation scheduling and task separation', () {
      final manager = AiTaskManager.instance;
      const testPath = 'C:\\Videos\\PendingMovie.mkv';
      const testTitle = 'PendingMovie.mkv';

      // 1. 创建并模拟一个正在运行的 ASR 任务
      final asrTask = AiTask(
        id: 'asr_pending_test',
        taskType: AiTaskType.transcription,
        videoPath: testPath,
        videoTitle: testTitle,
        modelId: 'base',
        language: 'en',
      );
      asrTask.updateState(AsrState.processing);

      // 直接添加到 tasks
      manager.allTasks; // 触发内部就绪
      expect(asrTask.isRunning, isTrue);
      expect(asrTask.hasPendingTranslation, isFalse);

      // 预约排队翻译
      asrTask.pendingTranslationLang = 'zh-Hans';
      expect(asrTask.hasPendingTranslation, isTrue);
      expect(asrTask.pendingTranslationLang, 'zh-Hans');

      // 验证序列化与反序列化保持 pendingTranslationLang
      final json = asrTask.toJson();
      expect(json['pendingTranslationLang'], 'zh-Hans');

      final restored = AiTask.fromJson(json);
      expect(restored, isNotNull);
      expect(restored!.pendingTranslationLang, 'zh-Hans');
      expect(restored.hasPendingTranslation, isTrue);

      // 取消预约
      asrTask.pendingTranslationLang = null;
      expect(asrTask.hasPendingTranslation, isFalse);
    });
  });

  group('Baidu LLM & Video Title Sanitization Tests', () {
    test('BaiduTranslationEngine default modelType is llm', () {
      final defaultEngine = BaiduTranslationEngine(appId: 'testApp', secretKey: 'testKey');
      expect(defaultEngine.modelType, 'llm');
      expect(defaultEngine.displayName, contains('大模型'));

      final nmtEngine = BaiduTranslationEngine(appId: 'testApp', secretKey: 'testKey', modelType: 'nmt');
      expect(nmtEngine.modelType, 'nmt');
      expect(nmtEngine.displayName, contains('通用'));
    });

    test('sanitizeVideoTitle extracts clean title from typical video filenames', () {
      // 英文电影带年份、清晰度、压制标签
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle('Inception.2010.1080p.BluRay.x265.DTS-HD.mkv'),
        'Inception 2010',
      );

      // 中文动漫带字幕组与压制参数
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle('[DBD-Raws][秒速5厘米][BDRip][1080P][HEVC-10bit][FLAC].mp4'),
        '秒速5厘米',
      );

      // 电视剧季度集数
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle('Game.of.Thrones.S08E06.2160p.UHD.HDR.mkv'),
        'Game of Thrones S08E06',
      );

      // 带有本地路径的文件名
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle(r'D:\Downloads\Movies\Oppenheimer.2023.WEB-DL.mkv'),
        'Oppenheimer 2023',
      );
    });

    test('sanitizeVideoTitle rejects hashes, device recordings, numbers and invalid names', () {
      // 32 位 MD5 哈希
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle('d41d8cd98f00b204e9800998ecf8427e.mp4'),
        isNull,
      );

      // 相机/手机自动命名
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle('VID_20230501_143022.mp4'),
        isNull,
      );
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle('IMG_8923.MOV'),
        isNull,
      );
      expect(
        BaiduTranslationEngine.sanitizeVideoTitle('ScreenRecording_2024.mp4'),
        isNull,
      );

      // 纯数字或单字符
      expect(BaiduTranslationEngine.sanitizeVideoTitle('123456.mkv'), isNull);
      expect(BaiduTranslationEngine.sanitizeVideoTitle('a.mp4'), isNull);
      expect(BaiduTranslationEngine.sanitizeVideoTitle(null), isNull);
      expect(BaiduTranslationEngine.sanitizeVideoTitle('   '), isNull);
    });

    test('buildLlmReference generates context prompt for valid titles and fallback for invalid', () {
      final promptWithTitle = BaiduTranslationEngine.buildLlmReference(
        rawTitle: 'Interstellar.2014.1080p.mkv',
      );
      expect(promptWithTitle, contains('《Interstellar 2014》'));
      expect(promptWithTitle, contains('结合该作品的背景'));

      final fallbackPrompt = BaiduTranslationEngine.buildLlmReference(
        rawTitle: 'VID_20231010.mp4',
      );
      expect(fallbackPrompt, isNot(contains('《')));
      expect(fallbackPrompt, contains('请将以下影视对白台词翻译为通顺、地道的中文字幕'));
    });
  });
}

