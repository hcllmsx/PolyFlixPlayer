/// 翻译调度服务：协调翻译引擎分包、速率节流、进度通知与结果持久化缓存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../settings/app_settings.dart';
import '../../utils/native_file_helper.dart';
import '../subtitle_generator.dart';
import 'azure_translation_engine.dart';
import 'baidu_translation_engine.dart';
import 'local_translation_engine.dart';
import 'translation_engine.dart';

class TranslationService {
  TranslationService._();
  static final TranslationService instance = TranslationService._();

  /// 根据全局配置动态构建当前选中的翻译引擎。
  TranslationEngine getActiveEngine() {
    if (aiTranslationMode.value == 'local') {
      return LocalTranslationEngine(endpoint: aiLocalEndpoint.value);
    }

    final provider = aiTranslationProvider.value;
    switch (provider) {
      case 'azure':
        return AzureTranslationEngine(
          key: aiAzureKey.value,
          region: aiAzureRegion.value,
          endpoint: aiAzureEndpoint.value,
        );
      case 'baidu':
      default:
        return BaiduTranslationEngine(
          appId: aiBaiduAppId.value,
          secretKey: aiBaiduSecretKey.value,
          modelType: aiBaiduModelType.value,
        );
    }
  }

  /// 检查当前配置的翻译引擎是否就绪（凭据是否填写）。
  ({bool isConfigured, String? errorMessage}) checkConfiguration() {
    final engine = getActiveEngine();
    if (!engine.isConfigured) {
      return (isConfigured: false, errorMessage: engine.configurationError);
    }
    return (isConfigured: true, errorMessage: null);
  }

  /// 测试当前配置的引擎可用性。
  Future<String> testCurrentEngine({String testText = 'Hello'}) async {
    final engine = getActiveEngine();
    return await engine.testConnection(testText: testText);
  }

  /// 将一组字幕条目分批翻译为目标语言。
  ///
  /// [entries]: 待翻译字幕列表。
  /// [targetLanguage]: 目标语言（如 zh-Hans）。
  /// [contextTitle]: 可选的视频标题/文件名（用于大模型提取语境背景）。
  /// [onProgress]: 进度回调 (已翻译条数, 总条数)。
  /// [isCancelled]: 取消检查函数。
  ///
  /// 返回翻译完成（带有 `translatedText`）的新字幕列表。
  Future<List<SubtitleEntry>> translateEntries({
    required List<SubtitleEntry> entries,
    required String targetLanguage,
    String sourceLanguage = 'auto',
    String? contextTitle,
    void Function(int translated, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (entries.isEmpty) return const [];

    final engine = getActiveEngine();
    if (!engine.isConfigured) {
      throw TranslationException(engine.configurationError ?? '未配置翻译服务凭据');
    }
    final batchSize = _resolveBatchSize(engine.id);
    final delayBetweenBatches = _resolveDelay(engine.id);

    final total = entries.length;
    final results = <SubtitleEntry>[];

    onProgress?.call(0, total);

    for (int i = 0; i < total; i += batchSize) {
      if (isCancelled?.call() == true) {
        throw const TranslationException('翻译任务已取消');
      }

      final end = (i + batchSize < total) ? (i + batchSize) : total;
      final currentChunk = entries.sublist(i, end);
      final rawTexts = currentChunk.map((e) => e.text).toList();

      List<String> translatedTexts = const [];
      int retryCount = 0;
      while (true) {
        try {
          translatedTexts = await engine.translateBatch(
            texts: rawTexts,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage,
            contextTitle: contextTitle,
          );
          break;
        } catch (e) {
          retryCount++;
          if (retryCount >= 2 || isCancelled?.call() == true) {
            rethrow;
          }
          // 遇到频控或瞬时抖动，短暂停顿后重试
          await Future.delayed(const Duration(milliseconds: 1500));
        }
      }

      for (int k = 0; k < currentChunk.length; k++) {
        final original = currentChunk[k];
        final trans = (k < translatedTexts.length) ? translatedTexts[k] : '';
        results.add(SubtitleEntry(
          start: original.start,
          end: original.end,
          text: original.text,
          translatedText: trans.isNotEmpty ? trans : original.translatedText,
        ));
      }

      onProgress?.call(results.length, total);

      if (end < total && delayBetweenBatches > 0) {
        await Future.delayed(Duration(milliseconds: delayBetweenBatches));
      }
    }

    return results;
  }

  int _resolveBatchSize(String engineId) {
    switch (engineId) {
      case 'azure':
        return 40; // Azure 原生支持最多 100 组，40 组兼顾稳定与并发
      case 'baidu':
      default:
        return 25; // 百度建议单次 <6000 字节
    }
  }

  int _resolveDelay(String engineId) {
    switch (engineId) {
      case 'baidu':
        // 百度个人免费版 QPS=1，设 1000ms 间隔保障不被 54003 拦截
        return 1000;
      case 'azure':
      default:
        return 150;
    }
  }

  // ------------------------------------------------------------------ 缓存管理

  /// 生成翻译缓存的存储文件名。
  ///
  /// [sourceKey]: 视频标识（文件路径或流地址）。
  /// [sourceType]: 字幕来源（如 `builtin_0` 或 `asr_tiny`）。
  String _generateCacheFileName({
    required String sourceKey,
    required String sourceType,
    required String targetLang,
    required String engineId,
  }) {
    final cleanName = _extractCleanBaseName(sourceKey);
    final hash = md5.convert(utf8.encode('$sourceKey#$sourceType')).toString().substring(0, 8);
    return 'trans_${cleanName}_${sourceType}_${targetLang}_${engineId}_$hash.json';
  }

  String _extractCleanBaseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final seg = normalized.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => 'video');
    final dot = seg.lastIndexOf('.');
    return (dot > 0 ? seg.substring(0, dot) : seg).replaceAll(RegExp(r'[\\/:*?"<>| ]'), '_');
  }

  /// 保存翻译结果到磁盘缓存。
  Future<void> saveTranslationCache({
    required String sourceKey,
    required String sourceType,
    required String targetLang,
    required String engineId,
    required List<SubtitleEntry> entries,
  }) async {
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      final fileName = _generateCacheFileName(
        sourceKey: sourceKey,
        sourceType: sourceType,
        targetLang: targetLang,
        engineId: engineId,
      );
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');

      final data = {
        'version': 1,
        'sourceKey': sourceKey,
        'sourceType': sourceType,
        'targetLang': targetLang,
        'engineId': engineId,
        'createdAt': DateTime.now().toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(growable: false),
      };

      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  /// 加载磁盘中的翻译缓存。
  Future<List<SubtitleEntry>?> loadTranslationCache({
    required String sourceKey,
    required String sourceType,
    required String targetLang,
    required String engineId,
  }) async {
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) return null;

      final fileName = _generateCacheFileName(
        sourceKey: sourceKey,
        sourceType: sourceType,
        targetLang: targetLang,
        engineId: engineId,
      );
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
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

  /// 删除指定源与语言的翻译缓存。
  Future<void> deleteTranslationCache({
    required String sourceKey,
    required String sourceType,
    String? targetLang,
    String? engineId,
  }) async {
    try {
      final dir = NativeFileHelper.desktopSubtitleCacheDir();
      if (!dir.existsSync()) return;

      if (targetLang != null && engineId != null) {
        final fileName = _generateCacheFileName(
          sourceKey: sourceKey,
          sourceType: sourceType,
          targetLang: targetLang,
          engineId: engineId,
        );
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        if (await file.exists()) {
          await file.delete();
        }
      } else {
        final cleanName = _extractCleanBaseName(sourceKey);
        final prefix = 'trans_${cleanName}_${sourceType}_';
        for (final entity in dir.listSync()) {
          if (entity is File &&
              entity.path.split(Platform.pathSeparator).last.startsWith(prefix)) {
            try {
              entity.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }
}
