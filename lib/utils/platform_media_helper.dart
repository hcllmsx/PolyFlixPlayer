import 'dart:io';
import 'package:flutter/services.dart';

/// 移动端系统亮度与音量控制通道。
class PlatformMediaHelper {
  static const MethodChannel _channel =
      MethodChannel('com.polyflix.player/media_control');

  /// 获取当前屏幕亮度（0.01 ~ 1.0）。
  static Future<double> getBrightness() async {
    if (!Platform.isAndroid) return 0.5;
    try {
      final res = await _channel.invokeMethod<double>('getBrightness');
      return (res ?? 0.5).clamp(0.01, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  /// 设置当前窗口屏幕亮度（0.01 ~ 1.0）。
  static Future<void> setBrightness(double brightness) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setBrightness', {
        'brightness': brightness.clamp(0.01, 1.0),
      });
    } catch (_) {}
  }

  /// 还原当前窗口屏幕亮度为系统设置。
  static Future<void> resetBrightness() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('resetBrightness');
    } catch (_) {}
  }

  /// 获取当前系统媒体音量（0.0 ~ 1.0）。
  static Future<double> getVolume() async {
    if (!Platform.isAndroid) return 0.5;
    try {
      final res = await _channel.invokeMethod<double>('getVolume');
      return (res ?? 0.5).clamp(0.0, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  /// 设置系统媒体音量（0.0 ~ 1.0）。
  static Future<void> setVolume(double volume) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setVolume', {
        'volume': volume.clamp(0.0, 1.0),
      });
    } catch (_) {}
  }
}
