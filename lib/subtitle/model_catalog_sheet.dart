/// 全部语音模型对照表（介绍表格 + 已导入状态 + 选用/删除）。
///
/// 应用**不内置任何下载链接**，所以这张表承担"说明书"的角色：
/// 用户按表格选好模型 → 去网盘下载同名文件 → 用设置页的「导入模型」导入。
/// 表格左侧按官方原始文件名（如 `ggml-small-q5_1.bin`）展示，方便用户去网盘对照查找。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/app_toast.dart';
import '../utils/platform_utils.dart';
import 'download_links.dart';
import 'model_manager.dart';

/// 模型面板的返回结果。
class ModelPickerResult {
  const ModelPickerResult({required this.modelId});

  final String modelId;
}

class ModelCatalogSheet extends StatefulWidget {
  const ModelCatalogSheet({super.key, this.selectedId});

  /// 当前选中的模型 ID。
  final String? selectedId;

  /// 弹出面板；返回用户在表格里选用的模型（取消时返回 null）。
  static Future<ModelPickerResult?> show(
    BuildContext context, {
    String? selectedId,
  }) {
    return showModalBottomSheet<ModelPickerResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ModelCatalogSheet(selectedId: selectedId),
    );
  }

  @override
  State<ModelCatalogSheet> createState() => _ModelCatalogSheetState();
}

class _ModelCatalogSheetState extends State<ModelCatalogSheet> {
  Set<String> _imported = {};
  bool _loading = true;

  /// 鼠标当前悬停的模型行；只有悬停的那一行才显示"复制文件名"按钮。
  String? _hoveredModelId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await ModelManager.instance.getDownloadedModels();
    if (!mounted) return;
    setState(() {
      _imported = list.toSet();
      _loading = false;
    });
  }

  Future<void> _delete(WhisperModelInfo model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: Text(
          '确定要删除 ${model.displayName} 吗？\n'
          '删除的是已导入到模型目录的 ${model.fileName}，需要时可重新导入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ModelManager.instance.deleteModel(model.id);
    await _refresh();
    if (mounted) {
      AppToast.show(context, '已删除 ${model.fileName}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Icon(Icons.memory_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '全部语音模型',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _loading
                            ? '正在检查已导入的模型…'
                            : '已导入 ${_imported.length} / ${availableModels.length} 个模型',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 20),
              shrinkWrap: true,
              children: [
                _netdiskCard(scheme),
                _groupHeader(scheme, '多语言模型（支持 99 种语言自动侦测）'),
                _columnHeader(scheme),
                for (final m in multilingualModels) _row(m),
                _groupHeader(scheme, '英语专用模型（.en：只识别英语，同档位更快更准）'),
                _columnHeader(scheme),
                for (final m in englishOnlyModels) _row(m),
                _groupHeader(scheme, '无需下载的文件'),
                _notNeededNote(scheme),
                _footerNote(scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 网盘入口：链接由 [kModelNetdiskUrl] 提供，未填写时给出说明而不是留白。
  Widget _netdiskCard(ColorScheme scheme) {
    final url = kModelNetdiskUrl.trim();
    final code = kModelNetdiskCode.trim();
    final hasUrl = url.isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '模型网盘',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  hasUrl
                      ? '$url${code.isEmpty ? '' : '    提取码：$code'}'
                      : '链接待补充：全部 ggml-*.bin 文件会放在网盘里，链接就绪后这里会显示。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (hasUrl)
            IconButton(
              tooltip: '复制链接',
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () {
                final text = code.isEmpty ? url : '$url 提取码：$code';
                Clipboard.setData(ClipboardData(text: text));
                AppToast.show(context, '已复制网盘信息');
              },
            ),
        ],
      ),
    );
  }

  Widget _groupHeader(ColorScheme scheme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }

  /// 表头：说明每一列是什么。
  Widget _columnHeader(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '文件名 / 说明',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant.withValues(alpha: .8),
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              '体积',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant.withValues(alpha: .8),
              ),
            ),
          ),
          SizedBox(
            width: 62,
            child: Text(
              '状态',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant.withValues(alpha: .8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "复制文件名"按钮：悬停（或触屏）时显示在文件名右侧。
  Widget _copyButton(String fileName) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 22),
      icon: const Icon(Icons.copy_rounded, size: 15),
      tooltip: '复制文件名',
      onPressed: () {
        Clipboard.setData(ClipboardData(text: fileName));
        AppToast.show(context, '已复制 $fileName');
      },
    );
  }

  Widget _row(WhisperModelInfo model) {
    final scheme = Theme.of(context).colorScheme;
    final imported = _imported.contains(model.id);
    final selected = widget.selectedId == model.id;
    // 桌面端悬停才显示复制按钮；触屏没有 hover，直接常显
    final hovered = _hoveredModelId == model.id || !isDesktopPlatform;
    final tags = <String>[model.tier, model.summary];

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredModelId = model.id),
      onExit: (_) => setState(() {
        if (_hoveredModelId == model.id) _hoveredModelId = null;
      }),
      child: InkWell(
        onTap: imported
            ? () =>
                  Navigator.of(context)
                      .pop(ModelPickerResult(modelId: model.id))
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // 用等宽字体 + 可选中：用户要照着这个名字去网盘找文件
                        Flexible(
                          child: SelectableText(
                            model.fileName,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontFamily: 'Consolas',
                              fontFamilyFallback: const ['Menlo', 'monospace'],
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected
                                  ? scheme.primary
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                        // 复制按钮紧跟文件名；外层固定宽度占位，
                        // 悬停显隐时文件名与右侧各列都不会位移
                        SizedBox(
                          width: 26,
                          height: 22,
                          child: hovered ? _copyButton(model.fileName) : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tags.join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (model.cpuHint != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '纯 CPU 识别 1 小时视频约 ${model.cpuHint}',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant.withValues(alpha: .7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: Text(
                  model.sizeLabel,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                width: 62,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (imported) ...[
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: Colors.green,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        tooltip: '删除已导入的模型',
                        onPressed: () => _delete(model),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          '未导入',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: .6,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 说明那些"看着像模型、其实用不到"的文件，避免用户白下几个 GB。
  Widget _notNeededNote(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            'ggml-*-encoder.mlmodelc.zip',
            style: TextStyle(
              fontSize: 12.5,
              fontFamily: 'Consolas',
              fontFamilyFallback: const ['Menlo', 'monospace'],
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Apple 平台（macOS / iOS）的 Core ML 编码器加速包，Windows 与 Android '
            '都用不到，请勿下载。',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _footerNote(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '怎么选：不确定就用 Large v3 Turbo · q5（547 MB）——体积与精度兼顾；'
            '机器较弱就用 Small 系列；只在确定是英语视频时才选「英语专用」的 .en 版本。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '量化版（q5/q8）比同档位原版更小更快、精度略降；'
            '已导入的模型点一下即可切换使用，右侧垃圾桶图标可删除。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: scheme.onSurfaceVariant.withValues(alpha: .8),
            ),
          ),
        ],
      ),
    );
  }
}
