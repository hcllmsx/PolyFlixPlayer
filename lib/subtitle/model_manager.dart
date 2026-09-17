/// Whisper 模型管理：清单、已导入查询、导入与删除。
///
/// 重要：应用**不内置任何下载链接**（官方源与镜像都不内置）。模型由用户自行获取
/// （设置页「浏览全部模型」里有对照表与网盘入口）后，用「导入模型」导入到本地目录。
///
/// 模型文件存放在独立的 models/ 目录下（与 cache/ 分离），清理缓存时不会被误删。
/// 用户可通过设置页的「模型目录」按钮直接查看该目录。
library;

import 'dart:io';

import '../utils/native_file_helper.dart';

/// 模型信息。
///
/// 应用**不内置任何下载链接**（官方源与镜像都不内置）。这里既是界面上
/// "模型对照表"的数据源，也用于「导入模型」时按文件名 / 体积识别用户导入的是哪个模型。
class WhisperModelInfo {
  const WhisperModelInfo({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.sizeBytes,
    required this.tier,
    required this.summary,
    this.cpuHint,
    this.isEnglishOnly = false,
    this.isQuantized = false,
    this.legacy = false,
  });

  final String id;

  /// 界面上展示的名称（如 "Small · 英语专用 · q5"）。
  final String displayName;

  /// 官方原始文件名（如 `ggml-small-q5_1.bin`）。
  ///
  /// 表格里按它显示——用户去网盘找文件、或自己核对导入结果时，认的是这个名字。
  final String fileName;

  final int sizeBytes;

  /// 档位文案：极速 / 平衡 / 精确 / 高精度 / 旗舰。
  final String tier;

  /// 一句话说明：这个模型适合什么场景、有什么取舍。
  final String summary;

  /// 纯 CPU 识别 1 小时视频的大致耗时（参考值）。
  final String? cpuHint;

  /// 英文专用模型（`.en`）：只能识别英语，英语准确率略高、速度略快。
  final bool isEnglishOnly;

  /// 量化版（q5/q8）：体积更小、速度更快，精度略降。
  final bool isQuantized;

  /// 旧版本（large-v1）：仅作兼容，不推荐新用户使用。
  final bool legacy;

  /// 体积展示文案，如 "466 MB" / "1.5 GB"。
  String get sizeLabel {
    const mb = 1024 * 1024;
    if (sizeBytes >= 1024 * mb) {
      return '${(sizeBytes / (1024 * mb)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / mb).round()} MB';
  }
}

/// 生成一条模型定义（文件名按 id 推导，避免手写出错）。
///
/// [sizeMiB] 取官方文件的真实体积（MiB），仅用于展示与导入时的体积比对。
WhisperModelInfo _model(
  String id,
  double sizeMiB,
  String tier,
  String summary, {
  String? cpuHint,
  bool legacy = false,
}) {
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
    'large-v1': 'Large v1',
    'large-v2': 'Large v2',
    'large-v3': 'Large v3',
    'large-v3-turbo': 'Large v3 Turbo',
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
    sizeBytes: (sizeMiB * 1024 * 1024).round(),
    tier: tier,
    summary: summary,
    cpuHint: cpuHint,
    isEnglishOnly: englishOnly,
    isQuantized: quant != null,
    legacy: legacy,
  );
}

/// 全部可用模型清单（对应官方 ggerganov/whisper.cpp 仓库里的 ggml-*.bin 文件）。
///
/// 说明：
///  - **多语言**：支持 99 种语言自动侦测，日常首选；
///  - **英语专用（.en）**：只认英语，英语场景下更准更快，喂其它语言会输出乱码；
///  - **量化（q5 / q8）**：体积小、速度快，精度略降，适合 CPU 或磁盘紧张的用户；
///  - **Large v3 Turbo**：精度接近 large，速度快得多，配合 GPU 引擎包性价比最高。
///
/// 体积取自官方文件真实大小（MiB）；导入时按体积做容差比对。
/// CPU 耗时是纯 CPU 识别 1 小时视频的大致参考（12 线程实测，实际取决于机器）。
final List<WhisperModelInfo> availableModels = [
  // ---------------- 多语言 ----------------
  _model('tiny', 74.1, '极速', '最快的一档，精度最低；低配机器、或只想快速看个大概时用',
      cpuHint: '约 1 分钟'),
  _model('tiny-q5_1', 30.7, '极速', 'tiny 的量化版：体积不到一半、速度略快，精度再降一点',
      cpuHint: '约 1 分钟'),
  _model('tiny-q8_0', 41.5, '极速', 'tiny 的轻量化版，比 q5 稍准、稍大', cpuHint: '约 1 分钟'),
  _model('base', 141.1, '平衡', '入门档：比 tiny 明显准确，速度依然很快', cpuHint: '约 2 分钟'),
  _model('base-q5_1', 56.9, '平衡', 'base 的量化版，体积小、速度快', cpuHint: '约 1.5 分钟'),
  _model('base-q8_0', 78.0, '平衡', 'base 的轻量化版，精度损失比 q5 小', cpuHint: '约 1.5 分钟'),
  _model('small', 465.0, '精确', '日常首选：精度与速度的平衡点，中文识别够用',
      cpuHint: '约 4~5 分钟'),
  _model('small-q5_1', 181.3, '精确', 'small 的量化版：体积不到四成，省空间的首选',
      cpuHint: '约 3~4 分钟'),
  _model('small-q8_0', 252.2, '精确', 'small 的轻量化版，精度损失比 q5 小', cpuHint: '约 3~4 分钟'),
  _model('medium', 1462.7, '高精度', '精度明显提升，口音与专业词汇更稳；CPU 上耗时明显变长',
      cpuHint: '约 13 分钟'),
  _model('medium-q5_0', 514.2, '高精度', 'medium 的量化版，体积接近 small', cpuHint: '约 9 分钟'),
  _model('medium-q8_0', 785.2, '高精度', 'medium 的轻量化版', cpuHint: '约 11 分钟'),
  _model('large-v3-turbo', 1549.3, '旗舰·快速', '精度接近 large-v3 但快数倍；有 GPU 时的首选',
      cpuHint: '约 6~8 分钟'),
  _model('large-v3-turbo-q5_0', 547.4, '旗舰·快速',
      '综合推荐：体积小、速度快，大模型里性价比最高', cpuHint: '约 5 分钟'),
  _model('large-v3-turbo-q8_0', 833.7, '旗舰·快速', 'turbo 的轻量化版，精度损失更小',
      cpuHint: '约 6 分钟'),
  _model('large-v3', 2951.7, '旗舰', '官方最强多语言精度；纯 CPU 上很慢，建议配合 CUDA 引擎包',
      cpuHint: '约 30 分钟'),
  _model('large-v3-q5_0', 1031.1, '旗舰', 'large-v3 的量化版，体积约三分之一',
      cpuHint: '约 20 分钟'),
  _model('large-v2', 2951.3, '旗舰', '上一代 large，精度与 v3 接近，某些素材上更稳',
      cpuHint: '约 30 分钟'),
  _model('large-v2-q5_0', 1030.7, '旗舰', 'large-v2 的量化版', cpuHint: '约 20 分钟'),
  _model('large-v2-q8_0', 1579.4, '旗舰', 'large-v2 的轻量化版', cpuHint: '约 24 分钟'),
  _model('large-v1', 2951.3, '旗舰·旧版', '初代 large，已过时；仅作兼容，不推荐新用户使用',
      cpuHint: '约 30 分钟', legacy: true),

  // ---------------- 英语专用（.en：只识别英语，同档位更快更准） ----------------
  _model('tiny.en', 74.1, '极速', '仅英语：同档位下更快更准；别拿去识别其它语言',
      cpuHint: '约 1 分钟'),
  _model('tiny.en-q5_1', 30.7, '极速', '仅英语，tiny.en 的量化版', cpuHint: '约 1 分钟'),
  _model('tiny.en-q8_0', 41.5, '极速', '仅英语，tiny.en 的轻量化版', cpuHint: '约 1 分钟'),
  _model('base.en', 141.1, '平衡', '仅英语：比 tiny.en 明显准确', cpuHint: '约 2 分钟'),
  _model('base.en-q5_1', 57.0, '平衡', '仅英语，base.en 的量化版', cpuHint: '约 1.5 分钟'),
  _model('base.en-q8_0', 78.0, '平衡', '仅英语，base.en 的轻量化版', cpuHint: '约 1.5 分钟'),
  _model('small.en', 465.0, '精确', '仅英语：英语场景下精度与速度兼顾的首选',
      cpuHint: '约 4~5 分钟'),
  _model('small.en-q5_1', 181.3, '精确', '仅英语，small.en 的量化版', cpuHint: '约 3~4 分钟'),
  _model('small.en-q8_0', 252.2, '精确', '仅英语，small.en 的轻量化版', cpuHint: '约 3~4 分钟'),
  _model('medium.en', 1462.7, '高精度', '仅英语：英语精度很高，CPU 上耗时不短',
      cpuHint: '约 13 分钟'),
  _model('medium.en-q5_0', 514.2, '高精度', '仅英语，medium.en 的量化版', cpuHint: '约 9 分钟'),
  _model('medium.en-q8_0', 785.2, '高精度', '仅英语，medium.en 的轻量化版', cpuHint: '约 11 分钟'),
];

/// 多语言模型（按体积升序）。
List<WhisperModelInfo> get multilingualModels =>
    availableModels.where((m) => !m.isEnglishOnly).toList();

/// 英语专用模型（按体积升序）。
List<WhisperModelInfo> get englishOnlyModels =>
    availableModels.where((m) => m.isEnglishOnly).toList();

/// 本地导入模型的结果。
class ModelImportResult {
  const ModelImportResult({
    required this.success,
    required this.message,
    this.modelId,
  });

  final bool success;
  final String message;

  /// 成功时写入的模型 ID（如 tiny / base / small）。
  final String? modelId;
}

/// 模型管理器。
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  /// 按 ID 取模型定义；未知 ID 返回 null。
  WhisperModelInfo? infoOf(String modelId) {
    for (final m in availableModels) {
      if (m.id == modelId) return m;
    }
    return null;
  }

  /// 获取指定模型在本地的文件路径。如果不存在返回 null。
  ///
  /// 只认应用自己的模型目录（桌面端为 `%LOCALAPPDATA%\PolyFlixPlayer\models\whisper`）。
  /// 这里**刻意不做**"找不到就去项目 _temp 目录捞一份"的开发回退：那段回退会让
  /// "已导入"判定与删除操作都指向仓库里的临时副本 —— 删掉真正的模型后列表仍显示
  /// "已导入"（因为 _temp 那份还在），要点两次才删得掉；发布版更会去访问用户设备上
  /// 根本不存在的目录。开发调试请把模型放进应用模型目录（设置页「模型目录」可直接打开），
  /// 或用「导入模型」导入。
  Future<String?> getModelPath(String modelId) async {
    final info = availableModels.where((m) => m.id == modelId).firstOrNull;
    if (info == null) return null;
    final file = File(await _managedFilePath(info));
    return await file.exists() ? file.path : null;
  }

  /// 模型在应用模型目录中的目标路径（无论文件是否已存在）。
  ///
  /// [getModelPath]、[deleteModel] 都经由它解析路径，保证"显示的、导入的、
  /// 删除的"始终是同一个文件，不会出现删一次还在的情况。
  Future<String> _managedFilePath(WhisperModelInfo info) async {
    final dirPath = await NativeFileHelper.getWhisperModelDirPath();
    return '$dirPath${Platform.pathSeparator}${info.fileName}';
  }

  /// 检查指定模型是否已导入到本地。
  Future<bool> isModelDownloaded(String modelId) async {
    return await getModelPath(modelId) != null;
  }

  /// 获取所有已导入模型的 ID 列表。
  Future<List<String>> getDownloadedModels() async {
    final downloaded = <String>[];
    for (final model in availableModels) {
      if (await isModelDownloaded(model.id)) {
        downloaded.add(model.id);
      }
    }
    return downloaded;
  }

  /// 从本地文件导入一个已下载好的 ggml 模型。
  ///
  /// 用于"自己去网盘下载模型再导入"的场景：校验文件确实是 ggml
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

      // 2) 判断属于哪个模型：文件名优先，体积兜底
      final fileName = sourcePath.split(Platform.pathSeparator).last;
      final lowerName = fileName.toLowerCase();
      final size = await source.length();

      WhisperModelInfo? target;
      // 2a) 完整文件名精确匹配（最可靠）：必须先走这一步，
      //     否则 `ggml-small.en.bin` 会被 `small` 抢先匹配成非英语模型。
      for (final model in availableModels) {
        if (lowerName == model.fileName.toLowerCase()) {
          target = model;
          break;
        }
      }
      // 2b) 文件名被改过时按"最长 ID 包含"匹配，同样避免 short 抢走 long（small vs small.en）
      if (target == null) {
        for (final model in availableModels) {
          if (lowerName.contains(model.id) &&
              (target == null || model.id.length > target.id.length)) {
            target = model;
          }
        }
      }
      // 2c) 名字完全对不上时按体积近似匹配
      if (target == null) {
        var bestDelta = double.infinity;
        for (final model in availableModels) {
          final delta = (size - model.sizeBytes).abs() / model.sizeBytes;
          if (delta < 0.15 && delta < bestDelta) {
            bestDelta = delta;
            target = model;
          }
        }
      }
      if (target == null) {
        return ModelImportResult(
          success: false,
          message: '无法识别模型类型（文件名 $fileName，体积 '
              '${(size / (1024 * 1024)).toStringAsFixed(0)}MB）。\n'
              '请使用官方 ggml-*.bin 文件（文件名不要改），'
              '完整清单见「浏览全部模型」表格。',
        );
      }

      // 3) 流式复制到模型目录
      final dirPath = await NativeFileHelper.getWhisperModelDirPath();
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final destPath = await _managedFilePath(target);
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
        message: '已导入 ${target.displayName}（${target.fileName}）',
        modelId: target.id,
      );
    } catch (e) {
      return ModelImportResult(success: false, message: '导入失败：$e');
    }
  }

  /// 删除指定模型。
  ///
  /// 只删应用模型目录里的文件（同时清掉历史遗留的 `.downloading` 半成品）。
  /// 路径解析与 [getModelPath] 完全一致，所以**删一次就真的没了**，
  /// 界面上"已导入"标记也会同步消失。
  Future<void> deleteModel(String modelId) async {
    final info = availableModels.where((m) => m.id == modelId).firstOrNull;
    if (info == null) return;
    final filePath = await _managedFilePath(info);
    for (final path in [filePath, '$filePath.downloading']) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  /// 删除所有已导入的模型。
  Future<int> deleteAllModels() async {
    return NativeFileHelper.clearModels();
  }
}
