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

  // ─────────────────────────────────────────────────
  // 目录结构：
  //   PolyFlixPlayer/
  //   ├── cache/         ← 普通缓存（可安全清理）
  //   │   └── subtitles/ ← 已生成的字幕缓存
  //   └── models/        ← 模型目录（清理缓存时跳过）
  //       └── whisper/   ← Whisper ASR 模型
  //
  // 清理缓存只动 cache/，不碰 models/。
  // ─────────────────────────────────────────────────

  /// 桌面端缓存目录：%TEMP%\PolyFlixPlayer\cache\
  static Directory desktopCacheDir() {
    final base = Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}PolyFlixPlayer${sep}cache');
  }

  /// 桌面端模型目录：%TEMP%\PolyFlixPlayer\models\
  static Directory _desktopModelsDir() {
    final base = Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}PolyFlixPlayer${sep}models');
  }

  /// 桌面端音频提取缓存目录：%TEMP%\PolyFlixPlayer\cache\audio\
  static Directory desktopCacheAudioDir() {
    final base = desktopCacheDir().path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}audio');
  }

  /// 桌面端字幕缓存目录：%TEMP%\PolyFlixPlayer\cache\subtitles\
  static Directory desktopSubtitleCacheDir() {
    final base = desktopCacheDir().path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}subtitles');
  }

  /// 打开系统文件管理器并定位到指定目录（桌面端生效）。
  static Future<void> openDirectory(Directory dir) async {
    try {
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir.path]);
      }
    } catch (_) {}
  }

  /// 桌面端 Whisper 模型目录：%TEMP%\PolyFlixPlayer\models\whisper\
  static Directory desktopWhisperModelDir() {
    final base = _desktopModelsDir().path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}whisper');
  }

  /// 获取模型存放目录路径（跨平台）。
  ///
  /// Android 端使用 filesDir（系统不会自动清理），桌面端使用
  /// %TEMP%\PolyFlixPlayer\models\whisper\。
  static Future<String> getWhisperModelDirPath() async {
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('getModelsDirPath');
        if (path != null && path.isNotEmpty) return path;
      } catch (_) {}
      // Fallback：用 cacheDir 的兄弟目录
      return '/data/data/com.polyflix.polyflix_player/files/models/whisper';
    }
    final dir = desktopWhisperModelDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
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

  /// 获取当前应用缓存总大小（字节）。
  ///
  /// 只统计 cache/ 目录，不含模型文件。
  static Future<int> getCacheSizeBytes() async {
    if (Platform.isAndroid) {
      try {
        final size = await _channel.invokeMethod<int>('getCacheSize');
        return size ?? 0;
      } catch (_) {}
      return 0;
    }
    // 桌面端：统计 cache/ 目录
    try {
      return await _directorySize(desktopCacheDir());
    } catch (_) {}
    return 0;
  }

  /// 获取模型文件占用空间（字节）。
  static Future<int> getModelsSizeBytes() async {
    if (Platform.isAndroid) {
      try {
        final size = await _channel.invokeMethod<int>('getModelsSize');
        return size ?? 0;
      } catch (_) {}
      return 0;
    }
    try {
      return await _directorySize(_desktopModelsDir());
    } catch (_) {}
    return 0;
  }

  /// 清理应用缓存，返回已释放的字节数。
  ///
  /// **只清理 cache/ 目录，不动 models/ 目录。**
  static Future<int> clearCache() async {
    int cleared = 0;
    if (Platform.isAndroid) {
      try {
        cleared = (await _channel.invokeMethod<int>('clearCache')) ?? 0;
      } catch (_) {}
    } else {
      // 桌面端：删除 cache/ 目录（连同内容），下次使用时按需重建
      try {
        final dir = desktopCacheDir();
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

  /// 删除所有已下载的模型文件，返回已释放的字节数。
  ///
  /// 仅在用户从模型管理界面主动调用时使用。
  static Future<int> clearModels() async {
    int cleared = 0;
    if (Platform.isAndroid) {
      try {
        cleared = (await _channel.invokeMethod<int>('clearModels')) ?? 0;
      } catch (_) {}
    } else {
      try {
        final dir = _desktopModelsDir();
        if (dir.existsSync()) {
          cleared = await _directorySize(dir);
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }
    return cleared;
  }
}
