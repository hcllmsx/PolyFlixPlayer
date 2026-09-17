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
