/// 本地离线翻译引擎预留抽象。
///
/// 用于未来接入本地轻量神经机器翻译模型（如 NLLB ONNX）或本地兼容接口。
library;

import 'translation_engine.dart';

class LocalTranslationEngine implements TranslationEngine {
  LocalTranslationEngine({
    this.endpoint = '',
  });

  /// 本地模型或兼容服务地址（可选预留）。
  final String endpoint;

  @override
  String get id => 'local';

  @override
  String get displayName => '本地模型 (离线)';

  @override
  Future<String> testConnection({String testText = 'Hello'}) async {
    throw const TranslationException(
      '本地离线翻译模型尚在开发规划中，敬请期待后续版本。建议先在设置中选用百度、腾讯或微软 Azure 在线翻译（均有免费额度）。',
    );
  }

  @override
  Future<List<String>> translateBatch({
    required List<String> texts,
    required String targetLanguage,
    String sourceLanguage = 'auto',
  }) async {
    throw const TranslationException(
      '本地离线翻译功能暂未就绪，请前往设置切换为在线翻译 API。',
    );
  }
}
