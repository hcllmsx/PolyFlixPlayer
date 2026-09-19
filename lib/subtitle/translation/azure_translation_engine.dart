/// 微软 Azure AI Translator 引擎实现。
///
/// 遵循 Azure AI 翻译服务 v3.0 REST API 规范，原生支持批量数组翻译。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'adaptive_http_client.dart';
import 'translation_engine.dart';

class AzureTranslationEngine implements TranslationEngine {
  AzureTranslationEngine({
    required String key,
    String region = 'global',
    String? endpoint,
  })  : key = _cleanCredential(key),
        region = region.trim().toLowerCase(),
        endpoint = _normalizeEndpoint(endpoint);

  final String key;
  final String region;
  final String endpoint;

  static String _cleanCredential(String s) {
    return s.replaceAll(RegExp(r'[\s\u200B-\u200D\uFEFF]'), '');
  }

  static String _normalizeEndpoint(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return 'https://api.cognitive.microsofttranslator.com/translate';
    }
    var ep = raw.trim();
    if (ep.endsWith('/')) ep = ep.substring(0, ep.length - 1);
    if (ep.contains('cognitiveservices.azure.com')) {
      if (!ep.endsWith('/translate')) {
        ep = '$ep/translator/text/v3.0/translate';
      }
    } else if (!ep.endsWith('/translate')) {
      ep = '$ep/translate';
    }
    return ep;
  }

  @override
  String get id => 'azure';

  @override
  String get displayName => '微软 Azure 翻译';

  @override
  bool get isConfigured => key.isNotEmpty;

  @override
  String? get configurationError => isConfigured
      ? null
      : '未配置微软 Azure 翻译密钥 (Key)';

  @override
  Future<String> testConnection({String testText = 'Hello'}) async {
    final results = await translateBatch(
      texts: [testText],
      targetLanguage: 'zh-Hans',
      sourceLanguage: 'auto',
    );
    if (results.isEmpty || results.first.trim().isEmpty) {
      throw const TranslationException('Azure 翻译返回空结果，请检查账户配置。');
    }
    return results.first;
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String targetLanguage,
    String sourceLanguage = 'auto',
  }) async {
    if (texts.isEmpty) return const [];
    if (key.isEmpty) {
      throw const TranslationException('未配置微软 Azure 翻译密钥 (Key)。');
    }

    final lang = TranslationLanguage.findByCode(targetLanguage);
    final toLang = lang.azureCode;

    var uriStr = '$endpoint?api-version=3.0&to=$toLang';
    if (sourceLanguage != 'auto') {
      final fromLang = TranslationLanguage.findByCode(sourceLanguage).azureCode;
      uriStr += '&from=$fromLang';
    }

    final bodyJson = jsonEncode(texts.map((t) => {'Text': t}).toList());

    final headers = {
      'Content-Type': 'application/json; charset=UTF-8',
      'Ocp-Apim-Subscription-Key': key,
    };
    if (region.isNotEmpty) {
      headers['Ocp-Apim-Subscription-Region'] = region;
    }

    http.Response? response;
    dynamic lastError;

    // 针对网络异常或代理切换提供最多 3 次重试
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        response = await AdaptiveHttpClient.post(
          Uri.parse(uriStr),
          headers: headers,
          body: bodyJson,
          timeout: const Duration(seconds: 12),
        );
        break;
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }

    if (response == null) {
      final errStr = lastError.toString();
      if (errStr.contains('HandshakeException') || errStr.contains('terminated during handshake')) {
        throw TranslationException(
          '网络 TLS 握手被重置或拦截 (HandshakeException)。\n'
          '排查建议：\n'
          '1. 请检查本地网络连接或代理软件状态；\n'
          '2. 也可选用国内直连更通畅的百度翻译。',
          rawError: lastError,
        );
      }
      throw TranslationException('连接微软 Azure 翻译服务失败：$lastError', rawError: lastError);
    }

    if (response.statusCode != 200) {
      String msg = 'HTTP 状态码 ${response.statusCode}';
      String? errCode;
      try {
        final errData = jsonDecode(utf8.decode(response.bodyBytes));
        if (errData is Map && errData.containsKey('error')) {
          final err = errData['error'] as Map<String, dynamic>;
          errCode = err['code']?.toString();
          msg = err['message']?.toString() ?? msg;
        }
      } catch (_) {}
      throw TranslationException(_getFriendlyErrorMessage(response.statusCode, errCode, msg), code: errCode);
    }

    final dynamic data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! List) {
      throw const TranslationException('Azure 翻译返回非预期的数据格式。');
    }

    final results = <String>[];
    for (final item in data) {
      if (item is Map && item.containsKey('translations')) {
        final transList = item['translations'] as List<dynamic>?;
        if (transList != null && transList.isNotEmpty) {
          results.add(transList.first['text']?.toString() ?? '');
          continue;
        }
      }
      results.add('');
    }

    return results;
  }

  static String _getFriendlyErrorMessage(int httpStatus, String? errCode, String rawMsg) {
    if (httpStatus == 401 || errCode == '401000') {
      return 'Azure 密钥无效或未授权，请检查密钥是否填写正确。';
    }
    if (httpStatus == 400 && rawMsg.contains('region')) {
      return '区域 (Region) 不匹配，请检查是否与 Azure 资源所在区域一致（如 eastasia 或 global）。';
    }
    if (httpStatus == 403 || errCode == '403001') {
      return '配额受限或账户余额不足，请检查 Azure 免费层额度或订阅状态。';
    }
    if (httpStatus == 429) {
      return '并发请求过多，超出当前定价层 QPS 上限。';
    }
    return 'Azure 翻译错误: $rawMsg';
  }
}
