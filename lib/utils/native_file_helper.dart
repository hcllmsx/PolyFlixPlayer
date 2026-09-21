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
  // 目录结构（Windows）：
  //
  //   %LOCALAPPDATA%\PolyFlixPlayer\   ← 持久数据，不受临时目录清理影响
  //   ├── models\whisper\              ← Whisper ASR 模型
  //   └── engine\                      ← 识别引擎包（CUDA / Vulkan，见 EnginePackManager）
  //
  //   %TEMP%\PolyFlixPlayer\           ← 可随时清理的临时缓存（清理缓存会整个删掉）
  //   ├── subtitles\                   ← 已生成的字幕缓存
  //   └── audio\                       ← 提取出的临时音频
  //
  // 模型与引擎放 LOCALAPPDATA：动辄数百 MB ~ 1GB，被系统清理工具删掉后重下代价太高；
  // 缓存放 TEMP：随时可以丢，清理后重算即可，所以直接以 PolyFlixPlayer 目录为缓存根，
  // 不必再多套一层 cache\。
  // ─────────────────────────────────────────────────

  static String? _cachedAppDataDirPath;

  /// 初始化持久化数据目录（在 main() 启动时调用）。
  ///
  /// Android 端使用应用私有 files 目录（/data/user/0/package_name/files/PolyFlixPlayer），
  /// 确保应用设置与播放列表永久独立于临时缓存目录，不受清理缓存与系统回收影响。
  /// 首次运行还会自动从旧临时缓存目录迁移历史数据。
  static Future<void> initializeDataDir() async {
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('getAppDataDirPath');
        if (path != null && path.isNotEmpty) {
          _cachedAppDataDirPath = path;
          _migrateOldCacheData(path);
        }
      } catch (_) {}
    }
    // 启动时自动清理历史孤儿切片与过期临时音频
    cleanStaleTempAudio();
  }

  static void _migrateOldCacheData(String targetDirPath) {
    try {
      final oldDir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}PolyFlixPlayer',
      );
      if (!oldDir.existsSync()) return;
      final targetDir = Directory(targetDirPath);
      if (!targetDir.existsSync()) targetDir.createSync(recursive: true);

      for (final fileName in ['settings.json', 'library.json', 'ai_tasks.json']) {
        final oldFile = File('${oldDir.path}${Platform.pathSeparator}$fileName');
        final newFile = File('${targetDir.path}${Platform.pathSeparator}$fileName');
        if (oldFile.existsSync() && !newFile.existsSync()) {
          oldFile.copySync(newFile.path);
        }
      }
    } catch (_) {}
  }

  /// 自动清理过期的临时音频文件与孤儿切片文件。
  ///
  /// - 立即清理上一次转录未正常结束留下的 `chunk_*.wav`；
  /// - 清理超过 3 天未被修改的 `pflx_asr_*.wav` 临时提取音频。
  static Future<void> cleanStaleTempAudio() async {
    try {
      final audioDir = desktopCacheAudioDir();
      if (!audioDir.existsSync()) return;
      final now = DateTime.now();
      final staleThreshold = now.subtract(const Duration(days: 3));

      for (final entity in audioDir.listSync()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('chunk_') && name.endsWith('.wav')) {
            try {
              entity.deleteSync();
            } catch (_) {}
          } else if (name.startsWith('pflx_asr_') && name.endsWith('.wav')) {
            try {
              final lastMod = entity.lastModifiedSync();
              if (lastMod.isBefore(staleThreshold)) {
                entity.deleteSync();
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// 桌面端缓存目录：%TEMP%\PolyFlixPlayer\
  ///
  /// 该目录下只有可再生的缓存（字幕缓存、临时音频），"清理应用缓存"会整个删除。
  static Directory desktopCacheDir() {
    final base = Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}PolyFlixPlayer');
  }

  /// 跨平台持久数据目录：
  /// - 桌面端：%LOCALAPPDATA%\PolyFlixPlayer\
  /// - Android 端：应用持久 files 目录下的 PolyFlixPlayer/
  static Directory appDataDir() {
    if (_cachedAppDataDirPath != null && _cachedAppDataDirPath!.isNotEmpty) {
      return Directory(_cachedAppDataDirPath!);
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      return Directory(
        '${localAppData.trim()}${Platform.pathSeparator}PolyFlixPlayer',
      );
    }
    if (Platform.isAndroid) {
      const fallback = '/data/data/com.polyflix.polyflix_player/files/PolyFlixPlayer';
      return Directory(fallback);
    }
    final base = Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}PolyFlixPlayer');
  }

  /// 兼容旧方法名
  static Directory desktopDataDir() => appDataDir();

  /// 桌面端模型目录：%LOCALAPPDATA%\PolyFlixPlayer\models\
  static Directory _desktopModelsDir() {
    return Directory(
      '${desktopDataDir().path}${Platform.pathSeparator}models',
    );
  }

  /// 桌面端音频提取缓存目录：%TEMP%\PolyFlixPlayer\audio\
  /// （仅存放提取出的临时 WAV，识别完成即删）
  static Directory desktopCacheAudioDir() {
    final base = desktopCacheDir().path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}audio');
  }

  /// 字幕缓存目录：持久化存储，重装应用后不丢失。
  ///
  /// - 桌面端：%LOCALAPPDATA%\PolyFlixPlayer\subtitles\
  /// - Android：应用 files 目录下 PolyFlixPlayer/subtitles/
  ///
  /// 旧版放在临时缓存目录（%TEMP% / cache），重装会丢。
  /// 首次调用时自动把旧目录里的缓存搬过来。
  static Directory desktopSubtitleCacheDir() {
    final base = appDataDir().path;
    final sep = Platform.pathSeparator;
    final dir = Directory('$base${sep}subtitles');
    // 懒迁移：旧临时目录如果还有字幕缓存文件，一次性搬到新目录
    _migrateSubtitleCache(dir);
    return dir;
  }

  static bool _subtitleCacheMigrated = false;

  static void _migrateSubtitleCache(Directory newDir) {
    if (_subtitleCacheMigrated) return;
    _subtitleCacheMigrated = true;
    try {
      final oldBase = desktopCacheDir().path;
      final sep = Platform.pathSeparator;
      final oldDir = Directory('$oldBase${sep}subtitles');
      if (!oldDir.existsSync()) return;
      if (!newDir.existsSync()) newDir.createSync(recursive: true);
      for (final entity in oldDir.listSync()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final name = entity.uri.pathSegments.last;
          final target = File('${newDir.path}$sep$name');
          if (!target.existsSync()) {
            entity.copySync(target.path);
          }
        }
      }
      // 搬完删旧目录
      oldDir.deleteSync(recursive: true);
    } catch (_) {}
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
  /// 桌面端统计 %TEMP%\PolyFlixPlayer\ 整个目录；模型与引擎包在
  /// %LOCALAPPDATA% 下，不计入、也不会被清理。
  static Future<int> getCacheSizeBytes() async {
    if (Platform.isAndroid) {
      try {
        final size = await _channel.invokeMethod<int>('getCacheSize');
        return size ?? 0;
      } catch (_) {}
      return 0;
    }
    // 桌面端：统计缓存根目录
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

  /// 获取已缓存的 AI 字幕信息：字节数与文件数量。
  static Future<({int bytes, int count})> getSubtitleCacheInfo() async {
    try {
      final dir = desktopSubtitleCacheDir();
      if (!dir.existsSync()) return (bytes: 0, count: 0);
      var totalBytes = 0;
      var fileCount = 0;
      for (final entity in dir.listSync()) {
        // `.progress.json` 是"识别断点"标记（不是字幕），不计入字幕缓存条目
        if (entity is File &&
            entity.path.endsWith('.json') &&
            !entity.path.endsWith('.progress.json')) {
          fileCount++;
          try {
            totalBytes += entity.lengthSync();
          } catch (_) {}
        }
      }
      return (bytes: totalBytes, count: fileCount);
    } catch (_) {
      return (bytes: 0, count: 0);
    }
  }

  /// 清空所有已识别生成的字幕缓存，返回已释放的字节数。
  static Future<int> clearSubtitleCache() async {
    try {
      final dir = desktopSubtitleCacheDir();
      if (!dir.existsSync()) return 0;
      var clearedBytes = 0;
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            clearedBytes += entity.lengthSync();
            entity.deleteSync();
          } catch (_) {}
        }
      }
      return clearedBytes;
    } catch (_) {
      return 0;
    }
  }

  /// 清理应用临时缓存，返回已释放的字节数。
  ///
  /// 清理的是系统的临时缓存目录（Android: cacheDir / 桌面端: %TEMP%\PolyFlixPlayer\），
  /// 包括提取的临时音频 WAV、文件选择器临时文件等；
  /// 模型位于 models 目录，已生成的字幕与应用设置位于持久化目录，均不受影响。
  static Future<int> clearCache() async {
    int cleared = 0;
    if (Platform.isAndroid) {
      try {
        cleared = (await _channel.invokeMethod<int>('clearCache')) ?? 0;
      } catch (_) {}
    } else {
      // 桌面端：整个缓存根目录连同内容删除，下次使用时按需重建
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
