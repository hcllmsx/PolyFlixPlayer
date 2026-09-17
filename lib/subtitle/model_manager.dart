/// Whisper 模型管理：下载、校验、查询、删除。
///
/// 模型文件存放在独立的 models/ 目录下（与 cache/ 分离），清理缓存
/// 时不会被误删。用户可通过设置页的"管理模型"入口手动管理。
///
/// 下载 URL 支持可配置：开发阶段先从 HuggingFace 下载，之后用户
/// 上传到自己的存储桶后替换链接即可。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../settings/app_settings.dart';
import '../utils/native_file_helper.dart';

/// 模型信息。
class WhisperModelInfo {
  const WhisperModelInfo({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.downloadUrl,
    required this.sizeBytes,
    this.sha256,
    this.isEnglishOnly = false,
    this.isQuantized = false,
  });

  final String id;

  /// 界面上展示的名称（如 "Small · 英语专用 · q5"）。
  final String displayName;

  final String fileName;
  final String downloadUrl;
  final int sizeBytes;
  final String? sha256;

  /// 英文专用模型（`.en`）：只能识别英语，英语准确率略高、速度略快。
  final bool isEnglishOnly;

  /// 量化版（q5/q8）：体积更小、速度更快，精度略降。
  final bool isQuantized;

  /// 体积展示文案，如 "466 MB" / "1.5 GB"。
  String get sizeLabel {
    const mb = 1024 * 1024;
    if (sizeBytes >= 1024 * mb) {
      return '${(sizeBytes / (1024 * mb)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / mb).round()} MB';
  }

  /// 国内镜像地址（hf-mirror）。
  ///
  /// 国内网络直连 huggingface.co 会被拒（而且 Dart 的 HttpClient 不读系统代理），
  /// 实测 hf-mirror 可直连，因此作为自动回退的备用下载源。
  String get mirrorUrl =>
      'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/$fileName';
}

/// 生成一条模型定义（文件名与下载地址都按 id 推导，避免手写出错）。
WhisperModelInfo _model(String id, int sizeMiB) {
  final englishOnly = id.contains('.en');
  final quant = RegExp(r'-(q\d_\d)$').firstMatch(id)?.group(1);
  final family = id
      .replaceAll('.en', '')
      .replaceAll(RegExp(r'-q\d_\d$'), '');

  const familyLabels = {
    'tiny': 'Tiny 极速',
    'base': 'Base 平衡',
    'small': 'Small 精确',
    'medium': 'Medium 高精度',
    'large-v3-turbo': 'Large v3 Turbo',
    'large-v3': 'Large v3',
  };

  final parts = <String>[
    familyLabels[family] ?? family,
    if (englishOnly) '英语专用',
    if (quant != null) quant.replaceAll('_', ''),
  ];

  return WhisperModelInfo(
    id: id,
    displayName: parts.join(' · '),
    fileName: 'ggml-$id.bin',
    downloadUrl:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$id.bin',
    sizeBytes: sizeMiB * 1024 * 1024,
    isEnglishOnly: englishOnly,
    isQuantized: quant != null,
  );
}

/// 可用的 Whisper 模型清单（都是 ggml 格式，与识别引擎包通用）。
///
/// 说明：
///  - **多语言**：支持 99 种语言自动侦测，日常首选；
///  - **英语专用（.en）**：只认英语，英语场景下更准更快，喂其它语言会输出乱码；
///  - **量化（q5 / q8）**：体积小、速度快，精度略降，适合 CPU 或磁盘紧张的用户；
///  - **Large v3 Turbo**：精度接近 large，速度快得多，配合 GPU 引擎包性价比最高。
///
/// 体积来自 HuggingFace 上的实际文件大小；下载后按体积做完整性校验。
final List<WhisperModelInfo> availableModels = [
  // ---- 多语言 ----
  _model('tiny', 75),
  _model('tiny-q5_1', 31),
  _model('tiny-q8_0', 42),
  _model('base', 142),
  _model('base-q5_1', 57),
  _model('base-q8_0', 78),
  _model('small', 466),
  _model('small-q5_1', 181),
  _model('small-q8_0', 252),
  _model('medium', 1463),
  _model('medium-q5_0', 514),
  _model('medium-q8_0', 785),
  _model('large-v3-turbo', 1549),
  _model('large-v3-turbo-q5_0', 547),
  _model('large-v3-turbo-q8_0', 834),
  _model('large-v3', 2952),
  _model('large-v3-q5_0', 1126),

  // ---- 英语专用 ----
  _model('tiny.en', 75),
  _model('tiny.en-q5_1', 31),
  _model('base.en', 142),
  _model('base.en-q5_1', 57),
  _model('base.en-q8_0', 78),
  _model('small.en', 465),
  _model('small.en-q5_1', 181),
  _model('small.en-q8_0', 252),
  _model('medium.en', 1463),
  _model('medium.en-q5_0', 514),
  _model('medium.en-q8_0', 785),
];

/// 多语言模型（按体积升序）。
List<WhisperModelInfo> get multilingualModels =>
    availableModels.where((m) => !m.isEnglishOnly).toList();

/// 英语专用模型（按体积升序）。
List<WhisperModelInfo> get englishOnlyModels =>
    availableModels.where((m) => m.isEnglishOnly).toList();

/// 模型下载进度回调。
///
/// [received] 已下载字节数，[total] 总字节数（-1 表示未知）。
typedef ModelDownloadProgress = void Function(int received, int total);

/// 本地导入模型的结果。
class ModelImportResult {
  const ModelImportResult({
    required this.success,
    required this.message,
    this.modelId,
  });

  final bool success;
  final String message;

  /// 成功时写入的模型 ID（tiny / base / small）。
  final String? modelId;
}

/// 模型管理器。
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  /// 最近一次下载实际使用的源（供界面提示，如"国内镜像 hf-mirror"）。
  static String? lastDownloadSourceLabel;

  /// 按 ID 取模型定义；未知 ID 返回 null。
  WhisperModelInfo? infoOf(String modelId) {
    for (final m in availableModels) {
      if (m.id == modelId) return m;
    }
    return null;
  }

  /// 获取指定模型在本地的文件路径。如果不存在返回 null。
  Future<String?> getModelPath(String modelId) async {
    final info = availableModels.where((m) => m.id == modelId).firstOrNull;
    if (info == null) return null;
    final dirPath = await NativeFileHelper.getWhisperModelDirPath();
    final file = File('$dirPath${Platform.pathSeparator}${info.fileName}');
    if (await file.exists()) return file.path;

    // 开发/本地测试回退：自动检查项目 _temp\models\whisper 目录
    try {
      final sep = Platform.pathSeparator;
      final fileName = info.fileName;
      final root = Directory.current.path;
      final candidates = [
        File('$root${sep}_temp${sep}models${sep}whisper$sep$fileName'),
        File('$root${sep}_temp$sep$fileName'),
      ];
      for (final candidate in candidates) {
        if (await candidate.exists()) {
          return candidate.path;
        }
      }
    } catch (_) {}

    return null;
  }

  /// 检查指定模型是否已下载。
  Future<bool> isModelDownloaded(String modelId) async {
    return await getModelPath(modelId) != null;
  }

  /// 获取所有已下载模型的 ID 列表。
  Future<List<String>> getDownloadedModels() async {
    final downloaded = <String>[];
    for (final model in availableModels) {
      if (await isModelDownloaded(model.id)) {
        downloaded.add(model.id);
      }
    }
    return downloaded;
  }

  /// 下载模型文件。
  ///
  /// [modelId] 模型 ID（如 'tiny'、'base'、'small'）。
  /// [onProgress] 下载进度回调。
  /// 返回下载后的本地文件路径。
  ///
  /// 如果模型已存在，直接返回路径不重复下载。
  Future<String> downloadModel(
    String modelId, {
    ModelDownloadProgress? onProgress,
  }) async {
    final info = availableModels.where((m) => m.id == modelId).firstOrNull;
    if (info == null) throw ArgumentError('未知模型 ID: $modelId');

    final dirPath = await NativeFileHelper.getWhisperModelDirPath();
    final dir = Directory(dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);

    final filePath = '$dirPath${Platform.pathSeparator}${info.fileName}';
    final file = File(filePath);

    // 已存在则跳过
    if (await file.exists()) {
      final size = await file.length();
      // 检查文件大小是否合理（防止下载中断产生的残文件）
      if (size > info.sizeBytes * 0.9) return filePath;
      // 大小异常，删除重新下载
      await file.delete();
    }

    // 下载到临时文件，完成后再重命名，避免中断产生的残文件
    final tmpFile = File('$filePath.downloading');
    final sources = <({String label, String url})>[
      if (modelDownloadSource.value != 'mirror') (
        label: 'HuggingFace 官方源',
        url: info.downloadUrl
      ),
      (label: '国内镜像 hf-mirror', url: info.mirrorUrl),
    ];

    Object? lastError;
    for (final source in sources) {
      try {
        await _downloadFrom(source.url, tmpFile, info, onProgress);
        await tmpFile.rename(filePath);
        lastDownloadSourceLabel = source.label;
        return filePath;
      } catch (e) {
        lastError = e;
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
      }
    }
    throw Exception('所有下载源均失败（${sources.map((s) => s.label).join("、")}）：$lastError');
  }

  /// 从指定地址下载到临时文件并做完整性校验。
  Future<void> _downloadFrom(
    String url,
    File tmpFile,
    WhisperModelInfo info,
    ModelDownloadProgress? onProgress,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      // 连接阶段设超时：官方源在国内常被拒，卡住会白等很久
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }

      final contentLength = response.contentLength ?? info.sizeBytes;
      final sink = tmpFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, contentLength);
        }
      } finally {
        await sink.close();
      }

      // 体积校验：拦截被墙返回的 HTML 错误页 / 中断产生的残文件
      final downloadedSize = await tmpFile.length();
      if (downloadedSize < info.sizeBytes * 0.9) {
        throw Exception('文件体积异常（$downloadedSize 字节），可能下载不完整');
      }

      if (info.sha256 != null) {
        final bytes = await tmpFile.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        if (hash != info.sha256) {
          throw Exception('文件校验失败：哈希不匹配');
        }
      }
    } finally {
      client.close();
    }
  }

  /// 从本地文件导入一个已下载好的 ggml 模型。
  ///
  /// 用于"网络不好，自己离线下载模型再导入"的场景：校验文件确实是 ggml
  /// 模型（magic 头 4 字节为 `ggml`），再按文件名或体积判断属于哪个模型，
  /// 最后流式复制到模型目录，复制过程通过 [onProgress] 回报字节数。
  Future<ModelImportResult> importModelFile(
    String sourcePath, {
    void Function(int copied, int total)? onProgress,
  }) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) {
        return const ModelImportResult(success: false, message: '文件不存在或无法读取');
      }

      // 1) 校验文件头 magic。
      //    whisper.cpp 的 ggml 模型把 magic 0x67676d6c 按小端写入，
      //    因此文件前 4 字节是 "lmgg"；同时兼容大端写法与新版 GGUF 格式。
      final raf = await source.open();
      final header = await raf.read(4);
      await raf.close();
      final isGgmlLittleEndian =
          header.length == 4 && header[0] == 0x6c && header[1] == 0x6d &&
              header[2] == 0x67 && header[3] == 0x67;
      final isGgmlBigEndian =
          header.length == 4 && header[0] == 0x67 && header[1] == 0x67 &&
              header[2] == 0x6d && header[3] == 0x6c;
      final isGguf =
          header.length == 4 && header[0] == 0x47 && header[1] == 0x47 &&
              header[2] == 0x55 && header[3] == 0x46;
      if (!isGgmlLittleEndian && !isGgmlBigEndian && !isGguf) {
        return const ModelImportResult(
          success: false,
          message: '这不是 Whisper 的 ggml 模型文件（文件头校验失败）',
        );
      }

      // 2) 判断属于哪个模型：先看文件名，再看体积
      final fileName = sourcePath.split(Platform.pathSeparator).last;
      final lowerName = fileName.toLowerCase();
      final size = await source.length();

      WhisperModelInfo? target;
      for (final model in availableModels) {
        if (lowerName.contains(model.id)) {
          target = model;
          break;
        }
      }
      if (target == null) {
        var bestDelta = double.infinity;
        for (final model in availableModels) {
          final delta =
              (size - model.sizeBytes).abs() / model.sizeBytes;
          if (delta < 0.15 && delta < bestDelta) {
            bestDelta = delta;
            target = model;
          }
        }
      }
      if (target == null) {
        final expected = availableModels
            .map((m) => '${m.id} 约 ${(m.sizeBytes ~/ (1024 * 1024))}MB')
            .join('、');
        return ModelImportResult(
          success: false,
          message: '无法识别模型类型（文件体积 ${(size / (1024 * 1024)).toStringAsFixed(0)}MB）。'
              '请使用官方 ggml-*.bin 文件，或将文件名带上模型名。预期：$expected',
        );
      }

      // 3) 流式复制到模型目录
      final dirPath = await NativeFileHelper.getWhisperModelDirPath();
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final destPath = '$dirPath${Platform.pathSeparator}${target.fileName}';
      final dest = File(destPath);

      // 用户直接选中模型目录里已有的那个文件时，绝不能"先删后复制"——会把源文件删掉
      if (await dest.exists() &&
          dest.absolute.path.toLowerCase() == source.absolute.path.toLowerCase()) {
        return ModelImportResult(
          success: true,
          message: '${target.displayName} 已在模型目录中，无需重复导入',
          modelId: target.id,
        );
      }
      if (await dest.exists()) await dest.delete();

      final sink = dest.openWrite();
      var copied = 0;
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        copied += chunk.length;
        onProgress?.call(copied, size);
      }
      await sink.flush();
      await sink.close();

      return ModelImportResult(
        success: true,
        message: '已导入 ${target.displayName} 模型',
        modelId: target.id,
      );
    } catch (e) {
      return ModelImportResult(success: false, message: '导入失败：$e');
    }
  }

  /// 删除指定模型。
  Future<void> deleteModel(String modelId) async {
    final path = await getModelPath(modelId);
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// 删除所有已下载的模型。
  Future<int> deleteAllModels() async {
    return NativeFileHelper.clearModels();
  }
}
