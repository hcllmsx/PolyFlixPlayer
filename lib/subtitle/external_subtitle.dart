/// 外挂字幕加载器（用户手动选择 / 同目录同名自动匹配）。
///
/// 两条渲染路径，与播放页既有的"内嵌字幕交 mpv、AI 字幕走叠层"约定保持一致：
///
///  - **纯文本字幕**（`.srt` / `.vtt`）：解析成 [SubtitleEntry] 交给 Flutter 叠层渲染，
///    主/副两条通道都能用，可以和 AI 字幕并排显示。
///  - **特效字幕**（`.ass` / `.ssa`）：默认整份交给底层 mpv 原生渲染（libass），
///    样式、字体、定位、动画全部保真；代价是只能独占画面，不能与 AI 字幕并排。
///    需要并排时可以切到"纯文本模式"，走上面那条路（样式丢失）。
///  - **图形字幕**（`.sup` / `.idx` / `.sub`，即 PGS、VobSub 这类位图字幕）：
///    同样是整份交给 mpv 原生渲染，但没有"转文本"这条路（位图抽不出文字），
///    所以只能独占画面。VobSub 请选 `.idx`（`.sub` 只是它的数据文件）。
///
/// 编码处理：先按严格 UTF-8（含 BOM）解码，失败再让 ffmpeg 分别按
/// GB18030 / BIG5 转成 UTF-8（中文外挂字幕的两种主流老编码），
/// 最后用"常用字命中数"给各次结果打分，取分最高的那份，避免把 Big5 的字节流
/// 按 GB18030 解出一堆貌似合法的错字。
///
/// 转码产物缓存在临时缓存目录里（缓存名含源文件大小与修改时间），
/// 同一个字幕文件只转一次；"清理缓存"会把它一并清掉，不占持久空间。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:media_kit/media_kit.dart';

import '../utils/native_file_helper.dart';
import 'subtitle_generator.dart';
import 'translation/srt_parser.dart';

/// 支持的外挂字幕扩展名（小写，不含点）。
///
/// - 文本类：`srt` / `vtt`
/// - 特效类：`ass` / `ssa`
/// - 图形类：`sup`（蓝光 PGS）/ `idx`（VobSub 索引，配合同名 `.sub`）
///   / `sub`（VobSub 数据，也可能是 MicroDVD 文本，统一按 mpv 原生渲染处理）
const Set<String> kExternalSubtitleExtensions = {
  'srt',
  'ass',
  'ssa',
  'vtt',
  'sup',
  'idx',
  'sub',
};

/// 外挂字幕的渲染类别。
enum ExternalSubtitleKind {
  /// 纯文本：解析成条目走叠层渲染，可与 AI 字幕并排。
  text,

  /// 特效：默认交底层 mpv 原生渲染，保真但独占画面；可切成纯文本模式。
  effects,

  /// 图形位图（PGS / VobSub）：只能交 mpv 原生渲染，也没有"转文本"这条路。
  graphics,
}

/// 交给 mpv 的外挂字幕轨标题前缀。
///
/// mpv 会把 `sub-add` 的标题参数回填到 `track-list`，而 media_kit 不区分内嵌/外挂，
/// 会把外挂轨一并报进 `stream.tracks.subtitle`。用这个前缀把"我们自己加的外挂轨"
/// 认出来，免得它混进"内置字幕"列表里、把下标串掉。
const String kExternalSubtitleTrackPrefix = '外挂·';

/// 外挂字幕加载失败（面向用户的可读原因）。
class ExternalSubtitleException implements Exception {
  const ExternalSubtitleException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract final class ExternalSubtitleLoader {
  const ExternalSubtitleLoader._();

  // ──────────────────────────── 基本信息 ────────────────────────────

  /// 取扩展名（小写，不含点）；没有扩展名时返回 null。
  static String? extensionOf(String path) {
    final name = fileNameOf(path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  /// 是否为受支持的外挂字幕文件。
  static bool isSupported(String path) {
    final ext = extensionOf(path);
    return ext != null && kExternalSubtitleExtensions.contains(ext);
  }

  /// 该文件的渲染类别。
  ///
  /// `.ass`/`.ssa` 是特效字幕；`.sup`/`.idx`/`.sub` 是图形位图字幕；
  /// 其余（`.srt`/`.vtt`）按纯文本处理。
  static ExternalSubtitleKind kindOf(String path) {
    final ext = extensionOf(path);
    if (ext == 'ass' || ext == 'ssa') return ExternalSubtitleKind.effects;
    if (ext == 'sup' || ext == 'idx' || ext == 'sub') {
      return ExternalSubtitleKind.graphics;
    }
    return ExternalSubtitleKind.text;
  }

  /// 文件名（用于 UI 显示与轨道标题）。
  static String fileNameOf(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  /// 文件是否存在（恢复"上次用过的外挂字幕"时先筛一遍，避免加载时再报错）。
  static Future<bool> exists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// 交给 mpv 时使用的轨道标题（同时也是"这是外挂轨"的标记）。
  static String trackTitleFor(String path) =>
      '$kExternalSubtitleTrackPrefix${fileNameOf(path)}';

  /// 该 mpv 字幕轨是否是我们自己加进去的外挂轨。
  static bool isExternalTrack(SubtitleTrack track) =>
      (track.title ?? '').startsWith(kExternalSubtitleTrackPrefix);

  // ──────────────────────────── 读取条目 ────────────────────────────

  /// 读取外挂字幕的文本条目（丢弃样式）。
  ///
  /// [offset] 为时间轴偏移，正数表示整批字幕延后出现。
  static Future<List<SubtitleEntry>> loadEntries(
    String path, {
    Duration offset = Duration.zero,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const ExternalSubtitleException('字幕文件不存在或已被移动');
    }

    // 1. 快路径：UTF-8 的 .srt 直接本地解析，不外呼 ffmpeg（瞬时完成）。
    //    .vtt 不走这条：它的时间戳尾随 `align:middle` 之类的设置，交给 ffmpeg 更稳。
    if (extensionOf(path) == 'srt') {
      final text = _tryDecodeUtf8(await file.readAsBytes());
      if (text != null) {
        final entries = _clean(SrtParser.parse(text));
        if (entries.isNotEmpty) return applyOffset(entries, offset);
      }
    }

    // 2. 其余情况（.ass/.ssa、.vtt、非 UTF-8 编码，或快路径没解析出内容）
    //    统一让 ffmpeg 转成 SRT 文本再解析，顺带把编码问题一并解决。
    final srt = await _toSrtText(path);
    final entries = _clean(SrtParser.parse(srt));
    if (entries.isEmpty) {
      throw const ExternalSubtitleException('未能从该字幕文件中解析出有效的时间轴内容');
    }
    return applyOffset(entries, offset);
  }

  /// 给整批条目统一加时间轴偏移（正数 = 字幕整体延后）。
  static List<SubtitleEntry> applyOffset(
    List<SubtitleEntry> entries,
    Duration offset,
  ) {
    if (offset == Duration.zero) {
      return List<SubtitleEntry>.unmodifiable(entries);
    }
    return entries.map((e) {
      var start = e.start + offset;
      var end = e.end + offset;
      if (start.isNegative) start = Duration.zero;
      if (end.isNegative) end = Duration.zero;
      return SubtitleEntry(
        start: start,
        end: end,
        text: e.text,
        translatedText: e.translatedText,
      );
    }).toList(growable: false);
  }

  // ──────────────────────────── mpv 原生路径 ────────────────────────────

  /// VobSub 的索引是 `.idx`、数据在 `.sub`，mpv 需要的是 `.idx`。
  ///
  /// 用户（或同名匹配）递过来的是 `.sub` 时，同目录存在同名 `.idx` 就换成它；
  /// 否则原样返回（那时它多半是 MicroDVD 文本字幕，mpv 一样能渲染）。
  static Future<String> resolveCompanion(String path) async {
    if (extensionOf(path) != 'sub') return path;
    try {
      final name = fileNameOf(path);
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      final parent = File(path).parent.path;
      final idxPath = '$parent${Platform.pathSeparator}$base.idx';
      if (await File(idxPath).exists()) return idxPath;
    } catch (_) {}
    return path;
  }

  /// 返回一份"mpv 能正确解码"的字幕文件路径。
  ///
  /// 已是 UTF-8 时原样返回（0 开销）；否则用 ffmpeg 转出 UTF-8 副本，
  /// 避免 mpv/libass 把 GBK 字节流渲染成乱码。
  /// 图形位图字幕（`.sup`/`.idx`/`.sub`）是二进制，直接原样返回。
  static Future<String> ensureMpvReadable(String path) async {
    try {
      if (kindOf(path) != ExternalSubtitleKind.effects) return path;
      if (_tryDecodeUtf8(await File(path).readAsBytes()) != null) return path;
      final converted = await _convertToUtf8(
        input: path,
        outputFormat: 'ass',
        outputExtension: 'ass',
      );
      return converted ?? path;
    } catch (_) {
      return path;
    }
  }

  /// 交给 mpv 时依次尝试的地址写法。
  ///
  /// Windows 上补一个 `\\?\` 长路径写法：视频本身就是走 media_kit 的这个形式
  /// 打开并正常播放的，中文 / 超长路径下裸路径偶尔开不出来。
  static List<String> uriCandidates(String path) {
    final list = <String>[path];
    if (Platform.isWindows && !path.startsWith(r'\\?\')) {
      list.add('\\\\?\\${path.replaceAll('/', '\\')}');
    }
    return list;
  }

  // ──────────────────────────── 同目录同名匹配 ────────────────────────────

  /// 扫描视频同目录下的"同名外挂字幕"。
  ///
  /// `movie.mp4` 会匹配 `movie.srt`、`movie.zh-cn.ass`、`movie_chs.srt`；
  /// PFLX 产物（`movie.pflx`）额外匹配 `movie.pflx.srt` 这种带全名的写法。
  /// 只在视频所在目录里找一次，不递归；最多返回 [limit] 份，越接近正名越靠前。
  static Future<List<String>> findSiblingSubtitles(
    String videoPath, {
    int limit = 3,
  }) async {
    try {
      final videoFile = File(videoPath);
      final dir = videoFile.parent;
      if (!dir.existsSync()) return const [];

      final name = fileNameOf(videoPath).toLowerCase();
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;

      final matches = <({int rank, String path})>[];
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final lower = fileNameOf(entity.path).toLowerCase();
        final extDot = lower.lastIndexOf('.');
        if (extDot <= 0) continue;
        if (!kExternalSubtitleExtensions
            .contains(lower.substring(extDot + 1))) {
          continue;
        }
        final stem = lower.substring(0, extDot);

        int? rank;
        if (stem == base) {
          rank = 0; // movie.mp4 → movie.srt
        } else if (stem == name) {
          rank = 1; // movie.pflx → movie.pflx.srt
        } else if (stem.startsWith('$base.') ||
            stem.startsWith('${base}_') ||
            stem.startsWith('$base-')) {
          rank = 2; // movie.zh-cn.srt / movie_chs.ass
        } else if (stem.startsWith('$name.') || stem.startsWith('${name}_')) {
          rank = 3;
        }
        if (rank == null) continue;
        matches.add((rank: rank, path: entity.path));
      }

      matches.sort((a, b) {
        final byRank = a.rank.compareTo(b.rank);
        if (byRank != 0) return byRank;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      return matches.take(limit).map((m) => m.path).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  // ──────────────────────────── 内部实现 ────────────────────────────

  /// 依次尝试的字符集（null 表示让 ffmpeg 自己判断）。
  ///
  /// 先显式按 GB18030（GB2312/GBK 的超集，覆盖绝大多数简体中文老字幕）解码，
  /// 再按 BIG5 解一次，两个都不像话才交给 ffmpeg 自己猜（UTF-16 BOM 等）。
  /// 到底用哪一份由 [_scoreCommonChinese] 的打分决定。
  static const List<String?> _kCharsets = <String?>['GB18030', 'BIG5', null];

  /// 常用汉字（简繁混排），用于判断"这次解码像不像正常中文"。
  static const String _kCommonChinese =
      '的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得于着下自之年过发后作'
      '里用道行所然家种事成方多经么去法学如都同现当没动面起看定天分还进好小部其些主样理心她本前开但因只从'
      '想实日军者意无力它与长把机十民第公此已工使情明性知全三又关点正业外将两高间由问很最重并物手应战向'
      '头文体政美相见被利什二等产或新己制身果加西斯月话合回特代内信表化老给世位次度门任常先海通教儿原东'
      '声提立及比员解水名真论处走义各入几口认条平系气题活尔更别打女变四神总何电数安少报才结反受目太量再'
      '感建务做接必场件计管期市直德资命山金指克许统区保至队形社便空决治展马科司五基眼书非则听白却界达光'
      '放强即像难且权思王象完设式色路记南品住告类求据程北边死张该交规万取拉格望觉术领共确传师观清今切院'
      '让识候带导争运笑飞风步改收根干造言联持组每济车亲极林服快办议往元英士证近失转夫令准布始怎呢存未远'
      '叫台单影具罗字爱击流备兵连调深商算质团集百需价花党华城石级整府离况亚请技际约示复病息究线似官火断'
      '精满支视消越器容照须九增研写称企八功吗包片史委乎查轻易早曾除农找装广显'
      '這們說對時為開關個國會來後長門間與學實點還樣種經現當沒動麵點頭風飛馬鳥魚車東馬龍萬與書寫讀';

  /// 常用字的码点集合（用 Set 判命中，避免每字符都做一次子串扫描）。
  static final Set<int> _kCommonChineseCodes = _kCommonChinese.runes.toSet();

  /// 严格 UTF-8 解码（兼容 BOM）；失败返回 null。
  static String? _tryDecodeUtf8(List<int> bytes) {
    var data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }
    try {
      return utf8.decode(data);
    } catch (_) {
      return null;
    }
  }

  /// 剥掉 ASS 覆盖标签（`{\an8}` / `{\pos(..)}`）、常见 HTML 标签（`<i>` 等），
  /// 并把 ASS 的硬换行 `\N` 还原成正常换行。
  static String _stripTags(String text) {
    var t = text.replaceAll(RegExp(r'\{[^}]*\}'), '');
    t = t.replaceAll(RegExp(r'<[^<>]{1,32}>'), '');
    t = t.replaceAll(RegExp(r'\\[Nn]'), '\n');
    t = t
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    return t.trim();
  }

  /// 清洗条目：剥标签、丢空条目、修掉零长度时间轴，并按开始时间排序。
  ///
  /// 排序是必须的：叠层用二分查找定位"当前时刻该显示哪条"，列表乱序会直接漏显示。
  static List<SubtitleEntry> _clean(List<SubtitleEntry> raw) {
    final result = <SubtitleEntry>[];
    for (final e in raw) {
      final text = _stripTags(e.text);
      if (text.isEmpty) continue;
      final end = e.end > e.start ? e.end : e.start + const Duration(seconds: 1);
      result.add(SubtitleEntry(
        start: e.start,
        end: end,
        text: text,
        translatedText: e.translatedText,
      ));
    }
    result.sort((a, b) => a.start.compareTo(b.start));
    return result;
  }

  /// 用"常用汉字命中数"给解码结果打分。
  ///
  /// Big5 的字节流按 GB18030 解码同样会得到一串合法汉字（只是全是错字），
  /// ffmpeg 的返回码区分不了；而正确解码的字幕里常用字密度会明显更高，
  /// 用它当判据既便宜又可靠。
  static int _scoreCommonChinese(String text) {
    // 只扫前面一段：字幕正文就在开头，没必要整篇遍历。
    final limit = text.length > 20000 ? 20000 : text.length;
    var score = 0;
    for (var i = 0; i < limit; i++) {
      if (_kCommonChineseCodes.contains(text.codeUnitAt(i))) score++;
    }
    return score;
  }

  /// 转码产物缓存目录：%TEMP%\PolyFlixPlayer\external_sub\（清理缓存会一并删除）。
  static Directory _tempDir() {
    final sep = Platform.pathSeparator;
    return Directory(
      '${NativeFileHelper.desktopCacheDir().path}${sep}external_sub',
    );
  }

  /// 转码产物的缓存路径：源路径 + 大小 + 修改时间一起入哈希，源文件一变就重转。
  static String _cacheFileFor(File source, String extension) {
    final stat = source.statSync();
    final seed =
        '${source.path}#${stat.size}#${stat.modified.millisecondsSinceEpoch}';
    final hash = md5.convert(utf8.encode(seed)).toString().substring(0, 12);
    return '${_tempDir().path}${Platform.pathSeparator}$hash.$extension';
  }

  /// 把外挂字幕转成 UTF-8 的 SRT 文本（带缓存）。
  static Future<String> _toSrtText(String path) async {
    final cachedPath = _cacheFileFor(File(path), 'srt');
    final cachedFile = File(cachedPath);
    if (await cachedFile.exists()) {
      final text = await cachedFile.readAsString();
      if (text.trim().isNotEmpty) return text;
    }
    final output = await _convertToUtf8(
      input: path,
      outputFormat: 'srt',
      outputExtension: 'srt',
    );
    if (output == null) {
      throw const ExternalSubtitleException('字幕文件无法解析（格式或编码不受支持）');
    }
    return File(output).readAsString();
  }

  /// 依次按 [_kCharsets] 转码，返回得分最高那份的缓存路径；全部失败返回 null。
  static Future<String?> _convertToUtf8({
    required String input,
    required String outputFormat,
    required String outputExtension,
  }) async {
    final source = File(input);
    final dir = _tempDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final cachePath = _cacheFileFor(source, outputExtension);
    final probe = File(
      '${dir.path}${Platform.pathSeparator}'
      'probe_${md5.convert(utf8.encode(input)).toString().substring(0, 8)}'
      '.$outputExtension',
    );

    String? bestText;
    var bestScore = -1;

    for (final charset in _kCharsets) {
      try {
        if (await probe.exists()) await probe.delete();
        final session = await FFmpegKit.executeWithArguments([
          '-y',
          if (charset != null) ...['-sub_charenc', charset],
          '-i',
          input,
          '-f',
          outputFormat,
          probe.path,
        ]);
        if (!ReturnCode.isSuccess(await session.getReturnCode())) continue;
        if (!await probe.exists() || await probe.length() == 0) continue;

        final text = await probe.readAsString();
        if (text.trim().isEmpty) continue;

        final score = _scoreCommonChinese(text);
        if (score > bestScore) {
          bestScore = score;
          bestText = text;
        }
        // 常用字命中已经足够多，说明这次解码是对的，不必再试其它字符集
        if (score >= 8) break;
      } catch (_) {
        continue;
      }
    }

    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {}

    if (bestText == null) return null;
    try {
      await File(cachePath).writeAsString(bestText, flush: true);
      return cachePath;
    } catch (_) {
      return null;
    }
  }
}
