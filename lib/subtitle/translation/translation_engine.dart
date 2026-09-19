/// 翻译子系统：引擎抽象基类、通用异常与语言定义。
library;

/// 翻译异常。
class TranslationException implements Exception {
  const TranslationException(this.message, {this.code, this.rawError});

  final String message;
  final String? code;
  final dynamic rawError;

  @override
  String toString() {
    if (code != null && code!.isNotEmpty) {
      return '[$code] $message';
    }
    return message;
  }
}

/// 目标语言模型。
class TranslationLanguage {
  const TranslationLanguage({
    required this.code,
    required this.name,
    required this.baiduCode,
    required this.azureCode,
  });

  /// 标准统一代码（如 zh-Hans, en, ja）。
  final String code;

  /// 显示名称（如 简体中文, English）。
  final String name;

  /// 百度翻译对应的语言代码。
  final String baiduCode;

  /// 微软 Azure 翻译对应的语言代码。
  final String azureCode;

  /// 支持的目标语言列表。
  static const List<TranslationLanguage> supportedLanguages = [
    TranslationLanguage(
      code: 'zh-Hans',
      name: '简体中文',
      baiduCode: 'zh',
      azureCode: 'zh-Hans',
    ),
    TranslationLanguage(
      code: 'zh-Hant',
      name: '繁体中文',
      baiduCode: 'cht',
      azureCode: 'zh-Hant',
    ),
    TranslationLanguage(
      code: 'en',
      name: '英语 (English)',
      baiduCode: 'en',
      azureCode: 'en',
    ),
    TranslationLanguage(
      code: 'ja',
      name: '日语 (日本語)',
      baiduCode: 'jp',
      azureCode: 'ja',
    ),
    TranslationLanguage(
      code: 'ko',
      name: '韩语 (한국어)',
      baiduCode: 'kor',
      azureCode: 'ko',
    ),
    TranslationLanguage(
      code: 'fr',
      name: '法语 (Français)',
      baiduCode: 'fra',
      azureCode: 'fr',
    ),
    TranslationLanguage(
      code: 'de',
      name: '德语 (Deutsch)',
      baiduCode: 'de',
      azureCode: 'de',
    ),
    TranslationLanguage(
      code: 'es',
      name: '西班牙语 (Español)',
      baiduCode: 'spa',
      azureCode: 'es',
    ),
    TranslationLanguage(
      code: 'ru',
      name: '俄语 (Русский)',
      baiduCode: 'ru',
      azureCode: 'ru',
    ),
    TranslationLanguage(
      code: 'it',
      name: '意大利语 (Italiano)',
      baiduCode: 'it',
      azureCode: 'it',
    ),
    TranslationLanguage(
      code: 'pt',
      name: '葡萄牙语 (Português)',
      baiduCode: 'pt',
      azureCode: 'pt',
    ),
    TranslationLanguage(
      code: 'vi',
      name: '越南语 (Tiếng Việt)',
      baiduCode: 'vie',
      azureCode: 'vi',
    ),
    TranslationLanguage(
      code: 'th',
      name: '泰语 (ไทย)',
      baiduCode: 'th',
      azureCode: 'th',
    ),
    TranslationLanguage(
      code: 'ar',
      name: '阿拉伯语 (العربية)',
      baiduCode: 'ara',
      azureCode: 'ar',
    ),
  ];

  static TranslationLanguage findByCode(String code) {
    return supportedLanguages.firstWhere(
      (l) => l.code == code || l.baiduCode == code,
      orElse: () => supportedLanguages.first,
    );
  }
}

/// 翻译引擎统一接口。
abstract class TranslationEngine {
  /// 引擎唯一标识（baidu / azure / local）。
  String get id;

  /// 引擎显示名称。
  String get displayName;

  /// 验证并测试当前配置的有效性。
  ///
  /// 返回测试翻译结果（如成功返回目标译文），失败时抛出 [TranslationException]。
  Future<String> testConnection({String testText = 'Hello'});

  /// 批量翻译文本列表。
  ///
  /// [texts]: 待翻译文本列表。
  /// [targetLanguage]: 目标语言标准代码（如 `zh-Hans`）。
  /// [sourceLanguage]: 源语言代码，默认 `'auto'` 自动识别。
  ///
  /// 返回与 [texts] 一一对应的翻译后文本列表。
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String targetLanguage,
    String sourceLanguage = 'auto',
    String? contextTitle,
  });

  /// 当前引擎是否已完成必要的凭据/地址配置。
  bool get isConfigured;

  /// 未配置时的提示文案（如已就绪则为 null）。
  String? get configurationError;
}
