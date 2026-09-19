import 'dart:io';
import 'package:flutter/services.dart';

/// 移动端系统亮度与音量控制通道。
class PlatformMediaHelper {
  static const MethodChannel _channel =
      MethodChannel('com.polyflix.player/media_control');

  static bool _handlerInitialized = false;
  static final List<void Function(double volume)> _volumeListeners = [];

  static void _ensureHandler() {
    if (_handlerInitialized) return;
    _handlerInitialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onVolumeChanged') {
        final volume = (call.arguments as num?)?.toDouble();
        if (volume != null) {
          for (final listener in List.of(_volumeListeners)) {
            listener(volume.clamp(0.0, 1.0));
          }
        }
      }
    });
  }

  /// 监听系统音量变化（如硬件实体音量键）。
  static void addVolumeListener(void Function(double volume) listener) {
    _ensureHandler();
    _volumeListeners.add(listener);
  }

  /// 移除系统音量变化监听。
  static void removeVolumeListener(void Function(double volume) listener) {
    _volumeListeners.remove(listener);
  }

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
