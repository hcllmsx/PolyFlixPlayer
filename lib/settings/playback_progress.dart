/// 视频播放进度记录：让"再次打开同一个视频"能从上次的位置继续播放。
///
/// 存储位置与播放列表**同一个文件**（`library.json` 的 `playbackPositions` 键）：
///  1. 两者生命周期一致 —— 视频被移出播放列表，它的进度也就没有意义了；
///  2. 记录条数与播放列表条数同量级，一起备份/清理最直观；
///  3. 播放进度天然就是"这条播放列表记录"的属性，分成两个文件反而容易失配。
///
/// **只记录播放列表里的视频**：直接拖进播放器的临时文件不落盘
///（这类文件本来就不进播放列表，下次也无从续播）。
library;

import 'app_settings.dart';
import 'app_store.dart';

/// 播放进度存储（读写 `library.json`）。
abstract final class PlaybackProgressStore {
  /// 播放列表在 `library.json` 里的键。
  ///
  /// 首页的 `_LibraryStorage` 也用这一个常量，保证两处读的是同一份列表：
  /// 进度记录会据此判断"这个视频在不在播放列表里"。
  static const String libraryPathsKey = 'savedLibraryPaths';

  /// 播放进度在 `library.json` 里的键。
  static const String _key = 'playbackPositions';

  /// 短于这个长度的视频完全不记进度；0 表示不限制。
  ///
  /// 具体多少由设置页的"短片不记进度"决定（默认 1 分钟）：短片从头再看一遍
  /// 也就分把钟，记住"看到 0:40"反而添乱；而且短片的片尾容差会很怪
  /// （30 秒的片子按 30 秒算，等于一开始就算看完）。
  static Duration get _minVideoDuration =>
      Duration(seconds: resumeMinVideoSeconds.value);

  /// 低于这个位置视为"没真正开始看"，不记录 —— 避免点开瞟一眼就留下续播记录。
  static const Duration minResume = Duration(seconds: 15);

  /// 片尾容差比例：剩这个比例以内视为"看完"。
  static const double tailRatio = 0.1;

  /// 片尾容差上限。
  static const Duration tailCap = Duration(seconds: 30);

  /// 片尾容差 = min(时长 × [tailRatio], [tailCap])。
  ///
  /// 单看比例：两小时的电影剩 10%（12 分钟）就判"看完"，太激进；
  /// 单看固定 30 秒：30 秒的短片等于整片都算片尾，压根没法记。
  /// 取两者较小值 —— 长片按 30 秒，短片按 10%，两种极端都合理。
  static Duration _tailTolerance(Duration duration) {
    final byRatio = Duration(
      milliseconds: (duration.inMilliseconds * tailRatio).round(),
    );
    return byRatio < tailCap ? byRatio : tailCap;
  }

  /// 是否已把 `library.json` 读进内存。
  ///
  /// 只读一次就够了：读写都经过同一个 [AppStore] 单例，内存里的数据始终最新
  ///（首页增删播放列表也写这个单例）。反复 `load()` 重读磁盘没有收益，
  /// 反而可能在列表刚落盘时读到旧内容。
  static bool _loaded = false;

  static Future<void> _ensureLoaded(AppStore store) async {
    if (_loaded) return;
    await store.load();
    _loaded = true;
  }

  /// 读取某视频的续播位置。
  ///
  /// 返回 null 的情形：没有记录、视频不在播放列表、位置太靠前（没看）、
  /// 或已接近片尾（视为看完）。调用方据此决定是否 seek。
  static Future<Duration?> resumePositionOf(String videoPath) async {
    try {
      if (!resumePlaybackEnabled.value) return null;
      final store = AppStore.library;
      await _ensureLoaded(store);
      if (videoPath.isEmpty || !_isInLibrary(store, videoPath)) return null;
      return _resumeFrom(_allRecords(store)[videoPath]);
    } catch (_) {
      return null;
    }
  }

  /// 批量读取多个视频的续播位置，供首页在卡片上显示"已看至 xx:xx"。
  ///
  /// 只包含"值得续播"的条目，判断标准与 [resumePositionOf] 完全一致
  /// （因此卡片上出现"已看至"的视频，点进去就一定会续播）。
  static Future<Map<String, Duration>> resumePositions(
    Iterable<String> videoPaths,
  ) async {
    final result = <String, Duration>{};
    try {
      if (!resumePlaybackEnabled.value) return result;
      final store = AppStore.library;
      await _ensureLoaded(store);
      final records = _allRecords(store);
      for (final path in videoPaths) {
        if (!_isInLibrary(store, path)) continue;
        final resume = _resumeFrom(records[path]);
        if (resume != null) result[path] = resume;
      }
    } catch (_) {}
    return result;
  }

  /// 从一条记录里解析出可用的续播位置（阈值判断集中在这里）。
  /// 视频是否短到不值得记进度（阈值为 0 表示不限制）。
  static bool _tooShortToRemember(Duration duration) {
    final min = _minVideoDuration;
    return min > Duration.zero && duration < min;
  }

  static Duration? _resumeFrom(Map<String, dynamic>? record) {
    if (record == null) return null;
    final ms = (record['ms'] as num?)?.toInt() ?? 0;
    final durationMs = (record['durationMs'] as num?)?.toInt() ?? 0;
    if (ms < minResume.inMilliseconds) return null;
    // 时长未知（0）时不做时长相关判断，避免把记录误判成无效
    if (durationMs > 0) {
      final duration = Duration(milliseconds: durationMs);
      if (_tooShortToRemember(duration)) return null;
      if (duration - Duration(milliseconds: ms) <= _tailTolerance(duration)) {
        return null;
      }
    }
    return Duration(milliseconds: ms);
  }

  /// 记录播放进度。
  ///
  /// [position] 为当前播放位置，[duration] 为视频总时长。
  ///
  /// 两种情况**按兵不动**（既不新建也不清除已有记录）：
  ///  - 位置太靠前（相当于没看）：播放器刚打开、切换片源时位置常是 0，
  ///    这时顺手写入或清除，会把上次的续播点冲掉；
  ///  - 视频不在播放列表里：拖进来的临时文件不记录。
  ///
  /// 只有"确实看完了"（进到片尾容差之内）才清除记录，让下次从头播。
  /// 想主动从头播且不留记录，走 [clear]。
  static Future<void> record(
    String videoPath, {
    required Duration position,
    required Duration duration,
  }) async {
    try {
      if (videoPath.isEmpty) return;
      // 续播关掉后不再写盘：已有记录保留着，重新打开开关即可接着用
      if (!resumePlaybackEnabled.value) return;
      final store = AppStore.library;
      await _ensureLoaded(store);
      if (!_isInLibrary(store, videoPath)) return;

      // 短片不记续播；旧版本留下的记录也顺手清掉
      if (_tooShortToRemember(duration)) {
        await _removeRecord(store, videoPath);
        return;
      }
      if (position < minResume) return;

      final finished =
          duration > Duration.zero &&
          duration - position <= _tailTolerance(duration);
      if (finished) {
        await _removeRecord(store, videoPath);
        return;
      }

      final all = _allRecords(store);
      all[videoPath] = {
        'ms': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'at': DateTime.now().millisecondsSinceEpoch,
      };
      // 顺手清掉已不在播放列表里的记录：视频被移除后进度已无用途，
      // 留着只会让 library.json 越积越大（用户不会注意到这类残留）。
      all.removeWhere((path, _) => !_isInLibrary(store, path));
      await store.setMap(_key, all);
    } catch (_) {
      // 记录失败不影响播放
    }
  }

  /// 清除某视频的播放进度（"从头播放"、或视频被移出播放列表时调用）。
  static Future<void> clear(String videoPath) async {
    try {
      if (videoPath.isEmpty) return;
      final store = AppStore.library;
      await _ensureLoaded(store);
      await _removeRecord(store, videoPath);
    } catch (_) {}
  }

  /// 视频是否在播放列表里。
  static bool _isInLibrary(AppStore store, String videoPath) {
    final paths = store.getStringList(libraryPathsKey);
    return paths != null && paths.contains(videoPath);
  }

  /// 读取全部进度记录（只保留结构正确的条目，坏数据不至于把功能带崩）。
  static Map<String, Map<String, dynamic>> _allRecords(AppStore store) {
    final raw = store.getMap(_key);
    if (raw == null) return <String, Map<String, dynamic>>{};
    final result = <String, Map<String, dynamic>>{};
    raw.forEach((path, value) {
      if (value is Map) result[path] = Map<String, dynamic>.from(value);
    });
    return result;
  }

  static Future<void> _removeRecord(AppStore store, String videoPath) async {
    final all = _allRecords(store);
    if (all.remove(videoPath) == null) return;
    await store.setMap(_key, all);
  }
}
