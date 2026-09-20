/// 全应用统一的底部提示条。
///
/// 只有这里一处决定 SnackBar 的观感，别处不要再手写 `SnackBar(...)`，
/// 否则又会出现"有的提示条实心、有的半透明"的不一致。
library;

import 'package:flutter/material.dart';

/// 提示条的**整体**不透明度：底板与内容（文字 / 按钮）都按这个值压一档，
/// 这样看过去是"整条半透明"，而不是"底板透、字很实"。
const double kSnackBarOpacity = .7;

/// 构造一条 [SnackBar]。
///
/// [duration] 默认沿用 SnackBar 的 4 秒；像"移除视频并可撤回"这种需要
/// 用户反应的场景才传更长的时长。
SnackBar buildSnackBar(
  BuildContext context, {
  required Widget content,
  Duration duration = const Duration(seconds: 4),
}) {
  final scheme = Theme.of(context).colorScheme;
  return SnackBar(
    duration: duration,
    backgroundColor: scheme.inverseSurface.withValues(alpha: kSnackBarOpacity),
    // 半透明底板带投影会显得脏，投影统一关掉。
    elevation: 0,
    content: Opacity(opacity: kSnackBarOpacity, child: content),
  );
}
