/// 外挂字幕的"记住上次选择"。
///
/// 把某个视频用过的外挂字幕（路径、是否纯文本模式、时间轴偏移）以及当时选在
/// 主/副哪条通道记到 `library.json`。放在同一个文件里的理由与播放进度一致：
/// 它们都是"这个视频的属性"，一起备份/清理最直观。
library;

import 'app_store.dart';

/// 一条外挂字幕记录。
class ExternalSubtitleRecord {
  const ExternalSubtitleRecord({
    required this.path,
    this.plainText = false,
    this.offsetMs = 0,
  });

  /// 字幕文件路径。
  final String path;

  /// 是否被用户切成了"纯文本模式"（对特效字幕才有意义）。
  final bool plainText;

  /// 时间轴偏移（毫秒，正数 = 字幕整体延后）。
  final int offsetMs;
}

/// 某个视频的外挂字幕记忆。
class ExternalSubtitleMemory {
  const ExternalSubtitleMemory({
    this.records = const <ExternalSubtitleRecord>[],
    this.primaryIndex,
    this.secondaryIndex,
  });

  final List<ExternalSubtitleRecord> records;

  /// 上次主字幕选的是第几条外挂字幕；null 表示主字幕不是外挂字幕。
  final int? primaryIndex;

  /// 上次副字幕选的是第几条外挂字幕；null 表示副字幕不是外挂字幕。
  final int? secondaryIndex;

  bool get isEmpty => records.isEmpty;
}

/// 外挂字幕记忆存储（读写 `library.json`）。
abstract final class ExternalSubtitleStore {
  /// 外挂字幕记忆在 `library.json` 里的键。
  static const String _key = 'externalSubtitles';

  /// 是否已把 `library.json` 读进内存。
  ///
  /// 与 [PlaybackProgressStore] 同理：读写都经过同一个 [AppStore] 单例，
  /// 内存里的数据始终最新，反复读盘没有收益。
  static bool _loaded = false;

  static Future<void> _ensureLoaded(AppStore store) async {
    if (_loaded) return;
    await store.load();
    _loaded = true;
  }

  /// 读取某个视频上次用过的外挂字幕。
  static Future<ExternalSubtitleMemory> load(String videoPath) async {
    if (videoPath.isEmpty) return const ExternalSubtitleMemory();
    try {
      final store = AppStore.library;
      await _ensureLoaded(store);
      final entry = _all(store)[videoPath];
      if (entry == null) return const ExternalSubtitleMemory();

      final records = <ExternalSubtitleRecord>[];
      final items = entry['items'];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          final path = item['path'];
          if (path is! String || path.isEmpty) continue;
          records.add(ExternalSubtitleRecord(
            path: path,
            plainText: item['plainText'] == true,
            offsetMs: (item['offsetMs'] as num?)?.toInt() ?? 0,
          ));
        }
      }
      if (records.isEmpty) return const ExternalSubtitleMemory();

      return ExternalSubtitleMemory(
        records: records,
        primaryIndex: _validIndex(entry['primary'], records.length),
        secondaryIndex: _validIndex(entry['secondary'], records.length),
      );
    } catch (_) {
      return const ExternalSubtitleMemory();
    }
  }

  /// 写入某个视频的外挂字幕记忆。
  static Future<void> save(
    String videoPath,
    ExternalSubtitleMemory memory,
  ) async {
    if (videoPath.isEmpty) return;
    try {
      final store = AppStore.library;
      await _ensureLoaded(store);
      final all = _all(store);
      if (memory.isEmpty) {
        if (all.remove(videoPath) == null) return;
      } else {
        all[videoPath] = <String, Object?>{
          'items': memory.records
              .map((r) => <String, Object?>{
                    'path': r.path,
                    'plainText': r.plainText,
                    'offsetMs': r.offsetMs,
                  })
              .toList(growable: false),
          'primary': memory.primaryIndex,
          'secondary': memory.secondaryIndex,
        };
      }
      await store.setMap(_key, all);
    } catch (_) {
      // 落盘失败不影响本次播放
    }
  }

  /// 清除某个视频的外挂字幕记忆。
  static Future<void> clear(String videoPath) async {
    if (videoPath.isEmpty) return;
    try {
      final store = AppStore.library;
      await _ensureLoaded(store);
      final all = _all(store);
      if (all.remove(videoPath) == null) return;
      await store.setMap(_key, all);
    } catch (_) {}
  }

  /// 读取全部记忆（只保留结构正确的条目，坏数据不至于把功能带崩）。
  static Map<String, Map<String, dynamic>> _all(AppStore store) {
    final raw = store.getMap(_key);
    if (raw == null) return <String, Map<String, dynamic>>{};
    final result = <String, Map<String, dynamic>>{};
    raw.forEach((path, value) {
      if (value is Map) result[path] = Map<String, dynamic>.from(value);
    });
    return result;
  }

  /// 下标必须是记录范围内的有效值，脏数据一律按"没选"处理。
  static int? _validIndex(Object? value, int length) {
    final index = (value as num?)?.toInt();
    if (index == null || index < 0 || index >= length) return null;
    return index;
  }
}
