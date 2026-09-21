/// 全部识别引擎对照表（介绍表格 + 当前使用状态）。
///
/// 引擎包 = whisper.cpp 官方发布的预编译二进制（zip）。应用**不内置下载**，
/// 用户按表格选好包 → 去网盘下载同名 zip → 用设置页的「导入引擎」导入。
///
/// 为什么需要引擎包：内置插件是纯 CPU 构建，装上 CUDA / OpenCL 等引擎包后
/// 才能用 GPU 加速（详见 README 的「AI 语音识别：性能与硬件」）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/app_settings.dart';
import '../utils/app_toast.dart';
import '../utils/platform_utils.dart';
import 'download_links.dart';
import 'engine_pack.dart';
import 'netdisk_links_card.dart';

/// 引擎包分组（键值用于把条目归到对应的小标题下）。
enum EngineGroup {
  winX64('Windows 64 位（x64，绝大多数用户）'),
  winArm64('Windows on ARM64（骁龙 X 等）'),
  winX86('Windows 32 位（很老的机器）'),
  other('其它平台（本播放器用不到，请勿下载）');

  const EngineGroup(this.title);

  final String title;
}

/// 一个引擎包条目的说明信息。
class EngineCatalogEntry {
  const EngineCatalogEntry({
    required this.fileName,
    required this.sizeLabel,
    required this.summary,
    required this.group,
    this.recommended = false,
    this.unsupported = false,
  });

  /// whisper.cpp 官方发布包的原始文件名。
  final String fileName;

  final String sizeLabel;

  /// 说明：适合谁、有什么用。
  final String summary;

  /// 所属平台分组。
  final EngineGroup group;

  /// 是否推荐（界面上加一个「推荐」标记）。
  final bool recommended;

  /// 本播放器用不到的包（其它平台），弱化显示。
  final bool unsupported;
}

/// 引擎包清单（对应 whisper.cpp 官方 b5130 版本的发布产物）。
const List<EngineCatalogEntry> engineCatalog = [
  EngineCatalogEntry(
    group: EngineGroup.winX64,
    fileName: 'whisper-bin-x64.zip',
    sizeLabel: '8.2 MB',
    summary:
        'Windows 64 位 · 纯 CPU。最通用，任何机器都能跑；'
        '效果与不装引擎包时基本一致，装上主要是为了让 CPU 多线程路径更完整。',
  ),
  EngineCatalogEntry(
    group: EngineGroup.winX64,
    fileName: 'whisper-blas-bin-x64.zip',
    sizeLabel: '20.4 MB',
    summary:
        'Windows 64 位 · CPU + OpenBLAS。用 BLAS 加速矩阵运算，'
        '纯 CPU 识别通常比上面的纯 CPU 包更快，核显机器也适用。',
    recommended: true,
  ),
  EngineCatalogEntry(
    group: EngineGroup.winX64,
    fileName: 'whisper-cublas-12.4.0-bin-x64.zip',
    sizeLabel: '643.3 MB',
    summary:
        'Windows 64 位 · NVIDIA 显卡（CUDA 12.4）。'
        'N 卡 + 较新驱动选这个，GPU 加速效果最好（如 RTX 40 系）。',
    recommended: true,
  ),
  EngineCatalogEntry(
    group: EngineGroup.winX64,
    fileName: 'whisper-cublas-11.8.0-bin-x64.zip',
    sizeLabel: '260.3 MB',
    summary:
        'Windows 64 位 · NVIDIA 显卡（CUDA 11.8）。'
        '显卡驱动较旧（或系统较老）时选这个。',
  ),
  EngineCatalogEntry(
    group: EngineGroup.winArm64,
    fileName: 'whisper-bin-win-cpu-arm64.zip',
    sizeLabel: '4.2 MB',
    summary: 'Windows on ARM64 · 纯 CPU。骁龙 X 等 ARM 版 Windows 用。',
  ),
  EngineCatalogEntry(
    group: EngineGroup.winArm64,
    fileName: 'whisper-bin-win-opencl-adreno-arm64.zip',
    sizeLabel: '4.7 MB',
    summary:
        'Windows on ARM64 · 高通 Adreno 核显走 OpenCL 加速。'
        '骁龙 X 笔记本想用核显加速时选这个。',
  ),
  EngineCatalogEntry(
    group: EngineGroup.winArm64,
    fileName: 'whisper-bin-win-cuda-13.4-arm64.zip',
    sizeLabel: '275.6 MB',
    summary:
        'Windows on ARM64 · NVIDIA 显卡（CUDA 13.4）。较冷门的组合，'
        '只有 ARM 版 Windows 且外接 N 卡时才用得到。',
  ),
  EngineCatalogEntry(
    group: EngineGroup.winX86,
    fileName: 'whisper-bin-Win32.zip',
    sizeLabel: '5.1 MB',
    summary: 'Windows 32 位 · 纯 CPU。仅 32 位系统需要（很老的机器）。',
  ),
  EngineCatalogEntry(
    group: EngineGroup.winX86,
    fileName: 'whisper-blas-bin-Win32.zip',
    sizeLabel: '11.8 MB',
    summary: 'Windows 32 位 · CPU + OpenBLAS。32 位系统下的加速版。',
  ),
  EngineCatalogEntry(
    group: EngineGroup.other,
    fileName: 'whisper-bin-ubuntu-x64.tar.gz',
    sizeLabel: '9.3 MB',
    summary: 'Linux x64 · 纯 CPU。本播放器不支持 Linux。',
    unsupported: true,
  ),
  EngineCatalogEntry(
    group: EngineGroup.other,
    fileName: 'whisper-bin-ubuntu-arm64.tar.gz',
    sizeLabel: '4.4 MB',
    summary: 'Linux ARM64 · 纯 CPU。本播放器不支持 Linux。',
    unsupported: true,
  ),
  EngineCatalogEntry(
    group: EngineGroup.other,
    fileName: 'whisper-b5130-xcframework.zip',
    sizeLabel: '54.5 MB',
    summary: 'Apple（iOS / macOS）XCFramework。本播放器不支持 Apple 平台。',
    unsupported: true,
  ),
];

class EngineCatalogSheet extends StatefulWidget {
  const EngineCatalogSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const EngineCatalogSheet(),
    );
  }

  @override
  State<EngineCatalogSheet> createState() => _EngineCatalogSheetState();
}

class _EngineCatalogSheetState extends State<EngineCatalogSheet> {
  List<EnginePack> _installed = const [];
  EnginePack? _preferred;
  bool _loading = true;

  /// 鼠标当前悬停的引擎行；只有悬停的那一行才显示"复制文件名"按钮。
  String? _hoveredFileName;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final packs = await EnginePackManager.instance.resolveAll();
    final preferred = await EnginePackManager.instance.resolvePreferred(
      allowGpu: !aiAsrForceCpu.value,
    );
    if (!mounted) return;
    setState(() {
      _installed = packs;
      _preferred = preferred;
      _loading = false;
    });
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
                Icon(Icons.developer_board_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '全部识别引擎',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
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
                _statusCard(scheme),
                // 网盘入口：夸克 / 百度各一份，可复制也可直接打开
                const NetdiskLinksCard(
                  title: '引擎包网盘（whisper.cpp 官方 zip）',
                  links: kEngineNetdiskLinks,
                ),
                _columnHeader(scheme),
                for (final group in EngineGroup.values) ...[
                  _groupHeader(scheme, group.title),
                  for (final e in engineCatalog.where((e) => e.group == group))
                    _row(scheme, e),
                ],
                _footerNote(scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 当前引擎状态：装了就用引擎包，没装就回落内置 CPU 插件。
  Widget _statusCard(ColorScheme scheme) {
    String text;
    if (_loading) {
      text = '正在检查已安装的引擎包…';
    } else if (_preferred == null) {
      text = _installed.isEmpty
          ? '当前：内置 CPU 插件（未安装引擎包）—— 识别可以正常用，只是没有 GPU 加速。'
          : '已安装 ${_installed.length} 个引擎包，但当前设置下不使用（可在设置页关闭「强制使用 CPU 识别」）。';
    } else {
      final gpu = _preferred!.supportsGpu && !aiAsrForceCpu.value;
      final extra = _installed.length - 1;
      text =
          '当前使用：${_preferred!.qualifiedName}（${gpu ? 'GPU 加速' : 'CPU 识别'}）'
          '${extra > 0 ? '，另有 $extra 个备用包' : ''}';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
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
          Text(
            '体积',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant.withValues(alpha: .8),
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

  Widget _row(ColorScheme scheme, EngineCatalogEntry entry) {
    final faded = entry.unsupported;
    final alpha = faded ? .55 : 1.0;
    // 桌面端悬停才显示复制按钮；触屏没有 hover，直接常显
    final hovered = _hoveredFileName == entry.fileName || !isDesktopPlatform;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredFileName = entry.fileName),
      onExit: (_) => setState(() {
        if (_hoveredFileName == entry.fileName) _hoveredFileName = null;
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: SelectableText(
                          entry.fileName,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontFamily: 'Consolas',
                            fontFamilyFallback: const ['Menlo', 'monospace'],
                            fontWeight: entry.recommended
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: scheme.onSurface.withValues(alpha: alpha),
                          ),
                        ),
                      ),
                      // 复制按钮紧跟文件名；固定宽度占位，
                      // 悬停显隐时"推荐"标记与体积列都不会位移
                      SizedBox(
                        width: 26,
                        height: 22,
                        child: hovered ? _copyButton(entry.fileName) : null,
                      ),
                      if (entry.recommended) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: .14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '推荐',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.summary,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: scheme.onSurfaceVariant.withValues(alpha: alpha),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              entry.sizeLabel,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant.withValues(alpha: alpha),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footerNote(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Text(
        '提示：引擎包与模型是两回事——模型决定"准不准"，引擎包只决定"快不快"。'
        '不装引擎包也能正常识别（内置 CPU 插件）。'
        '导入 CUDA 引擎包请确认显卡驱动较新，识别报错时可在设置页打开「强制使用 CPU 识别」排查。',
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: scheme.onSurfaceVariant.withValues(alpha: .85),
        ),
      ),
    );
  }
}
