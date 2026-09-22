import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/app_snack_bar.dart';
import 'update_service.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _currentVersion = '1.0.0';
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadLocalVersion();
  }

  Future<void> _loadLocalVersion() async {
    final v = await UpdateChecker.getLocalVersion();
    if (mounted) setState(() => _currentVersion = v);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          buildSnackBar(context, content: Text('无法打开链接: $url')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          buildSnackBar(context, content: Text('打开链接失败: $e')),
        );
      }
    }
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);

    try {
      final remoteVersion = await UpdateChecker.fetchRemoteVersion();
      if (!mounted) return;

      if (remoteVersion == null || remoteVersion.isEmpty) {
        _showUpdateDialog(title: '检查更新', content: '未检测到新版本或暂未发布更新。');
      } else if (UpdateChecker.isNewerVersion(remoteVersion, _currentVersion)) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ForceUpdateDialog(
            remoteVersion: remoteVersion,
            currentVersion: _currentVersion,
          ),
        );
      } else {
        _showUpdateDialog(
          title: '检查更新',
          content: '当前已是最新版本 (v$_currentVersion)。',
        );
      }
    } catch (_) {
      if (mounted) {
        _showUpdateDialog(title: '检查更新', content: '连接更新服务器失败，请检查网络后重试。');
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  void _showUpdateDialog({
    required String title,
    required String content,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.system_update_rounded,
          color: Theme.of(ctx).colorScheme.primary,
        ),
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          if (actionLabel != null && onAction != null)
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                onAction();
              },
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }

  /// 展示本软件用到的全部开源组件许可。
  ///
  /// 不需要手工维护这份清单：Flutter 在构建时会把所有依赖（含 `third_party/`
  /// 下本地 vendor 的包）的 LICENSE 汇总成 `NOTICES.Z` 打进应用包，
  /// `LicensePage` 直接读取并渲染，以后新增依赖会自动出现在里面。
  void _showLicenses() {
    showLicensePage(
      context: context,
      applicationName: '影现播放器',
      applicationVersion: 'v$_currentVersion',
      applicationIcon: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset(
          'assets/images/logo.png',
          width: 44,
          height: 44,
          fit: BoxFit.cover,
        ),
      ),
      applicationLegalese: 'PolyFlixPlayer · by hcllmsx\n本项目基于 GPL-3.0 协议开源',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('关于影现播放器')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: [
          Center(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '影现播放器',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  'v$_currentVersion',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: _checkingUpdate
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.system_update_alt_rounded),
                  title: const Text('检查更新'),
                  subtitle: Text(
                    _checkingUpdate ? '正在检查最新版本…' : '当前版本: v$_currentVersion',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _checkingUpdate ? null : _checkUpdate,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.language_rounded),
                  title: const Text('软件官网'),
                  subtitle: const Text('polyflix.sxrec.com'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _openUrl('https://polyflix.sxrec.com/'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('开源链接'),
                  subtitle: const Text('点击查看 github 仓库'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () =>
                      _openUrl('https://github.com/hcllmsx/PolyFlixPlayer'),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.person_outline_rounded),
                  title: const Text('联系作者'),
                  subtitle: const Text('bilibili 火车啦啦'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _openUrl('https://space.bilibili.com/255947051'),
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
          const SizedBox(height: 12),
          Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: _showLicenses,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text(
                  '开源软件许可',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant.withValues(alpha: .7),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
