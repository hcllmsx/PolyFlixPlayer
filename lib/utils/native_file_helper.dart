import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

class SelectedVideoFile {
  const SelectedVideoFile({
    required this.path,
    required this.name,
  });

  final String path;
  final String name;
}

abstract final class NativeFileHelper {
  static const MethodChannel _channel = MethodChannel('com.polyflix.player/storage_permission');

  /// 选择视频文件，Android 上优先直读真实物理路径（0拷贝），其他平台走标准 FilePicker
  static Future<List<SelectedVideoFile>> pickVideos() async {
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeListMethod<Map<dynamic, dynamic>>('pickVideoFiles');
        if (result != null && result.isNotEmpty) {
          final list = <SelectedVideoFile>[];
          for (final map in result) {
            final path = map['path'] as String?;
            final name = map['name'] as String? ?? (path != null ? File(path).uri.pathSegments.last : 'video.mp4');
            if (path != null && path.isNotEmpty) {
              list.add(SelectedVideoFile(path: path, name: name));
            }
          }
          return list;
        }
      } catch (_) {
        // Fallback to FilePicker if channel method fails
      }
    }

    // 默认 / 其他平台回退
    final files = await FilePicker.pickFiles(
      type: FileType.video,
    );
    if (files.isEmpty) return const [];

    return files
        .where((f) => f.path != null)
        .map((f) => SelectedVideoFile(path: f.path!, name: f.name))
        .toList();
  }

  /// 桌面端自有缓存目录：%TEMP%\PolyFlixPlayer\。
  ///
  /// 播放为流式（不落盘），当前该目录基本为空；约定未来一切可能产生的
  /// 本地缓存都放进这里，缓存统计/清理只动这个目录，绝不碰 %TEMP% 里
  /// 其他程序的文件。
  static Directory _desktopCacheDir() {
    final base = Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}PolyFlixPlayer');
  }

  /// 递归统计目录大小（字节）。目录不存在或中途出错均按已统计到的返回。
  static Future<int> _directorySize(Directory dir) async {
    if (!dir.existsSync()) return 0;
    var total = 0;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 获取当前应用缓存总大小（字节）
  static Future<int> getCacheSizeBytes() async {
    if (Platform.isAndroid) {
      try {
        final size = await _channel.invokeMethod<int>('getCacheSize');
        return size ?? 0;
      } catch (_) {}
      return 0;
    }
    // 桌面端：统计自有缓存目录
    try {
      return await _directorySize(_desktopCacheDir());
    } catch (_) {}
    return 0;
  }

  /// 清理应用缓存，返回已释放的字节数
  static Future<int> clearCache() async {
    int cleared = 0;
    if (Platform.isAndroid) {
      try {
        cleared = (await _channel.invokeMethod<int>('clearCache')) ?? 0;
      } catch (_) {}
    } else {
      // 桌面端：删除自有缓存目录（连同内容），下次使用时按需重建
      try {
        final dir = _desktopCacheDir();
        if (dir.existsSync()) {
          cleared = await _directorySize(dir);
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {}
    return cleared;
  }
}
