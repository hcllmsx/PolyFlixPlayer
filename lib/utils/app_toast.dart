/// 全局浮层提示：显示在所有弹窗/弹层之上。
///
/// 为什么不用 [SnackBar]：SnackBar 由 Scaffold 渲染（ScaffoldMessenger 挂在
/// MaterialApp 上），而底部弹窗、对话框是 Navigator Overlay 里的路由，
/// 天然盖在 Scaffold 之上 —— 于是「浏览全部模型」弹出时，下载完成/失败的
/// SnackBar 会被弹窗挡住，导出 SRT 的提示同理。
///
/// 这里改为往**根 Overlay** 里插一条浮层：插入时机晚于弹窗，因此必然显示在
/// 最上层；4 秒后自动消失，期间不拦截任何点击。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'app_snack_bar.dart';

/// 浮层提示入口。
class AppToast {
  AppToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// 在屏幕底部弹出一条提示，[isError] 为真时用红色底板。
  ///
  /// 同一时刻只保留一条：新提示会顶掉旧的，避免叠成一堆。
  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      // 拿不到 Overlay（widget 已卸载等极端情况）时退回 SnackBar，而不是静默丢弃
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        buildSnackBar(context, content: Text(message)),
      );
      return;
    }

    hide();
    final entry = OverlayEntry(
      builder: (_) => _ToastContent(message: message, isError: isError),
    );
    _entry = entry;
    overlay.insert(entry);

    // 文案长（比如带失败原因与路径）时多留一会儿，方便读完
    final seconds = (3 + message.length ~/ 40).clamp(3, 8);
    _timer = Timer(Duration(seconds: seconds), hide);
  }

  /// 立即收起当前提示。
  static void hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _ToastContent extends StatelessWidget {
  const _ToastContent({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: IgnorePointer(
        child: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isError
                        ? const Color(0xF0B3261E)
                        : const Color(0xF02B3138),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
