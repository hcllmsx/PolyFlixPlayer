import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/platform_utils.dart';

abstract final class UpdateChecker {
  /// 主链接：gh-proxy 加速。
  ///
  /// 用法是在完整的 GitHub 链接前拼代理域名（见
  /// <https://gh-proxy.com/docs/github-accelerator>），官方 raw 在国内有时会连不上，
  /// 所以让它走前面：绝大多数用户这里就能秒回。
  static const String primaryUrl =
      'https://gh-proxy.com/https://raw.githubusercontent.com/hcllmsx/PolyFlixPlayer/main/VERSION';

  /// 副链接：GitHub 官方 raw，gh-proxy 挂了或被限流时兜底。
  static const String backupUrl =
      'https://raw.githubusercontent.com/hcllmsx/PolyFlixPlayer/main/VERSION';
  static const String releaseUrl =
      'https://github.com/hcllmsx/PolyFlixPlayer/releases';

  /// 官网（与影藏 PolyFlix 共用）。
  static const String officialUrl = 'https://polyflix.sxrec.com/';

  static Future<String> getLocalVersion() async {
    try {
      final text = await rootBundle.loadString('VERSION');
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) return trimmed;
    } catch (_) {}
    return '1.0.0';
  }

  static Future<String?> fetchRemoteVersion() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      // 优先尝试主链接
      try {
        final request = await client.getUrl(Uri.parse(primaryUrl));
        final response = await request.close();
        if (response.statusCode == 200) {
          final body = (await response.transform(utf8.decoder).join()).trim();
          if (_isValidVersionString(body)) return body;
        }
      } catch (_) {}

      // 备用链接
      try {
        final request = await client.getUrl(Uri.parse(backupUrl));
        final response = await request.close();
        if (response.statusCode == 200) {
          final body = (await response.transform(utf8.decoder).join()).trim();
          if (_isValidVersionString(body)) return body;
        }
      } catch (_) {}

      return null;
    } finally {
      client.close();
    }
  }

  static bool _isValidVersionString(String str) {
    return RegExp(r'^\d+(\.\d+)+$').hasMatch(str);
  }

  static bool isNewerVersion(String remote, String current) {
    try {
      final rParts = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final cParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final maxLen = rParts.length > cParts.length ? rParts.length : cParts.length;
      for (var i = 0; i < maxLen; i++) {
        final r = i < rParts.length ? rParts[i] : 0;
        final c = i < cParts.length ? cParts[i] : 0;
        if (r > c) return true;
        if (r < c) return false;
      }
    } catch (_) {}
    return false;
  }
}

class ForceUpdateDialog extends StatefulWidget {
  const ForceUpdateDialog({
    super.key,
    required this.remoteVersion,
    required this.currentVersion,
  });

  final String remoteVersion;
  final String currentVersion;

  @override
  State<ForceUpdateDialog> createState() => _ForceUpdateDialogState();
}

class _ForceUpdateDialogState extends State<ForceUpdateDialog> {
  /// 是否处于"复制兜底"状态：系统浏览器打开链接失败时，退回复制地址到
  /// 剪贴板，并临时把按钮文字换成复制成功的反馈。
  /// [_lastFallbackUrl] 记录进入兜底状态的是哪个按钮的链接，用于还原按钮文案。
  bool _copyFallback = false;
  String? _lastFallbackUrl;
  Timer? _resetTimer;

  /// 「前往下载 / 前往官网」：优先调用系统默认浏览器直接打开对应页面；
  /// 打开失败（无默认浏览器关联、被拦截等）才退回复制地址。
  ///
  /// 反馈不能走 SnackBar：本弹窗挂在 Navigator 的 root overlay 上，蒙版
  /// 层级天然高于 ScaffoldMessenger 的 SnackBar（Windows / Android 一致），
  /// 提示会被黑色蒙版盖住，所以反馈直接画在按钮文字上。
  ///
  /// [url] 要打开的链接；[fallbackLabel] 为空串表示该按钮没有复制兜底状态
  /// （官网按钮），否则进入复制兜底并临时显示该文案。
  Future<void> _openUrl(String url, {String fallbackLabel = ''}) async {
    final uri = Uri.parse(url);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted || fallbackLabel.isEmpty) return;

    _lastFallbackUrl = url;
    Clipboard.setData(ClipboardData(text: url));
    setState(() => _copyFallback = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copyFallback = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remoteVersion = widget.remoteVersion;
    final currentVersion = widget.currentVersion;

    return PopScope(
      canPop: false,
      child: AlertDialog(
        icon: Icon(
          Icons.system_update_rounded,
          size: 44,
          color: scheme.primary,
        ),
        title: const Text(
          '发现新版本',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '检测到影现播放器已发布重要更新（v$remoteVersion）。\n当前版本（v$currentVersion）需更新后方可继续使用。',
              style: const TextStyle(height: 1.5),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: .4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '请前往项目发布页下载最新安装包。',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    // SystemNavigator.pop() 只对 Android/iOS 有效（相当于 finish()），
                    // Windows 上不会退出进程，桌面端需直接结束进程。
                    if (isDesktopPlatform) {
                      exit(0);
                    } else {
                      SystemNavigator.pop();
                    }
                  },
                  child: const Text('退出软件'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _openUrl(UpdateChecker.officialUrl),
                  child: const Text('前往官网'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _openUrl(
                    UpdateChecker.releaseUrl,
                    fallbackLabel: '已复制地址 ✓',
                  ),
                  child: Text(
                    _copyFallback && _lastFallbackUrl == UpdateChecker.releaseUrl
                        ? '已复制地址 ✓'
                        : '前往 GitHub',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
