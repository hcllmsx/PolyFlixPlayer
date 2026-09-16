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
  });

  final String id;
  final String displayName;
  final String fileName;
  final String downloadUrl;
  final int sizeBytes;
  final String? sha256;
}

/// 可用的 Whisper 模型列表。
///
/// 下载 URL 默认指向 HuggingFace。后续替换为你的存储桶链接即可。
const List<WhisperModelInfo> availableModels = [
  WhisperModelInfo(
    id: 'tiny',
    displayName: 'Tiny（75MB · 速度最快）',
    fileName: 'ggml-tiny.bin',
    downloadUrl: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
    sizeBytes: 75 * 1024 * 1024,
  ),
  WhisperModelInfo(
    id: 'base',
    displayName: 'Base（140MB · 平衡）',
    fileName: 'ggml-base.bin',
    downloadUrl: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
    sizeBytes: 140 * 1024 * 1024,
  ),
  WhisperModelInfo(
    id: 'small',
    displayName: 'Small（460MB · 高精度）',
    fileName: 'ggml-small.bin',
    downloadUrl: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
    sizeBytes: 460 * 1024 * 1024,
  ),
];

/// 模型下载进度回调。
///
/// [received] 已下载字节数，[total] 总字节数（-1 表示未知）。
typedef ModelDownloadProgress = void Function(int received, int total);

/// 模型管理器。
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

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
    try {
      final request = http.Request('GET', Uri.parse(info.downloadUrl));
      final response = await http.Client().send(request);

      if (response.statusCode != 200) {
        throw HttpException(
          '下载失败：HTTP ${response.statusCode}',
          uri: Uri.parse(info.downloadUrl),
        );
      }

      final contentLength = response.contentLength ?? info.sizeBytes;
      final sink = tmpFile.openWrite();
      var received = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, contentLength);
      }
      await sink.close();

      // 校验文件大小
      final downloadedSize = await tmpFile.length();
      if (downloadedSize < info.sizeBytes * 0.9) {
        await tmpFile.delete();
        throw Exception('下载的文件大小异常（$downloadedSize 字节），可能下载不完整');
      }

      // SHA256 校验（如果提供了）
      if (info.sha256 != null) {
        final bytes = await tmpFile.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        if (hash != info.sha256) {
          await tmpFile.delete();
          throw Exception('文件校验失败：哈希不匹配');
        }
      }

      // 重命名为正式文件名
      await tmpFile.rename(filePath);
      return filePath;
    } catch (e) {
      // 清理临时文件
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
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
