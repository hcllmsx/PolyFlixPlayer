/// 应用本地数据存储：`%LOCALAPPDATA%\PolyFlixPlayer\*.json`。
///
/// 为什么不用 `shared_preferences`：
///  - 它在 Windows 上落在 `%APPDATA%\<CompanyName>\<ProductName>\shared_preferences.json`，
///    路径由 exe 的版本信息（`windows/runner/Runner.rc` 里的 CompanyName / ProductName）
///    决定，一旦改名，用户的设置和播放列表就会"凭空重置"；
///  - 改用我们自己的目录后，配置、播放列表与模型、引擎、任务记录集中在同一个文件夹，
///    备份、排查、清理都直观。
///
/// 注意：本次切换**不做旧数据迁移**——老用户的设置回到默认值、播放列表清空（有意为之）。
library;

import 'dart:convert';
import 'dart:io';

import '../utils/native_file_helper.dart';

/// 极简 JSON 键值存储（一个实例对应一个文件）。
///
/// 数据量小、改动不频繁，所以每次写入直接同步落盘，不做防抖/批处理。
class AppStore {
  AppStore._(this._fileName);

  /// 应用设置：`settings.json`。
  static final AppStore instance = AppStore._('settings.json');

  /// 媒体库（播放列表）：`library.json`。
  ///
  /// 与设置分成两个文件：播放列表属于用户数据（可能想单独备份/清理），
  /// 而且它万一写坏也不应该连累设置。
  static final AppStore library = AppStore._('library.json');

  final String _fileName;

  static final JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  Map<String, dynamic> _data = {};
  bool _loaded = false;

  /// 存储文件路径，桌面端为 `%LOCALAPPDATA%\PolyFlixPlayer\<文件名>`。
  ///
  /// Android 上 [NativeFileHelper.desktopDataDir] 会退到临时目录（系统可能清理），
  /// 功能可用；将来正式支持 Android 时再换成应用私有 files 目录。
  File _file() {
    final dir = NativeFileHelper.desktopDataDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 读取磁盘内容（整体替换内存数据），应在使用前调用。
  Future<void> load() async {
    var data = <String, dynamic>{};
    try {
      final file = _file();
      if (file.existsSync()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) data = decoded;
      }
    } catch (_) {
      // 文件损坏时按空配置处理，保证应用能正常启动
    }
    _data = data;
    _loaded = true;
  }

  /// 写入前确保已经载入过磁盘内容，否则会把其它键覆盖掉。
  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  bool getBool(String key, bool fallback) =>
      _data[key] is bool ? _data[key] as bool : fallback;

  int getInt(String key, int fallback) =>
      _data[key] is int ? _data[key] as int : fallback;

  String? getString(String key) =>
      _data[key] is String ? _data[key] as String : null;

  List<String>? getStringList(String key) {
    final value = _data[key];
    if (value is List) {
      return value.whereType<String>().toList();
    }
    return null;
  }

  /// 读取一层 JSON 对象（如播放进度记录：路径 → 进度对象）。
  ///
  /// 嵌套的值保持原样返回，调用方自行按需取用；类型不符时返回 null。
  Map<String, dynamic>? getMap(String key) {
    final value = _data[key];
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  Future<void> setBool(String key, bool value) => _write(key, value);

  Future<void> setInt(String key, int value) => _write(key, value);

  Future<void> setString(String key, String value) => _write(key, value);

  Future<void> setStringList(String key, List<String> value) =>
      _write(key, List<String>.from(value));

  Future<void> setMap(String key, Map<String, Object?> value) =>
      _write(key, value);

  /// 写内存 + 落盘。缩进 JSON：文件很小，方便用户直接查看甚至手改。
  Future<void> _write(String key, Object? value) async {
    await _ensureLoaded();
    _data[key] = value;
    try {
      await _file().writeAsString(_encoder.convert(_data));
    } catch (_) {
      // 落盘失败不影响本次生效
    }
  }
}
