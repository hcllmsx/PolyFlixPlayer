import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../utils/native_file_helper.dart';
import '../utils/platform_utils.dart';
import 'about_page.dart';
import 'app_settings.dart';
import 'update_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _cacheBytes = 0;
  bool _loadingCache = true;
  bool _clearingCache = false;
  String _currentVersion = '26.8.23';

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
    _loadLocalVersion();
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
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
          const _SectionTitle(title: '存储与空间'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(
                Icons.cleaning_services_rounded,
                color: scheme.primary,
              ),
              title: const Text('清理应用缓存'),
              subtitle: Text(
                _loadingCache
                    ? '正在计算缓存大小…'
                    : '当前临时缓存占用: ${_formatBytes(_cacheBytes)}',
              ),
              trailing: _clearingCache
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : FilledButton.tonal(
                      onPressed: _cacheBytes > 0 ? _clearCache : null,
                      child: const Text('清理'),
                    ),
              onTap: _cacheBytes > 0 && !_clearingCache ? _clearCache : null,
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
      ),
    );
  }
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
