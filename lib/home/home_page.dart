/// 首页：导入视频、识别 PFLX 双视频文件，并提供播放与导出入口。
library;

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../main.dart';
import '../pflx/pflx.dart';
import '../player/player_page.dart';
import '../settings/app_settings.dart';
import '../settings/app_store.dart';
import '../settings/settings_page.dart';
import '../settings/update_service.dart';
import '../subtitle/ai_task_manager.dart';
import '../utils/native_file_helper.dart';
import '../utils/platform_utils.dart';
import 'ai_task_panel.dart';

const Set<String> _kSupportedVideoExtensions = {
  'mp4',
  'mkv',
  'mov',
  'avi',
  'flv',
  'wmv',
  'webm',
  'ts',
  'm4v',
  '3gp',
  'rmvb',
  'f4v',
  'mpg',
  'mpeg',
  'vob',
  'ogv',
  'm2ts',
  'mts',
  'divx',
  'asf',
  'rm',
  'dat',
  'h264',
  'h265',
  'hevc',
};

bool _isVideoPath(String path) {
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex >= path.length - 1) return false;
  final ext = path.substring(dotIndex + 1).toLowerCase();
  return _kSupportedVideoExtensions.contains(ext);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<_LibraryItem> _items = [];
  bool _scanning = false;

  /// 是否有文件正被拖到窗口上方（用于显示投放提示层）。
  bool _dropActive = false;

  /// 是否接收拖放事件。进入播放页前必须关掉：DropTarget 被其他页面覆盖后
  /// 仍会继续收到拖放事件，会和播放页自己的拖放目标互相抢占。
  bool _dropEnabled = true;

  /// 宽屏双栏模式下，右侧面板是否展示内嵌设置页。
  bool _showSettingsInPanel = false;

  /// 首页选项卡：0 = 播放列表，1 = 任务列表。
  ///
  /// 任务列表只在「设置 → 启用 AI 字幕功能」打开时出现。
  int _homeTab = 0;

  @override
  void initState() {
    super.initState();
    try {
      MediaKit.ensureInitialized();
    } catch (_) {}
    _loadSavedLibrary();
    // "任务列表"选项卡由 AI 字幕总开关控制，设置里改动后首页要立刻同步
    aiSubtitleEnabled.addListener(_onAiSubtitleSettingChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _silentCheckUpdate());
  }

  void _onAiSubtitleSettingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    aiSubtitleEnabled.removeListener(_onAiSubtitleSettingChanged);
    super.dispose();
  }

  /// 实际生效的选项卡：AI 字幕总开关关闭时强制回到播放列表。
  int get _activeHomeTab => aiSubtitleEnabled.value ? _homeTab : 0;

  Future<void> _silentCheckUpdate() async {
    try {
      final current = await UpdateChecker.getLocalVersion();
      final remote = await UpdateChecker.fetchRemoteVersion();
      if (!mounted || remote == null) return;
      if (UpdateChecker.isNewerVersion(remote, current)) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              ForceUpdateDialog(remoteVersion: remote, currentVersion: current),
        );
      }
    } catch (_) {}
  }

  Future<void> _loadSavedLibrary() async {
    final items = await _LibraryStorage.load();
    if (!mounted) return;
    setState(() {
      _items.clear();
      _items.addAll(items);
    });
  }

  /// 选择视频文件。
  ///
  /// [autoOpen] 为 true 时（空列表页中央的"选择视频文件"入口），文件加入媒体库后
  /// 立即打开第一个，省掉"添加完再点一次播放"的多余步骤。
  Future<void> _pickFiles({bool autoOpen = false}) async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final files = await NativeFileHelper.pickVideos();
      if (files.isEmpty) return;

      int skippedNonVideo = 0;
      final selections = <_LibraryItem>[];
      for (final file in files) {
        if (!_isVideoPath(file.path)) {
          skippedNonVideo++;
          continue;
        }
        final info = scan(file.path);
        final isPflx =
            info != null &&
            info['payload_offset'] + info['payload_len'] <= info['file_size'];
        selections.add(
          _LibraryItem(
            path: file.path,
            name: file.name,
            isPflx: isPflx,
            info: isPflx ? info : null,
          ),
        );
      }

      if (!mounted) return;

      if (selections.isEmpty && skippedNonVideo > 0) {
        _showTip('仅支持导入视频文件（如 MP4、MKV、MOV 等格式）。');
        return;
      }
      if (selections.isEmpty) return;

      final existingPaths = _items.map((item) => item.path).toSet();
      final freshItems = selections
          .where((item) => existingPaths.add(item.path))
          .toList(growable: false);
      if (freshItems.isEmpty) {
        // 已在媒体库中：自动打开模式下仍然直接播放它，不重复添加。
        if (autoOpen) {
          _open(selections.first);
        } else {
          _showTip('所选视频已在你的媒体库中。');
        }
        return;
      }
      setState(() => _items.insertAll(0, freshItems));
      await _LibraryStorage.save(_items);

      if (skippedNonVideo > 0) {
        _showTip('已跳过非视频文件，添加了 ${freshItems.length} 个视频。');
      } else {
        _showTip('已添加 ${freshItems.length} 个视频。');
      }
      if (autoOpen) _open(selections.first);
    } catch (_) {
      if (mounted) _showTip('无法读取所选文件，请检查文件访问权限后重试。');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 拖放打开：拖进窗口的文件立即播放。
  void _openDroppedFile(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    if (!_isVideoPath(path)) {
      _showTip('仅支持视频文件：$name');
      return;
    }
    _playPath(path, name);
  }

  /// 识别是否为 PFLX 产物后直接进入播放页（不写入媒体库）。
  void _playPath(String path, String name) {
    if (!mounted) return;
    final info = scan(path);
    final isPflx =
        info != null &&
        info['payload_offset'] + info['payload_len'] <= info['file_size'];
    _open(
      _LibraryItem(
        path: path,
        name: name,
        isPflx: isPflx,
        info: isPflx ? info : null,
      ),
    );
  }

  Future<void> _export(_LibraryItem item) async {
    if (!item.isPflx || item.info == null) return;

    if (Platform.isAndroid) {
      final hasPermission = await _StoragePermissionHelper.hasPermission();
      if (!hasPermission && mounted) {
        final shouldRequest = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: Icon(
              Icons.folder_special_outlined,
              color: Theme.of(ctx).colorScheme.primary,
            ),
            title: const Text('开启存储管理权限'),
            content: const Text(
              '导出隐藏视频到自定义文件夹需要"所有文件访问权限"，请在接下来的系统设置中允许本应用管理所有文件。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('前往开启'),
              ),
            ],
          ),
        );
        if (shouldRequest == true) {
          await _StoragePermissionHelper.requestPermission();
        }
        return;
      }
    }

    if (!mounted) return;
    final defaultName = item.hiddenName ?? 'hidden_video';
    final confirmedName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _ExportNameDialog(defaultName: defaultName),
    );
    if (confirmedName == null || !mounted) return;

    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
    if (directory == null || !mounted) return;

    final separator = Platform.pathSeparator;
    final outputPath = '$directory$separator$confirmedName';
    final result = await _showExportProgressDialog(
      sourcePath: item.path,
      outputPath: outputPath,
      info: item.info!,
    );

    if (!mounted) return;
    if (result.success) {
      _showTip('导出完成：$confirmedName');
    } else {
      _showTip('导出失败：${result.error ?? '未知错误'}');
    }
  }

  Future<_ExportResult> _showExportProgressDialog({
    required String sourcePath,
    required String outputPath,
    required PflxInfo info,
  }) async {
    final result = await showDialog<_ExportResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ExportProgressDialog(
        sourcePath: sourcePath,
        outputPath: outputPath,
        info: info,
        onComplete: (result) => Navigator.of(context).pop(result),
      ),
    );
    return result ?? _ExportResult.failure('导出被中断');
  }

  Future<void> _open(_LibraryItem item) async {
    // 播放页也有拖放目标，进入前先关掉首页的，避免两者同时接收拖放事件。
    setState(() => _dropEnabled = false);

    // 桌面端：记下当前窗口尺寸。播放页可能按视频比例把窗口改小，回来时要还原。
    // 还原刻意放在这里而不是播放页的退出流程里——改窗口尺寸会让引擎重新布局
    // 重绘，若发生在 media_kit 渲染纹理释放之后会直接崩掉进程；等回到首页时
    // 播放器已完全销毁，就没有这个问题了。
    Size? sizeBefore;
    if (isDesktopPlatform) {
      try {
        sizeBefore = await windowManager.getSize();
      } catch (_) {
        // 取不到就跳过还原，不影响播放。
      }
    }
    if (!mounted) return;
    windowFitAppliedInPlayer = false;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          sourcePath: item.path,
          info: item.info,
          isPflx: item.isPflx,
        ),
      ),
    );

    if (!mounted) return;
    setState(() => _dropEnabled = true);

    // 只有播放页确实按视频比例调过窗口才还原，否则会覆盖用户自己调整的尺寸。
    if (sizeBefore != null && windowFitAppliedInPlayer) {
      windowFitAppliedInPlayer = false;
      // 等播放器渲染层完全从树中移除后再改窗口尺寸，
      // 否则尺寸变化触发的重新合成可能访问已释放的 mpv 纹理。
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      try {
        await windowManager.setSize(sizeBefore);
      } catch (_) {
        // 还原失败不影响使用。
      }
    }
  }

  void _removeItem(_LibraryItem item) {
    final index = _items.indexWhere((e) => e.path == item.path);
    if (index < 0) return;
    setState(() => _items.removeAt(index));
    _LibraryStorage.save(_items);

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        behavior: SnackBarBehavior.floating,
        content: Row(
          children: [
            Expanded(
              child: Text(
                '已从列表中移除 ${item.name}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _UndoCountdownButton(
              duration: const Duration(seconds: 8),
              onPressed: () {
                messenger.hideCurrentSnackBar();
                setState(() => _items.insert(index, item));
                _LibraryStorage.save(_items);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showItemOptions(_LibraryItem item) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  item.name,
                  // 文件名通常很长，这里完整展示，一行放不下就自动换行
                  style: Theme.of(ctx).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.play_circle_outline_rounded),
                title: const Text('播放视频'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _open(item);
                },
              ),
              if (item.isPflx)
                ListTile(
                  leading: Icon(
                    Icons.file_download_outlined,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                  title: Text(
                    '导出隐藏视频',
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: item.hiddenName != null
                      ? Text(item.hiddenName!)
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _export(item);
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(ctx).colorScheme.error,
                ),
                title: Text(
                  '从列表中移除',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _removeItem(item);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTip(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bodyContent = LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 840;
        if (isWide) {
          return _buildWideLayout(context);
        }
        return _buildNarrowLayout(context);
      },
    );

    final scaffold = Scaffold(body: _AmbientBackground(child: bodyContent));

    if (!isDesktopPlatform) return scaffold;

    // 桌面端支持把视频文件直接拖进窗口播放。
    return DropTarget(
      enable: _dropEnabled,
      onDragEntered: (_) => setState(() => _dropActive = true),
      onDragExited: (_) => setState(() => _dropActive = false),
      onDragDone: (details) {
        setState(() => _dropActive = false);
        final paths = details.files
            .map((f) => f.path)
            .where((p) => p.isNotEmpty)
            .toList();
        if (paths.isNotEmpty) _openDroppedFile(paths.first);
      },
      child: Stack(
        children: [scaffold, if (_dropActive) const _DropHintOverlay()],
      ),
    );
  }

  /// 窄屏（手机竖屏或小窗口）单栏布局。
  Widget _buildNarrowLayout(BuildContext context) {
    return Stack(
      children: [
        CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              titleSpacing: 24,
              title: const _BrandLockup(compact: true),
              actions: [
                const ThemeToggleButton(),
                IconButton(
                  tooltip: '设置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsPage()),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: _HomeTabBar(
                  current: _activeHomeTab,
                  playlistCount: _items.length,
                  onChanged: (value) => setState(() => _homeTab = value),
                ),
              ),
            ),
            if (_activeHomeTab == 1)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 120),
                  child: AiTaskPanel(onOpenVideo: _playPath, shrinkWrap: true),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
                sliver: SliverList.list(
                  children: [
                    if (_scanning) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 16),
                    ],
                    if (_items.isEmpty)
                      _EmptyLibrary(
                        onPickFiles: () => _pickFiles(autoOpen: true),
                      )
                    else ...[
                      _SectionHeading(
                        title: '最近添加',
                        trailing: '${_items.length} 个视频',
                      ),
                      const SizedBox(height: 12),
                      ..._items.map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _VideoLibraryCard(
                            item: item,
                            onOpen: () => _open(item),
                            onExport: () => _export(item),
                            onDelete: () => _removeItem(item),
                            onLongPress: () => _showItemOptions(item),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
        Positioned(
          right: 20,
          bottom: 24,
          child: FloatingActionButton.extended(
            onPressed: _scanning ? null : () => _pickFiles(),
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : const Icon(Icons.add_rounded),
            label: Text(
              _scanning ? '正在识别' : (isDesktopPlatform ? '添加到列表' : '添加文件'),
            ),
          ),
        ),
      ],
    );
  }

  /// 宽屏（Windows 桌面端与平板横屏）双栏布局。
  Widget _buildWideLayout(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: [
        // 左侧主要展示与快捷投放区
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 20, 24, 16),
                child: Row(
                  children: [
                    const _BrandLockup(compact: false),
                    const Spacer(),
                    const ThemeToggleButton(),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(32, 10, 32, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [_buildWideHeroDropCard(context, scheme)],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 垂直分割线
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: scheme.outlineVariant.withValues(alpha: .35),
        ),

        // 右侧面板（宽度固定 420，收缩呈现播放列表或内嵌设置）
        SizedBox(
          width: 420,
          child: Material(
            color: Colors.transparent,
            child: _showSettingsInPanel
                ? SettingsPage(
                    embedded: true,
                    onClose: () => setState(() => _showSettingsInPanel = false),
                  )
                : _buildWideRightPanel(context, scheme),
          ),
        ),
      ],
    );
  }

  Widget _buildWideHeroDropCard(BuildContext context, ColorScheme scheme) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: InkWell(
          onTap: () => _pickFiles(),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 32),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .32),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.video_library_rounded,
                    size: 46,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '拖拽视频到此处播放',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '或点击此处选择本地视频',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  onPressed: () => _pickFiles(),
                  icon: const Icon(Icons.file_open_rounded, size: 18),
                  label: const Text('选择视频文件'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 右侧面板：播放列表 / 任务列表两个选项卡。
  ///
  /// AI 字幕总开关关闭时不显示任务选项卡，面板等同于原来的播放列表。
  Widget _buildWideRightPanel(BuildContext context, ColorScheme scheme) {
    final tab = _activeHomeTab;

    return Column(
      children: [
        // 顶部面板 Header（标题位置换成选项卡）
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .35),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: _HomeTabBar(
                  current: tab,
                  playlistCount: _items.length,
                  onChanged: (value) => setState(() => _homeTab = value),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded),
                tooltip: '添加视频',
                onPressed: _scanning ? null : () => _pickFiles(),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '设置',
                onPressed: () => setState(() => _showSettingsInPanel = true),
              ),
            ],
          ),
        ),
        if (_scanning && tab == 0) const LinearProgressIndicator(),
        Expanded(
          child: tab == 1
              ? AiTaskPanel(onOpenVideo: _playPath)
              : (_items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.movie_filter_outlined,
                                size: 48,
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: .5,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '播放列表暂无内容',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                onPressed: () => _pickFiles(),
                                icon: const Icon(Icons.add_rounded, size: 18),
                                label: const Text('添加视频'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _VideoLibraryCard(
                              item: item,
                              onOpen: () => _open(item),
                              onExport: () => _export(item),
                              onDelete: () => _removeItem(item),
                              onLongPress: () => _showItemOptions(item),
                            ),
                          );
                        },
                      )),
        ),
      ],
    );
  }
}

/// 首页选项卡：播放列表 / 任务列表。
///
/// 任务数的角标自己监听 [AiTaskManager]，不必让整个首页跟着任务进度重建。
class _HomeTabBar extends StatelessWidget {
  const _HomeTabBar({
    required this.current,
    required this.playlistCount,
    required this.onChanged,
  });

  /// 当前选中的选项卡（0 = 播放列表，1 = 任务列表）。
  final int current;

  /// 播放列表视频数（>0 时在标签上显示角标）。
  final int playlistCount;

  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // AI 字幕总开关关闭：不显示选项卡，退化成原来的标题
    if (!aiSubtitleEnabled.value) {
      return const Text(
        '播放列表',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      );
    }

    return ListenableBuilder(
      listenable: AiTaskManager.instance,
      builder: (context, _) {
        final running = AiTaskManager.instance.activeTasks.length;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _chip(
              context,
              scheme: scheme,
              label: '播放列表',
              badge: playlistCount > 0 ? '$playlistCount' : null,
              selected: current == 0,
              onTap: () => onChanged(0),
            ),
            const SizedBox(width: 8),
            _chip(
              context,
              scheme: scheme,
              label: '任务列表',
              // 不显示数量角标：同一时刻最多只有一个识别任务（0 或 1），
              // 用旋转的小圈表示"正在识别"就够了。
              showSpinner: running > 0,
              selected: current == 1,
              onTap: () => onChanged(1),
            ),
          ],
        );
      },
    );
  }

  Widget _chip(
    BuildContext context, {
    required ColorScheme scheme,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    String? badge,
    bool showSpinner = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: .16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: .45)
                : scheme.outlineVariant.withValues(alpha: .4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSpinner) ...[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LibraryItem {
  const _LibraryItem({
    required this.path,
    required this.name,
    required this.isPflx,
    this.info,
  });

  final String path;
  final String name;
  final bool isPflx;
  final PflxInfo? info;

  String? get hiddenName => info?['name'] as String?;
  int get fileBytes => (info?['file_size'] as int?) ?? _safeFileLength(path);
  int get hiddenBytes => (info?['payload_len'] as int?) ?? 0;
  bool get encrypted => (info?['encrypted'] as bool?) ?? false;

  static int _safeFileLength(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }
}

/// 拖拽文件悬停在窗口上方时的投放提示层。
class _DropHintOverlay extends StatelessWidget {
  const _DropHintOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor.withValues(alpha: .86),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.file_download_outlined,
                size: 64,
                color: scheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '松开即可播放',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '支持拖入单个视频文件，PFLX 产物会自动识别',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned(
          top: -130,
          right: -100,
          child: _GlowOrb(
            color:
                (isDark ? const Color(0xFF5148A4) : PolyFlixColors.softViolet)
                    .withValues(alpha: isDark ? .25 : .7),
            size: 280,
          ),
        ),
        Positioned(
          top: 340,
          left: -120,
          child: _GlowOrb(
            color: (isDark ? const Color(0xFF7B4C65) : const Color(0xFFFFE8E4))
                .withValues(alpha: isDark ? .16 : .8),
            size: 250,
          ),
        ),
        child,
      ],
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _BrandLockup extends StatelessWidget {
  const _BrandLockup({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(compact ? 8 : 12),
          child: Image.asset(
            'assets/images/logo.png',
            width: compact ? 30 : 42,
            height: compact ? 30 : 42,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '影现播放器',
          style: TextStyle(
            fontSize: compact ? 20 : 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
          ),
        ),
      ],
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onPickFiles});

  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
        child: Column(
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.video_library_outlined,
                size: 38,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '一个特殊的万能视频播放器',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPickFiles,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('选择视频文件'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing!,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _VideoLibraryCard extends StatelessWidget {
  const _VideoLibraryCard({
    required this.item,
    required this.onOpen,
    required this.onExport,
    required this.onDelete,
    required this.onLongPress,
  });

  final _LibraryItem item;
  final VoidCallback onOpen;
  final VoidCallback onExport;
  final VoidCallback onDelete;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPflx = item.isPflx;

    final deleteBackground = Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            '从列表中移除',
            style: TextStyle(
              color: scheme.onErrorContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.delete_outline_rounded, color: scheme.onErrorContainer),
        ],
      ),
    );

    final exportBackground = Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 20),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.file_download_outlined, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Text(
            '导出隐藏视频',
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );

    return Dismissible(
      key: ValueKey(item.path),
      direction: isPflx
          ? DismissDirection.horizontal
          : DismissDirection.endToStart,
      // 双视频时：右滑为导出，左滑为删除；普通单视频时：仅支持左滑删除
      background: isPflx ? exportBackground : deleteBackground,
      secondaryBackground: isPflx ? deleteBackground : null,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          if (isPflx) {
            onExport();
          }
          return false;
        } else if (direction == DismissDirection.endToStart) {
          onDelete();
          return true;
        }
        return false;
      },
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _VideoThumbnailBadge(item: item),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FileTypeBadge(
                            isPflx: isPflx,
                            encrypted: item.encrypted,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.data_usage_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _formatBytes(item.fileBytes),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (isPflx) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '·',
                          style: TextStyle(color: scheme.outline),
                        ),
                      ),
                      Icon(
                        Icons.visibility_off_outlined,
                        size: 15,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '隐藏内容 ${_formatBytes(item.hiddenBytes)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
                if (isPflx) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: .35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome_rounded,
                          size: 15,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.hiddenName == null
                                ? '包含 PFLX 隐藏视频'
                                : item.hiddenName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoThumbnailBadge extends StatelessWidget {
  const _VideoThumbnailBadge({required this.item});

  final _LibraryItem item;

  @override
  Widget build(BuildContext context) {
    final isPflx = item.isPflx;
    final dotIndex = item.name.lastIndexOf('.');
    final ext = (dotIndex >= 0 && dotIndex < item.name.length - 1)
        ? item.name.substring(dotIndex + 1).toUpperCase()
        : 'VIDEO';

    if (isPflx) {
      return Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6366F1), Color(0xFFA855F7)],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withValues(alpha: .28),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Center(
          child: Icon(
            Icons.auto_awesome_motion_rounded,
            color: Colors.white,
            size: 26,
          ),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF283046), Color(0xFF1B2234)]
              : const [Color(0xFFE2E8F0), Color(0xFFCBD5E1)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (isDark ? Colors.white : Colors.black).withValues(alpha: .08),
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.smart_display_rounded,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
            size: 28,
          ),
          Positioned(
            bottom: 3,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: (isDark ? Colors.black : Colors.white).withValues(
                  alpha: .75,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                ext.length > 4 ? ext.substring(0, 4) : ext,
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileTypeBadge extends StatelessWidget {
  const _FileTypeBadge({required this.isPflx, required this.encrypted});

  final bool isPflx;
  final bool encrypted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isPflx ? scheme.primary : scheme.onSurfaceVariant;
    final label = isPflx ? (encrypted ? 'PFLX · 已加密' : 'PFLX 双视频') : '普通视频';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ExportResult {
  const _ExportResult.success() : success = true, error = null;
  const _ExportResult.failure(this.error) : success = false;

  final bool success;
  final String? error;
}

class _ExportNameDialog extends StatefulWidget {
  const _ExportNameDialog({required this.defaultName});

  final String defaultName;

  @override
  State<_ExportNameDialog> createState() => _ExportNameDialogState();
}

class _ExportNameDialogState extends State<_ExportNameDialog> {
  late final TextEditingController _controller;
  late final String _baseName;
  late final String _extension;

  @override
  void initState() {
    super.initState();
    final dotIndex = widget.defaultName.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex < widget.defaultName.length - 1) {
      _baseName = widget.defaultName.substring(0, dotIndex);
      _extension = widget.defaultName.substring(dotIndex);
    } else {
      _baseName = widget.defaultName;
      _extension = '';
    }
    _controller = TextEditingController(text: _baseName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    final base = text.isEmpty ? _baseName : text;
    Navigator.of(context).pop('$base$_extension');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.file_download_outlined, color: scheme.primary),
      title: const Text('导出隐藏视频'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('请输入文件名'),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '文件名',
              border: const OutlineInputBorder(),
              suffixText: _extension.isNotEmpty ? _extension : null,
              suffixStyle: TextStyle(
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('选择位置')),
      ],
    );
  }
}

class _ExportProgressDialog extends StatefulWidget {
  const _ExportProgressDialog({
    required this.sourcePath,
    required this.outputPath,
    required this.info,
    required this.onComplete,
  });

  final String sourcePath;
  final String outputPath;
  final PflxInfo info;
  final ValueChanged<_ExportResult> onComplete;

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  double _progress = 0;
  String _status = '正在准备导出…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startExport());
  }

  Future<void> _startExport() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    setState(() => _status = '正在导出并校验文件…');

    try {
      extractPayload(widget.sourcePath, widget.outputPath, widget.info, (
        done,
        total,
      ) {
        if (!mounted) return;
        setState(() {
          _progress = total == 0 ? 0 : done / total;
          _status = '已处理 ${_formatBytes(done)} / ${_formatBytes(total)}';
        });
      });
      if (mounted) widget.onComplete(const _ExportResult.success());
    } catch (error) {
      if (mounted) widget.onComplete(_ExportResult.failure(error.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(
        Icons.file_download_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('正在导出隐藏视频'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_status),
          const SizedBox(height: 18),
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${(_progress * 100).toStringAsFixed(0)}%',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '请保持应用开启，导出完成后会自动进行完整性校验。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '未知大小';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final digits = value >= 100 || index == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[index]}';
}

abstract final class _StoragePermissionHelper {
  static const _channel = MethodChannel(
    'com.polyflix.player/storage_permission',
  );

  static Future<bool> hasPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final granted = await _channel.invokeMethod<bool>('hasStoragePermission');
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestStoragePermission');
    } catch (_) {}
  }
}

abstract final class _LibraryStorage {
  static const _key = 'savedLibraryPaths';

  static Future<List<_LibraryItem>> load() async {
    try {
      final store = AppStore.library;
      await store.load();
      final paths = store.getStringList(_key) ?? const <String>[];
      final list = <_LibraryItem>[];
      for (final path in paths) {
        if (!File(path).existsSync()) continue;
        final info = scan(path);
        final isPflx =
            info != null &&
            info['payload_offset'] + info['payload_len'] <= info['file_size'];
        list.add(
          _LibraryItem(
            path: path,
            name: path.replaceAll('\\', '/').split('/').last,
            isPflx: isPflx,
            info: isPflx ? info : null,
          ),
        );
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<_LibraryItem> items) async {
    try {
      // 只存路径：文件不存在时 load() 会自动跳过该条
      await AppStore.library.setStringList(
        _key,
        items.map((e) => e.path).toList(),
      );
    } catch (_) {}
  }
}

class _UndoCountdownButton extends StatefulWidget {
  const _UndoCountdownButton({required this.duration, required this.onPressed});

  final Duration duration;
  final VoidCallback onPressed;

  @override
  State<_UndoCountdownButton> createState() => _UndoCountdownButtonState();
}

class _UndoCountdownButtonState extends State<_UndoCountdownButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = scheme.inversePrimary;

    return InkWell(
      onTap: widget.onPressed,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 背景底环
              SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  value: 1.0,
                  strokeWidth: 2,
                  color: accentColor.withValues(alpha: .2),
                ),
              ),
              // 倒计时动画环（8秒倒计时递减）
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      value: 1.0 - _controller.value,
                      strokeWidth: 2.2,
                      color: accentColor,
                      strokeCap: StrokeCap.round,
                    ),
                  );
                },
              ),
              // 居中文本
              Text(
                '撤销',
                style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
