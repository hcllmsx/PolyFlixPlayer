import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);

    try {
      final remoteVersion = await UpdateChecker.fetchRemoteVersion();
      if (!mounted) return;

      if (remoteVersion == null || remoteVersion.isEmpty) {
        _showUpdateDialog(
          title: '检查更新',
          content: '未检测到新版本或暂未发布更新。',
        );
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
        _showUpdateDialog(
          title: '检查更新',
          content: '连接更新服务器失败，请检查网络后重试。',
        );
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

  void _showIntroDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.movie_filter_rounded,
          color: Theme.of(ctx).colorScheme.primary,
        ),
        title: const Text('影现播放器介绍'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '影现播放器（PolyFlixPlayer）是一款功能强大的全格式万能视频播放器，基于全能播放内核构建，支持 MP4、MKV、MOV、AVI 等主流格式的顺畅硬件加速解码。',
                style: TextStyle(height: 1.5),
              ),
              SizedBox(height: 12),
              Text(
                '独创 PFLX 双视频隐写技术：',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 4),
              Text(
                '能够智能识别并流式播放 MP4 容器内嵌的隐藏视频，无需事先完整解包；同时提供无损高速抽取与 CRC32 完整性校验导出功能。',
                style: TextStyle(height: 1.4),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('了解'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('关于影现播放器'),
      ),
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
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('软件介绍'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showIntroDialog,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: _checkingUpdate
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.system_update_alt_rounded),
                  title: const Text('检查更新'),
                  subtitle: Text(_checkingUpdate ? '正在检查最新版本…' : '当前版本: v$_currentVersion'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _checkingUpdate ? null : _checkUpdate,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('开源链接'),
                  subtitle: const Text('点击查看 github 仓库'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _openUrl('https://github.com/hcllmsx/PolyFlixPlayer-Mobile'),
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
        ],
      ),
    );
  }
}
