/// 模型选择 / 下载面板。
///
/// 模型多达二十几个，塞进设置页会非常长，因此统一收敛到这一个底部弹窗：
///  - 设置页与 AI 字幕面板都通过它来「浏览 / 下载 / 切换」模型；
///  - 按「多语言」「英语专用」分组，组内按体积升序；
///  - 已下载的模型可直接点选，未下载的可直接下载（带进度）。
library;

import 'package:flutter/material.dart';

import 'model_manager.dart';

/// 模型选择结果。
class ModelPickerResult {
  const ModelPickerResult({required this.modelId, this.downloaded = false});

  final String modelId;

  /// 本次是否是新下载的（调用方据此刷新列表）。
  final bool downloaded;
}

class ModelPickerSheet extends StatefulWidget {
  const ModelPickerSheet({
    super.key,
    this.selectedId,
    this.allowDownload = true,
  });

  /// 当前选中的模型 ID。
  final String? selectedId;

  /// 是否允许在面板内下载（设置页与 AI 面板都允许，保留参数便于以后收紧）。
  final bool allowDownload;

  /// 弹出面板；返回用户选择（或取消时返回 null）。
  static Future<ModelPickerResult?> show(
    BuildContext context, {
    String? selectedId,
    bool allowDownload = true,
  }) {
    return showModalBottomSheet<ModelPickerResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ModelPickerSheet(
        selectedId: selectedId,
        allowDownload: allowDownload,
      ),
    );
  }

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  Set<String> _downloaded = {};
  final Map<String, double> _progress = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await ModelManager.instance.getDownloadedModels();
    if (!mounted) return;
    setState(() {
      _downloaded = list.toSet();
      _loading = false;
    });
  }

  Future<void> _download(WhisperModelInfo model) async {
    if (_progress.containsKey(model.id)) return;
    setState(() => _progress[model.id] = 0);

    try {
      await ModelManager.instance.downloadModel(
        model.id,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress[model.id] = received / total);
        },
      );
      await _refresh();
      if (!mounted) return;
      final source = ModelManager.lastDownloadSourceLabel;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            '${model.displayName} 下载完成'
            '${source != null ? '（来源：$source）' : ''}，点击即可使用',
          ),
        ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _progress.remove(model.id));
    }
  }

  void _onTap(WhisperModelInfo model) {
    if (mounted) setState(() {}); // 保证进度条状态与点击一致
    if (_downloaded.contains(model.id)) {
      Navigator.of(context).pop(ModelPickerResult(modelId: model.id));
      return;
    }
    if (widget.allowDownload) _download(model);
  }

  Future<void> _delete(WhisperModelInfo model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定要删除 ${model.displayName} 吗？\n删除后如需使用需重新下载。'),
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
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
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
                        '选择语音识别模型',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '已下载 ${_downloaded.length} / ${availableModels.length} 个。'
                        '「英语专用」只能识别英语；量化版体积小、速度快、精度略降。',
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
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    shrinkWrap: true,
                    children: [
                      _groupHeader(context, '多语言模型（支持 99 种语言）'),
                      for (final m in multilingualModels) _row(context, m),
                      _groupHeader(context, '英语专用模型（仅英语，速度更快）'),
                      for (final m in englishOnlyModels) _row(context, m),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: Text(
                          '提示：Large v3 Turbo 精度接近 large 但快得多，'
                          '配合 GPU 引擎包性价比最高；磁盘紧张时可选 q5 / q8 量化版。',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: scheme.onSurfaceVariant.withValues(alpha: .8),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(BuildContext context, String title) {
    final scheme = Theme.of(context).colorScheme;
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

  Widget _row(BuildContext context, WhisperModelInfo model) {
    final scheme = Theme.of(context).colorScheme;
    final isDownloaded = _downloaded.contains(model.id);
    final progress = _progress[model.id];
    final isSelected = widget.selectedId == model.id;

    final tags = <String>[
      model.sizeLabel,
      if (model.isEnglishOnly) '英语专用',
      if (model.isQuantized) '量化',
    ];

    return ListTile(
      dense: true,
      onTap: progress != null ? null : () => _onTap(model),
      leading: Icon(
        isSelected
            ? Icons.radio_button_checked_rounded
            : (isDownloaded
                ? Icons.check_circle_outline_rounded
                : Icons.download_for_offline_outlined),
        color: isSelected
            ? scheme.primary
            : (isDownloaded ? Colors.green : scheme.onSurfaceVariant),
      ),
      title: Text(
        model.displayName,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        progress != null
            ? '下载中 ${(progress * 100).toStringAsFixed(1)}%'
            : tags.join(' · '),
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: progress != null
          ? SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                value: progress > 0 ? progress : null,
              ),
            )
          : (isDownloaded
              ? IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  tooltip: '删除模型',
                  onPressed: () => _delete(model),
                )
              : (widget.allowDownload
                  ? FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => _download(model),
                      child: const Text('下载'),
                    )
                  : null)),
    );
  }
}
