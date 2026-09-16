import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/platform_utils.dart';

abstract final class UpdateChecker {
  static const String primaryUrl =
      'https://raw.githubusercontent.com/hcllmsx/PolyFlixPlayer/main/VERSION';
  static const String backupUrl =
      'https://gh-proxy.com/https://raw.githubusercontent.com/hcllmsx/PolyFlixPlayer/main/VERSION';
  static const String releaseUrl =
      'https://github.com/hcllmsx/PolyFlixPlayer/releases';

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

class ForceUpdateDialog extends StatelessWidget {
  const ForceUpdateDialog({
    super.key,
    required this.remoteVersion,
    required this.currentVersion,
  });

  final String remoteVersion;
  final String currentVersion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
                child: FilledButton(
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(text: UpdateChecker.releaseUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制最新版本下载地址到剪贴板。')),
                    );
                  },
                  child: const Text('前往下载'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
