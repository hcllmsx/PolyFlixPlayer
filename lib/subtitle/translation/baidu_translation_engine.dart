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
    this.modelType = 'llm',
  })  : appId = _cleanCredential(appId),
        secretKey = _cleanCredential(secretKey);

  final String appId;
  final String secretKey;

  /// 翻译模型模式：'llm' 为大模型翻译（默认），'nmt' 为经典通用机器翻译。
  final String modelType;

  static String _cleanCredential(String s) {
    return s.replaceAll(RegExp(r'[\s\u200B-\u200D\uFEFF]'), '');
  }

  static const String _nmtEndpoint = 'https://fanyi-api.baidu.com/api/trans/vip/translate';
  static const String _llmEndpoint = 'https://fanyi-api.baidu.com/ait/api/aiTextTranslate';

  @override
  String get id => 'baidu';

  @override
  String get displayName => modelType == 'llm' ? '百度翻译 (大模型)' : '百度翻译 (通用)';

  @override
  bool get isConfigured => appId.isNotEmpty && secretKey.isNotEmpty;

  @override
  String? get configurationError => isConfigured
      ? null
      : '未配置百度翻译 APP ID 或密钥 (Secret Key)';

  /// 智能清洗视频文件名/标题，剔除压制组信息、分辨率编码等技术标签。
  /// 若判定为纯哈希/纯数字/无意义临时文件名/乱码，则返回 null，避免带偏大模型。
  static String? sanitizeVideoTitle(String? rawTitle) {
    if (rawTitle == null) return null;
    var title = rawTitle.trim();
    if (title.isEmpty) return null;

    // 1. 剥离可能存在的路径
    if (title.contains('/') || title.contains('\\')) {
      final sep = title.contains('/') ? '/' : '\\';
      title = title.split(sep).last.trim();
    }

    // 2. 剥离常见视频后缀扩展名
    title = title.replaceAll(
      RegExp(r'\.(mp4|mkv|avi|mov|wmv|flv|webm|ts|m2ts|rmvb|iso|vob|m4v)$', caseSensitive: false),
      '',
    ).trim();

    // 3. 剔除常见包含 Raws/字幕组/Fansub 的发布组标签
    title = title.replaceAll(
      RegExp(r'\[[A-Za-z0-9_.\s-]+-(Raws?|sub|fansub|rip)\]', caseSensitive: false),
      ' ',
    );
    title = title.replaceAll(
      RegExp(r'【.*?字幕组.*?】', caseSensitive: false),
      ' ',
    );

    // 4. 正则剔除常见的压制规格词、音频编码、分辨率、色彩格式等杂质
    final techPattern = RegExp(
      r'\b(2160p|1080p|1080i|720p|480p|360p|4k|8k|uhd|fhd|hd|'
      r'bluray|bdrip|brrip|web-?dl|web-?rip|hdtv|dvdrip|remux|'
      r'hdr10\+?|hdr|dolby|vision|atmos|dts-?hd(\.ma)?|dts|truehd|ac3|eac3|aac|flac|mp3|'
      r'x264|x265|h264|h265|hevc|avc|10bit|8bit|12bit|'
      r'complete|proper|repack|internal|unrated|extended|directors\.cut)\b',
      caseSensitive: false,
    );
    title = title.replaceAll(techPattern, ' ');

    // 5. 将各种括号、标点、连字符和下划线替换为空格，保留括号内真实的影视剧名
    title = title.replaceAll(RegExp(r'[\[\]【】()（）._+\-–—]'), ' ');
    // 合并多余空白
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 6. 质量门禁校验：判断是否为乱码或无意义文件名
    if (title.length < 2) return null;
    if (RegExp(r'^\d+$').hasMatch(title)) return null;
    if (RegExp(r'^(vid|img|dsc|mov|record|temp|untitled|screenrecording|screenshot)\b', caseSensitive: false).hasMatch(title)) {
      return null;
    }
    // 32 位 MD5、SHA 或十六进制哈希
    if (RegExp(r'^[0-9a-fA-F]{16,}$').hasMatch(title.replaceAll(' ', ''))) {
      return null;
    }

    // 字符有效性：若含有过多特殊乱码，非有效语言文字
    final validChars = RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9\u3040-\u30ff\uac00-\ud7af]');
    final validMatches = validChars.allMatches(title).length;
    if (validMatches < 2 || (validMatches / title.length) < 0.4) {
      return null;
    }

    // 长度截断，避免异常长标题注入
    if (title.length > 50) {
      title = title.substring(0, 50).trim();
    }

    return title;
  }

  /// 构造针对大模型的翻译指令（Prompt / reference）。
  static String buildLlmReference({String? rawTitle}) {
    final cleanTitle = sanitizeVideoTitle(rawTitle);
    if (cleanTitle != null && cleanTitle.isNotEmpty) {
      return '当前对白出自影视作品《$cleanTitle》。请结合该作品的背景、角色关系与剧情口语语境，将以下对白台词翻译为通顺、地道的中文字幕，保持口语化。';
    }
    return '请将以下影视对白台词翻译为通顺、地道的中文字幕，保持口语化。';
  }

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
    String? contextTitle,
  }) async {
    if (texts.isEmpty) return const [];
    if (appId.isEmpty || secretKey.isEmpty) {
      throw const TranslationException('未配置百度翻译 APP ID 或密钥 (Secret Key)。');
    }

    final isLlm = modelType == 'llm';
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

    // 根据模式决定请求端点
    final endpoints = isLlm
        ? [
            _llmEndpoint,
            'http://fanyi-api.baidu.com/ait/api/aiTextTranslate',
          ]
        : [
            _nmtEndpoint,
            'http://fanyi-api.baidu.com/api/trans/vip/translate',
          ];

    for (final currentKey in candidateKeys) {
      final salt = (DateTime.now().millisecondsSinceEpoch + Random().nextInt(10000)).toString();
      final signStr = '$appId$query$salt$currentKey';
      final sign = md5.convert(utf8.encode(signStr)).toString().toLowerCase();

      final bodyData = <String, String>{
        'q': query,
        'from': fromLang,
        'to': toLang,
        'appid': appId,
        'salt': salt,
        'sign': sign,
      };

      if (isLlm) {
        bodyData['model_type'] = 'llm';
        bodyData['reference'] = buildLlmReference(rawTitle: contextTitle);
      }

      // 优先尝试 HTTPS，若遇到网络代理拦截或 HandshakeException，自动回退到 HTTP 接口
      for (final endpoint in endpoints) {
        try {
          final res = await AdaptiveHttpClient.post(
            Uri.parse(endpoint),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: bodyData,
            timeout: Duration(seconds: isLlm ? 18 : 12),
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
        // 百度大模型成功返回 error_code 为 "52000"
        if (code != '52000') {
          final msg = data['error_msg']?.toString() ?? '未知错误';
          throw TranslationException(_getFriendlyErrorMessage(code, msg), code: code);
        }
      }

      // 兼容大模型格式 data['result']['trans_result'] 与通用翻译格式 data['trans_result']
      List<dynamic>? transList;
      if (data['result'] is Map && data['result']['trans_result'] is List) {
        transList = data['result']['trans_result'] as List<dynamic>;
      } else if (data['trans_result'] is List) {
        transList = data['trans_result'] as List<dynamic>;
      }

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
