/// 百度通用翻译 API 引擎实现。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'adaptive_http_client.dart';
import 'translation_engine.dart';

class BaiduTranslationEngine implements TranslationEngine {
  BaiduTranslationEngine({
    required String appId,
    required String secretKey,
  })  : appId = _cleanCredential(appId),
        secretKey = _cleanCredential(secretKey);

  final String appId;
  final String secretKey;

  static String _cleanCredential(String s) {
    return s.replaceAll(RegExp(r'[\s\u200B-\u200D\uFEFF]'), '');
  }

  static const String _endpoint = 'https://fanyi-api.baidu.com/api/trans/vip/translate';

  @override
  String get id => 'baidu';

  @override
  String get displayName => '百度翻译';

  @override
  Future<String> testConnection({String testText = 'Hello'}) async {
    final results = await translateBatch(
      texts: [testText],
      targetLanguage: 'zh-Hans',
      sourceLanguage: 'auto',
    );
    if (results.isEmpty || results.first.trim().isEmpty) {
      throw const TranslationException('百度翻译返回空结果，请检查账户配置。');
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
    if (appId.isEmpty || secretKey.isEmpty) {
      throw const TranslationException('未配置百度翻译 APP ID 或密钥 (Secret Key)。');
    }

    final lang = TranslationLanguage.findByCode(targetLanguage);
    final toLang = lang.baiduCode;
    final fromLang = sourceLanguage == 'auto' ? 'auto' : TranslationLanguage.findByCode(sourceLanguage).baiduCode;

    // 百度多句翻译通过换行符拼接：每个条目内部如果含有换行，需替换为空格，避免索引错乱
    final sanitizedTexts = texts.map((t) => t.replaceAll('\n', ' ').trim()).toList();
    final query = sanitizedTexts.join('\n');

    // 准备候选密钥（处理字体无衬线常见的视觉混淆，如大写 I 与小写 l）
    final candidateKeys = <String>[secretKey];
    if (secretKey.startsWith('ol')) {
      candidateKeys.add('oI${secretKey.substring(2)}');
    } else if (secretKey.startsWith('oI')) {
      candidateKeys.add('ol${secretKey.substring(2)}');
    }

    http.Response? response;
    dynamic lastError;

    for (final currentKey in candidateKeys) {
      final salt = (DateTime.now().millisecondsSinceEpoch + Random().nextInt(10000)).toString();
      final signStr = '$appId$query$salt$currentKey';
      final sign = md5.convert(utf8.encode(signStr)).toString().toLowerCase();

      final bodyData = {
        'q': query,
        'from': fromLang,
        'to': toLang,
        'appid': appId,
        'salt': salt,
        'sign': sign,
      };

      // 优先尝试 HTTPS，若遇到网络代理拦截或 HandshakeException，自动回退到官方 HTTP 接口
      for (final endpoint in [_endpoint, 'http://fanyi-api.baidu.com/api/trans/vip/translate']) {
        try {
          final res = await AdaptiveHttpClient.post(
            Uri.parse(endpoint),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: bodyData,
            timeout: const Duration(seconds: 12),
          );

          if (res.statusCode == 200) {
            final Map<String, dynamic> data = jsonDecode(utf8.decode(res.bodyBytes));
            // 若报 54001 签名错误且还有其他候选密钥，继续尝试下一个候选密钥
            if (data.containsKey('error_code') && data['error_code'].toString() == '54001') {
              lastError = data;
              break; // 跳出 endpoint 循环，尝试下一个 key
            }
            response = res;
            break;
          }
        } catch (e) {
          lastError = e;
          // 若 HTTPS 握手失败，循环自动尝试 HTTP 终结点
        }
      }

      if (response != null) {
        break; // 成功拿到正常响应
      }
    }

    if (response == null) {
      if (lastError is Map && lastError.containsKey('error_code')) {
        final code = lastError['error_code'].toString();
        final msg = lastError['error_msg']?.toString() ?? '未知错误';
        throw TranslationException(_getFriendlyErrorMessage(code, msg), code: code);
      }
      throw TranslationException('连接百度翻译服务器失败：$lastError', rawError: lastError);
    }

    try {
      if (response.statusCode != 200) {
        throw TranslationException('HTTP 请求失败 (状态码 ${response.statusCode})');
      }

      final Map<String, dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data.containsKey('error_code')) {
        final code = data['error_code'].toString();
        final msg = data['error_msg']?.toString() ?? '未知错误';
        throw TranslationException(_getFriendlyErrorMessage(code, msg), code: code);
      }

      final transList = data['trans_result'] as List<dynamic>?;
      if (transList == null || transList.isEmpty) {
        return List.filled(texts.length, '');
      }

      // 如果翻译结果条数与输入条数一致，直接按顺序对应
      if (transList.length == texts.length) {
        return transList.map((item) => item['dst']?.toString() ?? '').toList();
      }

      // 若条数不一致（百度可能会合并空行或按句号断句），尽可能按顺序填补
      final results = <String>[];
      for (int i = 0; i < texts.length; i++) {
        if (i < transList.length) {
          results.add(transList[i]['dst']?.toString() ?? '');
        } else {
          results.add('');
        }
      }
      return results;
    } catch (e) {
      if (e is TranslationException) rethrow;
      throw TranslationException('解析百度翻译结果失败：$e');
    }
  }

  static String _getFriendlyErrorMessage(String code, String rawMsg) {
    switch (code) {
      case '52001':
        return '请求超时，请重试';
      case '52002':
        return '系统错误，请重试';
      case '52003':
        return '未授权用户，请检查 APP ID 和密钥是否正确，且已开通通用翻译 API';
      case '54000':
        return '必填参数为空';
      case '54001':
        return '签名错误，请检查密钥是否输入正确';
      case '54003':
        return '访问频率受限，请稍候再试（个人免费版单秒限 1 次请求）';
      case '54004':
        return '账户余额不足或免费额度已耗尽，请检查百度翻译开放平台账户';
      case '58000':
        return '客户端 IP 非法，请检查服务器 IP 白名单设置';
      case '58001':
        return '译文语言方向不支持';
      case '58002':
        return '服务当前已关闭，请前往控制台开启';
      default:
        return '百度翻译返回错误 [$code]: $rawMsg';
    }
  }
}
