/// 网盘下载入口卡片（模型对照表与引擎对照表共用）。
///
/// 一份资料通常同时放在好几个网盘里（各家限速不同，用户挑顺手的用），所以这里
/// 展示的是**一组**链接：每条一行，带网盘名标签、链接本身，以及「打开 / 复制」
/// 两个动作（复制链接最常见——贴到浏览器或网盘客户端里比唤起外部应用更稳）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/app_toast.dart';
import 'download_links.dart';

/// 一组网盘分享：标题 + 链接列表。
class NetdiskLinksCard extends StatelessWidget {
  const NetdiskLinksCard({
    super.key,
    required this.title,
    required this.links,
    this.multipleNote = '两个网盘内容一样，挑顺手的下载即可',
  });

  /// 卡片标题（如 `模型网盘`）。
  final String title;

  final List<NetdiskLink> links;

  /// 有多个网盘时的说明，单个网盘时不显示。
  final String multipleNote;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                if (links.length > 1)
                  Text(
                    multipleNote,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 6),
                // 一条一行：窄屏也不会把链接挤成溢出
                for (final link in links) _linkRow(context, scheme, link),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkRow(
    BuildContext context,
    ColorScheme scheme,
    NetdiskLink link,
  ) {
    final uri = Uri.tryParse(link.url);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              link.name,
              style: TextStyle(fontSize: 11.5, color: scheme.primary),
            ),
          ),
          const SizedBox(width: 8),
          // 链接很长，按列排 + 最多两行省略，剩下的交给复制按钮
          Expanded(
            child: Text(
              link.url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: '在浏览器中打开',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.open_in_new_rounded, size: 18, color: scheme.primary),
            onPressed: () async {
              if (uri == null) return;
              final ok = await launchUrl(
                uri,
                mode: LaunchMode.externalApplication,
              );
              if (!ok && context.mounted) {
                AppToast.show(context, '打开失败，请复制链接到浏览器里手动打开',
                    isError: true);
              }
            },
          ),
          IconButton(
            tooltip: '复制链接',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link.url));
              AppToast.show(context, '已复制链接，粘贴到浏览器打开即可下载');
            },
          ),
        ],
      ),
    );
  }
}
