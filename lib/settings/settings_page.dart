import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../subtitle/device_capability.dart';
import '../subtitle/engine_pack.dart';
import '../subtitle/model_manager.dart';
import '../subtitle/model_picker_sheet.dart';
import '../subtitle/whisper_server.dart';
import '../utils/native_file_helper.dart';
import '../utils/platform_utils.dart';
import 'about_page.dart';
import 'app_settings.dart';
import 'update_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.embedded = false,
    this.onClose,
  });

  /// 是否作为右侧面板内嵌展示。
  final bool embedded;

  /// 内嵌模式下的关闭/返回回调。
  final VoidCallback? onClose;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _cacheBytes = 0;
  bool _loadingCache = true;
  bool _clearingCache = false;
  String _currentVersion = '26.8.23';

  // AI 字幕模型状态
  Set<String> _downloadedModels = {};
  final Map<String, double> _downloadProgress = {};

  /// 本机 GPU 能力。
  GpuCapability? _gpu;

  /// 已安装的识别引擎包（空表示只使用内置 CPU 插件）。
  List<EnginePack> _enginePacks = const [];

  /// 实际会被使用的引擎包（同类型多个时取最近导入的）。
  EnginePack? _preferredEngine;

  bool _checkingEngine = true;

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
    _loadLocalVersion();
    _refreshModels();
    detectGpuCapability().then((cap) {
      if (mounted) setState(() => _gpu = cap);
    });
    _refreshEnginePacks();
  }

  Future<void> _refreshEnginePacks() async {
    final packs = await EnginePackManager.instance.resolveAll();
    final preferred = await EnginePackManager.instance
        .resolvePreferred(allowGpu: !aiAsrForceCpu.value);
    if (!mounted) return;
    setState(() {
      _enginePacks = packs;
      _preferredEngine = preferred;
      _checkingEngine = false;
    });
  }

  Future<void> _refreshModels() async {
    final list = await ModelManager.instance.getDownloadedModels();
    if (mounted) {
      setState(() {
        _downloadedModels = list.toSet();
      });
    }
  }

  Future<void> _downloadModel(WhisperModelInfo model) async {
    if (_downloadProgress.containsKey(model.id)) return;
    setState(() => _downloadProgress[model.id] = 0.0);

    try {
      await ModelManager.instance.downloadModel(
        model.id,
        onProgress: (received, total) {
          if (mounted && total > 0) {
            setState(() {
              _downloadProgress[model.id] = received / total;
            });
          }
        },
      );
      await _refreshModels();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('模型 ${model.displayName} 下载完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _downloadProgress.remove(model.id));
      }
    }
  }

  Future<void> _deleteModel(WhisperModelInfo model) async {
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

    if (confirmed == true) {
      await ModelManager.instance.deleteModel(model.id);
      await _refreshModels();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除模型 ${model.displayName}')),
        );
      }
    }
  }

  Future<void> _loadLocalVersion() async {
    final v = await UpdateChecker.getLocalVersion();
    if (mounted) setState(() => _currentVersion = v);
  }

  Future<void> _refreshCacheSize() async {
    final bytes = await NativeFileHelper.getCacheSizeBytes();
    if (mounted) {
      setState(() {
        _cacheBytes = bytes;
        _loadingCache = false;
      });
    }
  }

  Future<void> _clearCache() async {
    if (_clearingCache) return;
    setState(() => _clearingCache = true);
    final cleared = await NativeFileHelper.clearCache();
    await _refreshCacheSize();
    if (!mounted) return;
    setState(() => _clearingCache = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            cleared > 0
                ? '已清理缓存，释放了 ${_formatBytes(cleared)} 存储空间。'
                : '缓存已全部清理完毕。',
          ),
        ),
      );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double val = bytes.toDouble();
    while (val >= 1024 && i < suffixes.length - 1) {
      val /= 1024;
      i++;
    }
    return '${val.toStringAsFixed(val < 10 && i > 0 ? 2 : 1)} ${suffixes[i]}';
  }

  /// 打开"建议反馈"问卷（腾讯文档）。用系统默认浏览器打开，
  /// 与关于页的"开源链接 / 联系作者"行为一致。
  Future<void> _openFeedback() async {
    const url = 'https://docs.qq.com/form/page/DRHJ3bmd6Q3RqaENT';
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开链接: $url')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开链接失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final body = ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        const _SectionTitle(title: '外观与主题'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                  const Text(
                    '应用外观',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '选择你偏好的界面色彩模式。',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  ListenableBuilder(
                    listenable: themeNotifier,
                    builder: (context, _) {
                      return SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<AppThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: AppThemeMode.system,
                              label: Text('自动'),
                              icon: Icon(Icons.brightness_auto_rounded),
                            ),
                            ButtonSegment(
                              value: AppThemeMode.light,
                              label: Text('浅色'),
                              icon: Icon(Icons.light_mode_rounded),
                            ),
                            ButtonSegment(
                              value: AppThemeMode.dark,
                              label: Text('深色'),
                              icon: Icon(Icons.dark_mode_rounded),
                            ),
                          ],
                          selected: {themeNotifier.mode},
                          onSelectionChanged: (selected) {
                            themeNotifier.setMode(selected.first);
                          },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          if (isDesktopPlatform) ...[
            const SizedBox(height: 18),
            const _SectionTitle(title: '播放'),
            Card(
              clipBehavior: Clip.antiAlias,
              child: ListenableBuilder(
                listenable: fitWindowToVideo,
                builder: (context, _) {
                  return SwitchListTile(
                    secondary: Icon(
                      Icons.aspect_ratio_rounded,
                      color: scheme.primary,
                    ),
                    title: const Text('窗口适应视频比例'),
                    subtitle: const Text(
                      '打开视频后把播放窗口调整成该视频的画面比例，尽量减少黑边。',
                    ),
                    value: fitWindowToVideo.value,
                    onChanged: (value) => setFitWindowToVideo(value),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 18),
          const _SectionTitle(title: 'AI 语音字幕 (实验性)'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListenableBuilder(
                  listenable: aiSubtitleEnabled,
                  builder: (context, _) {
                    return SwitchListTile(
                      secondary: Icon(
                        Icons.auto_awesome_rounded,
                        color: scheme.primary,
                      ),
                      title: const Text('启用 AI 字幕功能'),
                      subtitle: const Text('自动识别音频并生成字幕。'),
                      value: aiSubtitleEnabled.value,
                      onChanged: (value) => setAiSubtitleEnabled(value),
                    );
                  },
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      _cardSectionTitle('离线语音模型管理'),
                      const Spacer(),
                      Text(
                        '已检测到 ${_downloadedModels.length}/${availableModels.length} 个模型就绪',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                // 只列出已下载的模型：模型清单有二十多个，全列出来长得没法看，
                // 浏览 / 下载 / 切换统一走「浏览全部模型」面板。
                if (_downloadedModels.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      '尚未下载任何模型。点击下方「浏览全部模型」下载，或把已有的 ggml-*.bin 导入进来。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (final model in availableModels)
                    if (_downloadedModels.contains(model.id))
                      _buildModelItem(model, scheme),
                _sectionActionRow([
                  _SectionAction(
                    icon: Icons.list_alt_rounded,
                    label: '浏览全部模型',
                    onPressed: _browseModels,
                  ),
                  _SectionAction(
                    icon: Icons.file_download_outlined,
                    label: '导入模型',
                    onPressed: _importModel,
                  ),
                  _SectionAction(
                    icon: Icons.folder_open_rounded,
                    label: '打开模型目录',
                    onPressed: _openModelDirectory,
                  ),
                ]),
                ListenableBuilder(
                  listenable: modelDownloadSource,
                  builder: (context, _) => ListTile(
                    dense: true,
                    leading: Icon(Icons.cloud_download_outlined,
                        size: 20, color: scheme.primary),
                    title: const Text('模型下载源', style: TextStyle(fontSize: 13)),
                    subtitle: Text(
                      modelDownloadSource.value == 'mirror'
                          ? '国内镜像 hf-mirror（官方源不可达时选这个）'
                          : '自动：先试官方源，失败自动回退国内镜像',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: DropdownButton<String>(
                      value: modelDownloadSource.value,
                      focusColor: Colors.transparent,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 'auto', child: Text('自动', style: TextStyle(fontSize: 13))),
                        DropdownMenuItem(value: 'mirror', child: Text('仅镜像', style: TextStyle(fontSize: 13))),
                      ],
                      onChanged: (v) {
                        if (v != null) setModelDownloadSource(v);
                      },
                    ),
                  ),
                ),
                const Divider(height: 1),
                _buildAsrPerformanceRow(scheme),
                const SizedBox(height: 8),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const _SectionTitle(title: '存储与空间'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.cleaning_services_rounded,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('清理应用缓存'),
                            const SizedBox(height: 4),
                            Text(
                              _loadingCache
                                  ? '正在计算缓存大小…'
                                  : '当前临时缓存占用: ${_formatBytes(_cacheBytes)}',
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (isDesktopPlatform) ...[
                        OutlinedButton.icon(
                          icon: const Icon(Icons.folder_open_rounded, size: 16),
                          label: const Text('打开目录'),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: () => NativeFileHelper.openDirectory(
                            NativeFileHelper.desktopCacheDir(),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      _clearingCache
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.2),
                            )
                          : FilledButton.tonal(
                              onPressed: _cacheBytes > 0 ? _clearCache : null,
                              child: const Text('清理'),
                            ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const _SectionTitle(title: '关于'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.info_outline_rounded,
                    color: scheme.primary,
                  ),
                  title: const Text('关于影现播放器'),
                  subtitle: Text('v$_currentVersion'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AboutPage(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: Icon(
                    Icons.feedback_outlined,
                    color: scheme.primary,
                  ),
                  title: const Text('建议反馈'),
                  subtitle: const Text('通过问卷告诉我们你的想法'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: _openFeedback,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'PolyFlixPlayer · by hcllmsx\n一个"会识别自己人"的万能视频播放器',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: .7),
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      );

    if (widget.embedded) {
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: .5),
                ),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '返回播放列表',
                  onPressed: widget.onClose,
                ),
                const SizedBox(width: 4),
                const Text(
                  '应用设置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (widget.onClose != null)
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: '关闭',
                    onPressed: widget.onClose,
                  ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: body,
    );
  }

  /// 识别引擎与性能设置。
  ///
  /// 引擎采用"引擎包"模式：把 whisper.cpp 官方预编译包放进引擎目录即可获得
  /// GPU 加速（CUDA/Vulkan）；没放引擎包则自动回落到内置的纯 CPU 插件。
  Widget _buildAsrPerformanceRow(ColorScheme scheme) {
    final cores = Platform.numberOfProcessors;
    final options = <int>[0, 4, 8, 12, 16].where((v) => v == 0 || v < cores).toList();
    final hasGpuPack = _enginePacks.any((p) => p.supportsGpu);

    return ListenableBuilder(
      listenable: aiAsrForceCpu,
      builder: (context, _) {
        final gpuActive = hasGpuPack && !aiAsrForceCpu.value;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 识别引擎 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _cardSectionTitle('识别引擎'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _engineStatusText(),
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  ),
                  // 本机显卡（已过滤虚拟显示适配器）：
                  // 只有一张就直接跟在冒号后面，多张才用无序列表逐行展示
                  if (_gpu?.hasAdapters == true) ...[
                    const SizedBox(height: 6),
                    if (_gpu!.adapters.length == 1)
                      Text(
                        '本机显卡：${_gpu!.adapters.first}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    else ...[
                      Text(
                        '本机显卡：',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      for (final adapter in _gpu!.adapters)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, top: 2),
                          child: Text(
                            '· $adapter',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ],
                  if (_engineHintText() != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _engineHintText()!,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: .72),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _sectionActionRow([
              if (isDesktopPlatform)
                _SectionAction(
                  icon: Icons.unarchive_outlined,
                  label: '导入引擎',
                  onPressed: _importEngine,
                ),
              _SectionAction(
                icon: Icons.folder_open_rounded,
                label: '引擎目录',
                onPressed: () async {
                  await NativeFileHelper.openDirectory(
                    EnginePackManager.instance.engineRootDir(),
                  );
                  await _refreshEnginePacks();
                },
              ),
            ]),
            if (hasGpuPack)
              SwitchListTile(
                value: aiAsrForceCpu.value,
                onChanged: (v) => setAiAsrForceCpu(v),
                secondary: Icon(
                  Icons.developer_board_off_rounded,
                  color: scheme.primary,
                ),
                title: const Text('强制使用 CPU 识别'),
                subtitle: const Text('显卡驱动异常或识别报错时打开，无需删除引擎包。'),
              ),
            const Divider(height: 1, indent: 16, endIndent: 16),

            // ---------- 识别线程数 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _cardSectionTitle('识别线程数'),
            ),
            ListenableBuilder(
              listenable: aiAsrThreadCount,
              builder: (context, _) {
                final current = options.contains(aiAsrThreadCount.value)
                    ? aiAsrThreadCount.value
                    : 0;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        gpuActive
                            ? '当前使用 GPU 引擎包加速，线程数不生效。'
                            : '仅 CPU 识别时生效：本机 $cores 逻辑核心，'
                                '「自动」取核心数一半并限制在 4~12。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          DropdownButton<int>(
                            value: current,
                            underline: const SizedBox.shrink(),
                            // Material 3 下 DropdownButton 聚焦时会用 focusColor 填充底色，
                            // 选完一项后那块灰底会一直留着，这里显式关掉。
                            focusColor: Colors.transparent,
                            // GPU 加速时线程数不起作用，置灰不可选
                            onChanged: gpuActive
                                ? null
                                : (v) {
                                    if (v != null) setAiAsrThreadCount(v);
                                  },
                            items: [
                              for (final v in options)
                                DropdownMenuItem<int>(
                                  value: v,
                                  child: Text(
                                    v == 0 ? '自动' : '$v 线程',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: gpuActive
                                          ? scheme.onSurface
                                              .withValues(alpha: .38)
                                          : null,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
          ],
        );
      },
    );
  }

  /// 卡片内小节标题：与「离线语音模型管理」保持同一套样式。
  Widget _cardSectionTitle(String title) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: scheme.primary,
      ),
    );
  }

  /// 卡片内小节的操作按钮行：单独一行、右对齐。
  ///
  /// 用 Wrap 而不是 Row：设置页在双栏模式下只有 420px 宽，
  /// 按钮多了（浏览/导入/目录）排不下时会自动换行，不会溢出报错。
  Widget _sectionActionRow(List<_SectionAction> actions) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 4,
        runSpacing: 2,
        children: [
          for (final action in actions)
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: action.onPressed,
              icon: Icon(action.icon, size: 16),
              label: Text(action.label),
            ),
        ],
      ),
    );
  }

  /// 浏览 / 下载 / 切换全部模型。
  Future<void> _browseModels() async {
    final result = await ModelPickerSheet.show(context);
    await _refreshModels();
    if (result == null || !mounted) return;
    // 在设置页选中的模型同样记忆下来，AI 面板下次打开就用它
    await setAiAsrModelId(result.modelId);
    if (!mounted) return;
    final label =
        ModelManager.instance.infoOf(result.modelId)?.displayName ?? result.modelId;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已选用：$label')));
  }

  /// 导入本地已下载好的 ggml 模型文件。
  Future<void> _importModel() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择要导入的模型文件（ggml-tiny / base / small.bin）',
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );
    final path = picked?.path;
    if (path == null || !mounted) return;

    final result = await _runWithProgress<ModelImportResult>(
      '导入模型',
      (report) => ModelManager.instance.importModelFile(
        path,
        onProgress: (copied, total) => report(
          total > 0
              ? '正在写入模型目录… ${_formatBytes(copied)} / ${_formatBytes(total)}'
              : '正在写入模型目录…',
        ),
      ),
    );

    if (!mounted) return;
    await _refreshModels();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }

  /// 导入本地已下载好的引擎包 zip。
  Future<void> _importEngine() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择引擎包（whisper.cpp 官方发布的 zip）',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = picked?.path;
    if (path == null || !mounted) return;

    // 先停掉正在运行的识别服务：否则替换旧引擎包时文件被占用，删不掉
    await WhisperServerSession.shutdownAny();

    final result = await _runWithProgress<EngineImportResult>(
      '导入引擎包',
      (report) => EnginePackManager.instance.importFromZip(
        path,
        onProgress: (written) =>
            report('正在解压… 已写入 ${_formatBytes(written)}\n（1GB 左右的包通常需要 1~2 分钟）'),
        onDuplicateKind: _askDuplicateEngine,
      ),
    );

    if (!mounted) return;
    await _refreshEnginePacks();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }

  /// 同类型引擎包已存在时的询问：替换 / 保留两个 / 取消。
  Future<EngineDuplicateAction> _askDuplicateEngine(
    EngineKind kind,
    EnginePack existing,
  ) async {
    final kindLabel = switch (kind) {
      EngineKind.cuda => 'CUDA',
      EngineKind.vulkan => 'Vulkan',
      EngineKind.cpu => 'CPU',
    };
    final choice = await showDialog<EngineDuplicateAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已存在同类型引擎包'),
        content: Text(
          '引擎目录中已经有 $kindLabel 引擎包（${existing.dirName}）。\n\n'
          '· 替换：删除旧的，改用这次导入的包（推荐）\n'
          '· 保留两个：新包放到 ${existing.dirName}-2，'
          '会多占一份空间，识别时默认使用最近导入的那个',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(EngineDuplicateAction.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(EngineDuplicateAction.keepBoth),
            child: const Text('保留两个'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(EngineDuplicateAction.replace),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    return choice ?? EngineDuplicateAction.cancel;
  }

  /// 执行耗时任务并显示不可取消的进度弹窗。
  ///
  /// 不可取消是有意的：导入到一半中断会在模型/引擎目录里留下半截文件，
  /// 反而更难处理。
  Future<T> _runWithProgress<T>(
    String title,
    Future<T> Function(void Function(String detail) report) task,
  ) async {
    final detail = ValueNotifier<String>('准备中…');
    final navigator = Navigator.of(context, rootNavigator: true);

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<String>(
            valueListenable: detail,
            builder: (_, text, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 14),
                Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
              ],
            ),
          ),
        ),
      ),
    ));

    try {
      return await task((value) => detail.value = value);
    } finally {
      if (navigator.canPop()) navigator.pop();
      // 弹窗关闭动画结束后再释放，避免正在监听它的组件访问已释放对象
      Future.delayed(const Duration(milliseconds: 300), detail.dispose);
    }
  }

  /// 引擎状态主文案：展示真正会被使用的那个包（含目录名，便于区分同类型多包）。
  String _engineStatusText() {
    if (_checkingEngine) return '正在检测…';

    final preferred = _preferredEngine;
    if (preferred == null) {
      return _enginePacks.isEmpty
          ? '未安装引擎包：使用内置 CPU 引擎'
          : '已安装 ${_enginePacks.length} 个引擎包，但当前设置下不使用（见下方开关）';
    }

    final gpuActive = preferred.supportsGpu && !aiAsrForceCpu.value;
    final extra = _enginePacks.length - 1;
    final extraText = extra > 0 ? '，另有 $extra 个备用包' : '';
    return '当前使用：${preferred.qualifiedName}'
        '（${gpuActive ? 'GPU 加速' : 'CPU 识别'}）$extraText';
  }

  /// 引擎状态附加提示（没有则返回 null）。
  String? _engineHintText() {
    if (_checkingEngine) return null;
    if (_enginePacks.isEmpty) {
      return '把 whisper.cpp 官方预编译包解压到引擎目录即可启用 GPU 加速。';
    }
    if (_enginePacks.length > 1) {
      return '同类型有多个引擎包时，默认使用最近导入的那个；不需要的包可直接在引擎目录里删除。';
    }
    return null;
  }

  Future<void> _openModelDirectory() async {
    final path = await NativeFileHelper.getWhisperModelDirPath();
    await NativeFileHelper.openDirectory(Directory(path));
  }

  Widget _buildModelItem(WhisperModelInfo model, ColorScheme scheme) {
    final isDownloaded = _downloadedModels.contains(model.id);
    final progress = _downloadProgress[model.id];
    final isDownloading = progress != null;

    return ListTile(
      leading: Icon(
        isDownloaded ? Icons.check_circle_outline_rounded : Icons.download_for_offline_outlined,
        color: isDownloaded ? Colors.green : scheme.onSurfaceVariant,
      ),
      title: Text(
        model.displayName,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: isDownloading
          ? Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: progress > 0 ? progress : null),
                  const SizedBox(height: 2),
                  Text(
                    '下载中 ${(progress * 100).toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 11, color: scheme.primary),
                  ),
                ],
              ),
            )
          : Text(
              isDownloaded ? '已下载并就绪' : '约 ${_formatBytes(model.sizeBytes)}',
              style: TextStyle(
                fontSize: 12,
                color: isDownloaded ? Colors.green : scheme.onSurfaceVariant,
              ),
            ),
      trailing: isDownloading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : isDownloaded
              ? IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  tooltip: '删除模型',
                  onPressed: () => _deleteModel(model),
                )
              : FilledButton.tonal(
                  onPressed: () => _downloadModel(model),
                  child: const Text('下载'),
                ),
    );
  }
}

/// 卡片内小节操作按钮的描述。
class _SectionAction {
  const _SectionAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onPressed;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
