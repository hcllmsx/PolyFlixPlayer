/// 播放页：基于 media_kit 的沉浸式播放器，提供播放、快进、进度拖动与倍速控制。
///
/// 移动端与桌面端的差异集中在这几处：
/// - 移动端用 SystemChrome 做沉浸式全屏、屏幕方向旋转，并靠点击画面显隐控件；
///   桌面端没有这些概念，改为鼠标移动显隐 + 键盘快捷键，控制条常驻。
/// - 桌面端去掉画面中央的大号播放/进退按钮，改为底部控制条上的音量、
///   音轨、字幕按钮，并提供拖放换片。
/// - 音轨/字幕的选择入口两端不同：桌面端用控制条上的弹出菜单，移动端
///   用控制条按钮唤起底部弹窗（与倍速选择同一套交互）。
/// 核心播放逻辑（media_kit、PFLX 流式播放、进度/倍速）两端完全共用。
library;

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../pflx/pflx.dart';
import '../pflx/pflx_stream_server.dart';
import '../settings/app_settings.dart';
import '../subtitle/ai_subtitle_sheet.dart';
import '../subtitle/subtitle_generator.dart';
import '../subtitle/subtitle_overlay.dart';
import '../utils/platform_utils.dart';

/// 桌面端单次调节音量的步进值（键盘 ↑/↓）。
const double _kVolumeStep = 5;

/// 桌面端键盘快进/快退的秒数（←/→），与界面按钮的 ±10s 保持一致。
const int _kSeekStepSeconds = 10;

/// 字幕菜单里"关闭字幕"项的哨兵值（不会与真实轨道 id 冲突）。
const String _kSubtitlesOff = '__off__';

/// "窗口适应视频比例"使用的基准客户区尺寸（逻辑像素）。
///
/// 用它而不是"当前窗口尺寸"作为计算基准：否则每次打开视频都只会在上一次的
/// 结果上继续收缩（竖屏把窗口变窄 → 再开 16:9 只会更小），窗口只会越来越小。
/// 固定基准同时也保证了换算结果不会超过默认窗口大小、不会跑出屏幕。
const Size _kFitBaseClientSize = Size(1280, 720);

/// 播放页是否按视频比例调整过窗口尺寸（进程内状态，不做持久化）。
///
/// 首页在播放页返回后据此判断是否需要还原窗口。之所以把"还原"交给首页来做：
/// 改变窗口尺寸会让 Flutter 引擎重新布局并重绘，如果放在播放页的退出流程里做，
/// 这次重绘可能落在 media_kit 渲染纹理已经释放之后，会直接崩掉整个进程
/// （表现为点退出后应用闪退）。等回到首页、播放器彻底销毁后再改就安全了。
bool windowFitAppliedInPlayer = false;

/// 支持拖入播放的视频扩展名。
const Set<String> _kSupportedVideoExtensions = {
  'mp4', 'mkv', 'mov', 'avi', 'flv', 'wmv', 'webm', 'ts', 'm4v',
  '3gp', 'rmvb', 'f4v', 'mpg', 'mpeg', 'vob', 'ogv', 'm2ts', 'mts',
  'divx', 'asf', 'rm', 'dat', 'h264', 'h265', 'hevc',
};

bool _isVideoPath(String path) {
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex >= path.length - 1) return false;
  final ext = path.substring(dotIndex + 1).toLowerCase();
  return _kSupportedVideoExtensions.contains(ext);
}

String _fileNameOf(String path) => path.replaceAll('\\', '/').split('/').last;

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.sourcePath,
    this.info,
    required this.isPflx,
  });

  final String sourcePath;
  final PflxInfo? info;
  final bool isPflx;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  PflxStreamServer? _streamServer;

  /// 当前播放源。拖入新文件后会变，因此不能一直读 widget.sourcePath。
  late String _sourcePath;
  PflxInfo? _sourceInfo;
  bool _sourceIsPflx = false;

  bool _ready = false;
  bool _controlsVisible = true;
  bool _playing = false;
  bool _scrubbing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _scrubPosition = Duration.zero;
  double _speed = 1.0;
  Timer? _hideTimer;
  bool _isLandscape = false;

  /// 可切换的轨道列表与当前选中的轨道（由 media_kit 的流驱动）。
  Tracks _tracks = const Tracks();
  Track _currentTrack = const Track();

  /// 当前播放源是否已执行过"打开后自动加载字幕"。
  /// 每次切换播放源都要重置，否则新视频不会自动加载字幕。
  bool _autoSubtitleApplied = false;

  /// 当前播放源是否已按视频比例调整过窗口。
  /// 每次切换播放源重置；同一次播放内只调一次，避免覆盖用户手动改动的窗口尺寸。
  bool _windowFitApplied = false;

  /// 正在退出播放页，防止退出流程被重复触发。
  bool _closing = false;

  // ---------------- AI 字幕状态 ----------------
  /// AI 字幕是否正在显示。
  bool _aiSubtitleActive = false;

  /// AI 字幕是否正在运行 ASR 识别。
  bool _aiSubtitleRunning = false;

  /// ASR 进度与状态监听器。
  StreamSubscription<AsrProgress>? _asrProgressSub;

  // ---------------- 桌面端专用状态 ----------------
  /// 当前音量（0~100）。移动端音量交给系统管理，桌面端由滑块/键盘调节。
  double _volume = 100;

  /// 静音前的音量，用于取消静音时恢复。
  double _volumeBeforeMute = 100;

  bool _muted = false;

  /// 操作反馈浮层文案（音量/静音/切轨等瞬时提示），null 表示不显示。
  String? _osdText;
  Timer? _osdTimer;

  /// 是否有文件正被拖到画面上方。
  bool _dropActive = false;

  /// 正在切换播放源（拖放换片），用于避免并发切换。
  bool _switchingSource = false;

  /// 鼠标活动时间戳，用于节流 onHover —— 鼠标每移动一像素都触发 setState
  /// 会造成大量无谓重建，这里限制最短间隔。
  DateTime _lastPointerActivity = DateTime.fromMillisecondsSinceEpoch(0);

  /// 键盘事件接收节点。配合 ExcludeFocus 保证焦点不会跑到按钮上。
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'player');

  @override
  void initState() {
    super.initState();
    _sourcePath = widget.sourcePath;
    _sourceInfo = widget.info;
    _sourceIsPflx = widget.isPflx;
    // SystemChrome 只在移动端有意义；桌面端调用是空操作，直接跳过更清晰。
    if (isMobilePlatform) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ));
    }
    _aiSubtitleRunning = SubtitleGenerator.instance.isRunning;
    _asrProgressSub = SubtitleGenerator.instance.progressStream.listen((p) {
      if (!mounted) return;
      setState(() {
        _aiSubtitleRunning = SubtitleGenerator.instance.isRunning;
        if (p.state == AsrState.completed) {
          _aiSubtitleActive = true;
          _showOsd('AI 字幕识别完成 (共 ${SubtitleGenerator.instance.entries.length} 条)');
        } else if (p.state == AsrState.error) {
          _showOsd(p.message ?? 'AI 语音识别失败');
        }
      });
    });
    _initPlayer();
  }

  @override
  void dispose() {
    _asrProgressSub?.cancel();
    _cancelAutoHide();
    _osdTimer?.cancel();
    _keyboardFocus.dispose();
    if (isMobilePlatform) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ));
    }
    // 不在这里同步销毁 player 和 streamServer：_closePlayer 已先暂停播放
    // 并停止了 streamServer。底层资源（mpv 纹理）延迟释放，确保 Flutter
    // 渲染管线完成当前帧的合成、不再引用该纹理后才真正回收。
    final player = _player;
    final server = _streamServer;
    Future.delayed(const Duration(milliseconds: 150), () {
      try { server?.stop(); } catch (_) {}
      try { player.dispose(); } catch (_) {}
    });
    super.dispose();
  }

  Future<void> _toggleOrientation() async {
    // 屏幕方向是移动端概念，桌面端窗口没有"竖屏/横屏"之分。
    if (!isMobilePlatform) return;
    setState(() => _isLandscape = !_isLandscape);
    if (_isLandscape) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    _scheduleAutoHide();
  }

  Future<void> _initPlayer() async {
    _player = Player();
    _controller = VideoController(_player);

    _player.stream.playing.listen((value) {
      if (mounted) {
        setState(() => _playing = value);
        if (value) {
          _scheduleAutoHide();
        } else {
          _cancelAutoHide();
        }
      }
    });
    _player.stream.position.listen((value) {
      if (mounted && !_scrubbing) setState(() => _position = value);
    });
    _player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    // 音量双向同步：滑块调节 / 系统变化都反映到本地状态。
    _player.stream.volume.listen((value) {
      if (mounted) setState(() => _volume = value);
    });
    // 轨道列表与当前轨道由播放器驱动，供音轨/字幕菜单使用。
    _player.stream.tracks.listen((value) {
      if (!mounted) return;
      setState(() => _tracks = value);
      // 轨道信息到位后，主动把字幕真正加载上（见方法内注释）。
      _maybeAutoSelectSubtitle();
    });
    // 视频尺寸到位后，按设置把窗口调成视频比例。
    _player.stream.width.listen((_) => _maybeFitWindowToVideo());
    _player.stream.height.listen((_) => _maybeFitWindowToVideo());
    _player.stream.track.listen((value) {
      if (mounted) setState(() => _currentTrack = value);
    });

    await _openSource(_sourcePath, _sourceIsPflx ? _sourceInfo : null);

    if (!mounted) return;
    setState(() => _ready = true);
    _scheduleAutoHide();
  }

  /// 打开播放源：PFLX 产物走本地 HTTP Range 流（不落盘），普通文件直接播放。
  Future<void> _openSource(String path, PflxInfo? info) async {
    _autoSubtitleApplied = false;
    _windowFitApplied = false;
    await _streamServer?.stop();
    _streamServer = null;
    if (info != null) {
      _streamServer = await PflxStreamServer.start(path, info);
      await _player.open(Media(_streamServer!.url));
    } else {
      await _player.open(Media(path));
    }
  }

  /// 拖放换片：识别新文件并直接切换播放，不离开播放页。
  Future<void> _handleDroppedFile(String path) async {
    if (_switchingSource) return;
    final name = _fileNameOf(path);
    if (!_isVideoPath(path)) {
      _showOsd('不是视频文件：$name');
      return;
    }
    setState(() {
      _switchingSource = true;
      _dropActive = false;
    });
    try {
      final info = scan(path);
      final isPflx = info != null &&
          info['payload_offset'] + info['payload_len'] <= info['file_size'];
      await _openSource(path, isPflx ? info : null);
      if (!mounted) return;
      setState(() {
        _sourcePath = path;
        _sourceInfo = isPflx ? info : null;
        _sourceIsPflx = isPflx;
        _position = Duration.zero;
        _duration = Duration.zero;
        _controlsVisible = true;
      });
      // open() 会重置播放速率，这里恢复用户此前选择的倍速。
      await _player.setRate(_speed);
      _showOsd(isPflx ? '已切换到隐藏视频：$name' : '已切换到 $name');
    } catch (_) {
      if (mounted) _showOsd('打开失败：$name');
    } finally {
      if (mounted) setState(() => _switchingSource = false);
    }
  }

  void _scheduleAutoHide() {
    // 桌面端控制条常驻，不自动隐藏（与常见桌面播放器一致）。
    if (isDesktopPlatform) return;
    _cancelAutoHide();
    if (!_playing || !_controlsVisible || _scrubbing) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && _controlsVisible && !_scrubbing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _cancelAutoHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (_controlsVisible) {
        _scheduleAutoHide();
      } else {
        _cancelAutoHide();
      }
    });
  }

  Future<void> _togglePlayback() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    final max = _duration == Duration.zero ? target : _duration;
    await _player.seek(_clampDuration(target, Duration.zero, max));
    if (mounted) {
      setState(() => _controlsVisible = true);
      _scheduleAutoHide();
    }
  }

  void _onScrubStart(double value) {
    _cancelAutoHide();
    setState(() {
      _scrubbing = true;
      _scrubPosition = _fromMilliseconds(value);
      _controlsVisible = true;
    });
  }

  void _onScrubUpdate(double value) {
    setState(() => _scrubPosition = _fromMilliseconds(value));
  }

  Future<void> _onScrubEnd(double value) async {
    final target = _fromMilliseconds(value);
    await _player.seek(target);
    if (!mounted) return;
    setState(() {
      _scrubbing = false;
      _position = target;
    });
    _scheduleAutoHide();
  }

  Duration _fromMilliseconds(double value) =>
      Duration(milliseconds: value.round().clamp(0, _duration.inMilliseconds));

  Future<void> _setSpeed(double speed) async {
    await _player.setRate(speed);
    if (mounted) {
      setState(() => _speed = speed);
      _scheduleAutoHide();
    }
  }

  // ------------------------------------------------------------ 轨道切换

  /// 真实可切换的音轨（过滤掉 media_kit 的 auto / no 伪轨道）。
  List<AudioTrack> get _audioTracks => _tracks.audio
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList(growable: false);

  /// 真实可切换的字幕轨。
  List<SubtitleTrack> get _subtitleTracks => _tracks.subtitle
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList(growable: false);

  /// 当前实际在播放的音轨 id。
  ///
  /// media_kit 只在"用户手动切换过"时才会把 state.track.audio 更新为真实轨道
  /// id（setAudioTrack 会写 aid 并同步 state）；自动选择时它一直停留在 'auto'，
  /// 于是界面上一项都打不上勾——哪怕整个视频只有一条音轨。
  /// 这里把 'auto' 还原成 mpv 实际选中的那条：优先带 default 标记的，否则第一条。
  String? get _activeAudioId {
    final current = _currentTrack.audio.id;
    if (current == 'no') return null;
    if (current != 'auto') return current;
    final tracks = _audioTracks;
    if (tracks.isEmpty) return null;
    for (final t in tracks) {
      if (t.isDefault == true) return t.id;
    }
    return tracks.first.id;
  }

  /// 当前实际在显示的字幕轨 id；返回 null 表示"没有字幕在显示"。
  ///
  /// 与音轨同理：'auto' 时 mpv 只挑带 default 标记的字幕轨，都没有就不显示字幕。
  String? get _activeSubtitleId {
    final current = _currentTrack.subtitle.id;
    if (current == 'no') return null;
    if (current != 'auto') return current;
    for (final t in _subtitleTracks) {
      if (t.isDefault == true) return t.id;
    }
    return null;
  }

  /// 当前是否存在"翻译字幕"。
  ///
  /// 预留位：翻译功能上线后改为真实状态即可，主/副槽位的取舍逻辑无需改动。
  bool get _hasTranslation => false;

  /// 主字幕来源优先级：翻译字幕 > 内置字幕 > AI 识别字幕。
  ///
  /// AI 字幕只有在"没有翻译字幕、也没有内置字幕在显示"时才升为主字幕；
  /// 否则一律作为副字幕，与内置字幕同时显示（内置在下、AI 在上）。
  bool get _aiIsPrimary =>
      _aiSubtitleActive && _activeSubtitleId == null && !_hasTranslation;

  /// AI 字幕叠层的底部间距：作副字幕时抬到内置字幕上方，避免两行字叠在一起。
  double get _aiOverlayBottom => _aiIsPrimary ? 80 : 132;

  /// 拼出便于识别的轨道描述：标题 · [语言] · 编码。
  String _trackLabel({
    required String id,
    String? title,
    String? language,
    String? codec,
  }) {
    final parts = <String>[];
    if (title != null && title.isNotEmpty) parts.add(title);
    if (language != null && language.isNotEmpty) parts.add('[$language]');
    if (codec != null && codec.isNotEmpty) parts.add(codec);
    return parts.isEmpty ? '轨道 $id' : parts.join(' · ');
  }

  String _audioLabel(AudioTrack t) => _trackLabel(
        id: t.id,
        title: t.title,
        language: t.language,
        codec: t.codec,
      );

  String _subtitleLabel(SubtitleTrack t) => _trackLabel(
        id: t.id,
        title: t.title,
        language: t.language,
        codec: t.codec,
      );

  Future<void> _selectAudio(String id) async {
    final track = _audioTracks.where((t) => t.id == id).firstOrNull;
    if (track == null) return;
    await _player.setAudioTrack(track);
    _showOsd('音轨：${_audioLabel(track)}');
  }

  /// 选择字幕。
  ///
  /// 内置字幕轨与 AI 字幕分属"主/副"两个槽位，互不顶掉：
  /// 选内置轨只换主字幕，AI 副字幕保持原状；开关 AI 也不会关掉内置字幕。
  /// 只有"关闭字幕"会把两个槽位一起清空。
  Future<void> _selectSubtitle(String id) async {
    if (id == _kSubtitlesOff) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      if (_aiSubtitleActive) {
        setState(() => _aiSubtitleActive = false);
      }
      _showOsd('字幕已关闭');
      return;
    }
    if (id == '__ai_subtitle__') {
      if (SubtitleGenerator.instance.entries.isNotEmpty) {
        // 已有识别结果时按开关处理：再点一次即关闭这条副/主字幕
        setState(() => _aiSubtitleActive = !_aiSubtitleActive);
        final role = _hasTranslation
            ? '副字幕'
            : (_activeSubtitleId == null ? '主字幕' : '副字幕');
        _showOsd(_aiSubtitleActive
            ? '$role：AI 语音识别字幕'
            : '已关闭$role：AI 语音识别字幕');
      } else {
        await _showAiSubtitleSheet();
      }
      return;
    }
    final track = _subtitleTracks.where((t) => t.id == id).firstOrNull;
    if (track == null) return;
    // 不动 _aiSubtitleActive：内置字幕与 AI 字幕可以同时显示
    await _player.setSubtitleTrack(track);
    _showOsd(_aiSubtitleActive
        ? '主字幕：${_subtitleLabel(track)}（AI 副字幕同时显示）'
        : '主字幕：${_subtitleLabel(track)}');
  }

  /// 打开视频后主动选中一条字幕，让它真正显示出来。
  ///
  /// 不能只依赖 mpv 的自动选择：media_kit 只在调用 setSubtitleTrack 时才把
  /// state.track 同步成真实轨道 id，而 mpv 的 sid 停留在 'auto' 时并不会把
  /// 字幕真正送进渲染管线 —— 表现就是菜单里看着勾上了字幕，画面却一条都不显示，
  /// 必须手动再点一次才出来。这里显式选一次即可：优先带 default 标记的字幕轨，
  /// 没有则用第一条。每个播放源只执行一次（由 _autoSubtitleApplied 控制）。
  Future<void> _maybeAutoSelectSubtitle() async {
    if (_autoSubtitleApplied) return;
    final tracks = _subtitleTracks;
    if (tracks.isEmpty) return;
    _autoSubtitleApplied = true;
    final target = tracks.firstWhere(
      (t) => t.isDefault == true,
      orElse: () => tracks.first,
    );
    await _player.setSubtitleTrack(target);
    if (mounted) _showOsd('主字幕：${_subtitleLabel(target)}');
  }

  /// 退出播放页。
  ///
  /// 这里只负责离开，不做窗口还原：改窗口尺寸会让引擎重新布局重绘，在播放器
  /// 正在销毁的过程中做这件事会崩进程。窗口还原交给首页在返回后处理
  /// （见 windowFitAppliedInPlayer）。
  ///
  /// 退出前先暂停播放并停止流服务，再等一帧让渲染管线安全拆除纹理层，
  /// 然后才执行 pop。否则 dispose 释放 mpv 纹理时渲染管线可能还在引用
  /// 它，导致原生层 use-after-free 崩溃（竖版视频因窗口尺寸变化几乎必现）。
  Future<void> _closePlayer() async {
    if (_closing) return;
    _closing = true;
    // 1. 暂停播放，停止 mpv 的解码/渲染循环。
    try {
      await _player.pause();
    } catch (_) {}
    // 2. 提前停止流式服务（如有），减少 dispose 中的工作量。
    try {
      _streamServer?.stop();
      _streamServer = null;
    } catch (_) {}
    // 3. 等一帧，让 Flutter 渲染管线完成当前帧的合成，
    //    之后的帧就不会再引用播放器纹理了。
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    // 4. 现在安全 pop。
    Navigator.of(context).pop();
  }

  /// 按设置把窗口调整为视频画面比例（仅桌面端）。
  ///
  /// windowManager 的尺寸是**整个窗口**（原生用 GetWindowRect 取值，含标题栏与
  /// 边框），而要对齐的是**客户区**（也就是画面区）。两者的差值就是标题栏 +
  /// 边框的占用，用「窗口尺寸 − MediaQuery 客户区尺寸」实时算出来再换算，
  /// 这样在任意 DPI 缩放下都准确，也不用硬编码标题栏高度。
  ///
  /// 只缩不放：当目标比当前更大时保持原样，避免窗口被撑出屏幕。
  Future<void> _maybeFitWindowToVideo() async {
    if (!isDesktopPlatform) return;
    if (!mounted) return;
    if (!fitWindowToVideo.value) return;
    if (_windowFitApplied) return;

    final videoWidth = _player.state.width;
    final videoHeight = _player.state.height;
    if (videoWidth == null || videoHeight == null) return;
    if (videoWidth <= 0 || videoHeight <= 0) return;

    final client = MediaQuery.of(context).size;
    if (client.width <= 0 || client.height <= 0) return;

    final Size windowSize;
    try {
      windowSize = await windowManager.getSize();
    } catch (_) {
      return;
    }
    if (!mounted) return;

    final chromeWidth = windowSize.width - client.width;
    final chromeHeight = windowSize.height - client.height;

    final videoAspect = videoWidth / videoHeight;
    final baseAspect = _kFitBaseClientSize.width / _kFitBaseClientSize.height;

    double targetClientWidth;
    double targetClientHeight;
    if (videoAspect >= baseAspect) {
      // 视频比基准更宽：以基准宽度为准，压缩高度。
      targetClientWidth = _kFitBaseClientSize.width;
      targetClientHeight = _kFitBaseClientSize.width / videoAspect;
    } else {
      // 视频更方（含竖屏）：以基准高度为准，收窄宽度。
      targetClientHeight = _kFitBaseClientSize.height;
      targetClientWidth = _kFitBaseClientSize.height * videoAspect;
    }

    _windowFitApplied = true;
    // 通知首页：返回后需要把窗口还原（见 windowFitAppliedInPlayer 注释）。
    windowFitAppliedInPlayer = true;
    try {
      await windowManager.setSize(Size(
        targetClientWidth + chromeWidth,
        targetClientHeight + chromeHeight,
      ));
    } catch (_) {
      // 调整失败不影响播放。
    }
  }

  // ------------------------------------------------------------ 桌面端交互

  /// 鼠标在画面上活动：显示控件并重置自动隐藏计时。
  ///
  /// 带 250ms 节流——onHover 在鼠标移动时触发极其频繁，无节流会导致
  /// 移动鼠标时疯狂重建整棵组件树。
  void _onPointerActivity() {
    final now = DateTime.now();
    if (now.difference(_lastPointerActivity).inMilliseconds < 250) return;
    _lastPointerActivity = now;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleAutoHide();
  }

  /// 在画面右上角弹出一条瞬时提示（音量/静音/切轨反馈）。
  void _showOsd(String text) {
    _osdTimer?.cancel();
    setState(() => _osdText = text);
    _osdTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _osdText = null);
    });
  }

  Future<void> _changeVolume(double delta) async {
    final next = (_volume + delta).clamp(0.0, 100.0);
    if (next == _volume && !_muted) {
      // 已到边界：仍给一次反馈，避免用户以为按键没生效。
      _showOsd('音量 ${next.round()}%');
      return;
    }
    _muted = false;
    await _player.setVolume(next);
    if (mounted) {
      setState(() => _volume = next);
      _showOsd('音量 ${next.round()}%');
    }
  }

  Future<void> _toggleMute() async {
    if (_muted) {
      _muted = false;
      await _player.setVolume(_volumeBeforeMute);
      if (mounted) {
        setState(() => _volume = _volumeBeforeMute);
        _showOsd('已取消静音');
      }
    } else {
      _volumeBeforeMute = _volume;
      _muted = true;
      await _player.setVolume(0);
      if (mounted) {
        setState(() => _volume = 0);
        _showOsd('已静音');
      }
    }
  }

  /// 桌面端键盘快捷键（对齐桌面播放器通用习惯）。
  ///
  /// 空格=播放/暂停，←/→=±10s，↑/↓=音量，M=静音，Esc=退出播放。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final isRepeat = event is KeyRepeatEvent;
    if (event is! KeyDownEvent && !isRepeat) {
      return KeyEventResult.ignored;
    }
    // 带 Ctrl/Alt/Win 的组合键交还给系统，避免抢占系统快捷键。
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // 空格只在首次按下响应：长按若走 KeyRepeat 会反复切换暂停/播放。
    if (key == LogicalKeyboardKey.space) {
      if (!isRepeat) _togglePlayback();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(-_kSeekStepSeconds);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekRelative(_kSeekStepSeconds);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _changeVolume(_kVolumeStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _changeVolume(-_kVolumeStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      if (!isRepeat) _toggleMute();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (!isRepeat) _closePlayer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String get _title {
    if (!_sourceIsPflx) return _fileNameOf(_sourcePath);
    final name = _sourceInfo?['name'] as String?;
    return (name == null || name.isEmpty) ? '隐藏视频' : name;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, _) {},
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _ready
            ? _buildPlayer()
            : const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
      ),
    );
  }

  Widget _buildPlayer() {
    final currentPosition = _scrubbing ? _scrubPosition : _position;
    final content = Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: Video(controller: _controller, controls: NoVideoControls),
        ),
        // AI 字幕叠加层（独立于内置字幕，可同时显示）
        if (_aiSubtitleActive)
          SubtitleOverlay(
            generator: SubtitleGenerator.instance,
            position: currentPosition,
            visible: true,
            // 主字幕在下（贴近画面底部），副字幕抬到内置字幕上方，避免叠字
            isPrimary: _aiIsPrimary,
            bottomOffset: _aiOverlayBottom,
          ),
        _PlayerScrim(showControls: _controlsVisible),
        _PlayerTopBar(
          visible: _controlsVisible,
          title: _title,
          isPflx: _sourceIsPflx,
          closeIcon: Icons.arrow_back_rounded,
          onClose: _closePlayer,
        ),
        // 画面中央的大号播放/进退按钮只服务触屏；桌面端点底部控制条即可。
        if (!isDesktopPlatform)
          Center(
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _CenterControls(
                  playing: _playing,
                  onReplay: () => _seekRelative(-_kSeekStepSeconds),
                  onPlayPause: _togglePlayback,
                  onForward: () => _seekRelative(_kSeekStepSeconds),
                ),
              ),
            ),
          ),
        _PlayerBottomControls(
          visible: _controlsVisible,
          playing: _playing,
          isLandscape: _isLandscape,
          showOrientationToggle: isMobilePlatform,
          position: currentPosition,
          duration: _duration,
          speed: _speed,
          desktopControls: isDesktopPlatform ? _buildDesktopTrackControls() : null,
          mobileTrackControls:
              isMobilePlatform ? _buildMobileTrackControls() : null,
          onPlayPause: _togglePlayback,
          onSpeedTap: () => _showSpeedSheet(),
          onToggleOrientation: _toggleOrientation,
          onScrubStart: _onScrubStart,
          onScrubUpdate: _onScrubUpdate,
          onScrubEnd: _onScrubEnd,
        ),
        if (_switchingSource)
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
        if (_osdText != null) _PlayerOsd(text: _osdText!),
      ],
    );

    final player = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: isDesktopPlatform
          ? Focus(
              focusNode: _keyboardFocus,
              autofocus: true,
              onKeyEvent: _onKeyEvent,
              // ExcludeFocus 把控制条整体排除出焦点树：否则点击按钮后焦点
              // 落在按钮上，空格会被按钮当成"激活"吃掉，导致空格无法暂停。
              // （桌面版 Qt 实现同样遇到过该问题，那里用事件过滤器解决。）
              child: ExcludeFocus(
                child: MouseRegion(
                  cursor: _controlsVisible
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.none,
                  onHover: (_) => _onPointerActivity(),
                  child: content,
                ),
              ),
            )
          : content,
    );

    if (!isDesktopPlatform) return player;

    // 桌面端支持把另一个视频拖进画面直接换片。
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropActive = true),
      onDragExited: (_) => setState(() => _dropActive = false),
      onDragDone: (details) {
        setState(() => _dropActive = false);
        final paths = details.files
            .map((f) => f.path)
            .where((p) => p.isNotEmpty)
            .toList();
        if (paths.isNotEmpty) _handleDroppedFile(paths.first);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          player,
          if (_dropActive) const _PlayerDropHint(),
        ],
      ),
    );
  }

  /// 移动端控制条右侧附加区：音轨 + 字幕两个入口，唤起底部弹窗。
  ///
  /// 移动端没有鼠标悬停，PopupMenuButton 在触屏上的命中区域与观感都不理想，
  /// 所以不复用桌面端的弹出菜单，改走与倍速一致的 bottom sheet。
  Widget _buildMobileTrackControls() {
    final audioTracks = _audioTracks;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: audioTracks.isEmpty ? null : _showAudioSheet,
          tooltip: audioTracks.isEmpty ? '该视频没有可选音轨' : '音轨',
          icon: Icon(
            Icons.graphic_eq_rounded,
            color: audioTracks.isEmpty
                ? Colors.white.withValues(alpha: .35)
                : Colors.white,
          ),
        ),
        IconButton(
          onPressed: _showSubtitleSheet,
          tooltip: '字幕',
          icon: const Icon(Icons.subtitles_outlined, color: Colors.white),
        ),
        // AI 字幕按钮（常驻可见，点击弹出控制面板）
        IconButton(
          onPressed: _showAiSubtitleSheet,
          tooltip: 'AI 语音识别字幕',
          icon: _aiSubtitleRunning
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                )
              : Icon(
                  Icons.auto_awesome_rounded,
                  color: _aiSubtitleActive
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                ),
        ),
      ],
    );
  }

  /// 底部弹窗：选择音轨。返回选中的轨道 id，取消返回 null。
  Future<void> _showAudioSheet() async {
    setState(() => _controlsVisible = true);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF202027),
      showDragHandle: true,
      builder: (context) => _TrackSelectionSheet(
        title: '音轨',
        subtitle: '选择要使用的音频轨道。',
        options: [
          for (final t in _audioTracks)
            _TrackOption(
              id: t.id,
              label: _audioLabel(t),
              selected: t.id == _activeAudioId,
            ),
        ],
      ),
    );
    if (selected != null) await _selectAudio(selected);
  }

  /// 底部弹窗：选择字幕（顶部固定有"关闭字幕"项）。返回轨道 id，取消返回 null。
  Future<void> _showSubtitleSheet() async {
    setState(() => _controlsVisible = true);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF202027),
      showDragHandle: true,
      builder: (context) => _TrackSelectionSheet(
        title: '字幕',
        subtitle: '内置字幕与 AI 识别字幕可同时显示（内置在下，AI 在上）。',
        options: [
          _TrackOption(
            id: _kSubtitlesOff,
            label: '关闭字幕',
            selected: _activeSubtitleId == null && !_aiSubtitleActive,
          ),
          for (final t in _subtitleTracks)
            _TrackOption(
              id: t.id,
              label: _subtitleLabel(t),
              // 内置轨是主字幕槽位，勾选状态不受 AI 副字幕影响
              selected: t.id == _activeSubtitleId,
            ),
          _TrackOption(
            id: '__ai_subtitle__',
            label: _aiSubtitleRunning
                ? 'AI 语音识别字幕 (识别中…)'
                : (_aiIsPrimary
                    ? 'AI 语音识别字幕（主字幕）'
                    : 'AI 语音识别字幕（副字幕）'),
            selected: _aiSubtitleActive,
          ),
        ],
        footerNote:
            _subtitleTracks.isEmpty ? '该视频没有内嵌字幕（可直接选择 AI 语音识别字幕）' : null,
      ),
    );
    if (selected != null) {
      await _selectSubtitle(selected);
    }
  }

  /// 桌面端控制条右侧附加区：音量滑块 + 音轨 + 字幕。
  Widget _buildDesktopTrackControls() {
    final audioTracks = _audioTracks;
    final subtitleTracks = _subtitleTracks;
    final muted = _muted || _volume == 0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: _toggleMute,
          tooltip: muted ? '取消静音' : '静音（M）',
          icon: Icon(
            muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            color: Colors.white,
          ),
        ),
        SizedBox(
          width: 92,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: .28),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: .14),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: _volume.clamp(0, 100),
              max: 100,
              onChanged: (v) {
                _player.setVolume(v);
                setState(() {
                  _volume = v;
                  if (v > 0) _muted = false;
                });
              },
              onChangeEnd: (v) => _showOsd('音量 ${v.round()}%'),
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: audioTracks.isEmpty ? '该视频没有可选音轨' : '音轨',
          enabled: audioTracks.isNotEmpty,
          icon: Icon(
            Icons.graphic_eq_rounded,
            color: audioTracks.isEmpty
                ? Colors.white.withValues(alpha: .35)
                : Colors.white,
          ),
          onSelected: _selectAudio,
          itemBuilder: (context) => [
            for (final t in audioTracks)
              _trackMenuItem(
                value: t.id,
                label: _audioLabel(t),
                selected: t.id == _activeAudioId,
              ),
          ],
        ),
        PopupMenuButton<String>(
          tooltip: '字幕',
          icon: const Icon(Icons.subtitles_outlined, color: Colors.white),
          onSelected: _selectSubtitle,
          itemBuilder: (context) => [
            _trackMenuItem(
              value: _kSubtitlesOff,
              label: '关闭字幕',
              selected: _activeSubtitleId == null && !_aiSubtitleActive,
            ),
            if (subtitleTracks.isEmpty)
              _infoMenuItem('该视频没有内嵌字幕')
            else ...[
              const PopupMenuDivider(),
              for (final t in subtitleTracks)
                _trackMenuItem(
                  value: t.id,
                  label: _subtitleLabel(t),
                  // 内置轨是主字幕槽位，勾选状态不受 AI 副字幕影响
                  selected: t.id == _activeSubtitleId,
                ),
            ],
            // AI 语音识别字幕：副字幕槽位（没有内置字幕在显示时升为主字幕）
            const PopupMenuDivider(),
            _trackMenuItem(
              value: '__ai_subtitle__',
              label: _aiSubtitleRunning
                  ? 'AI 语音识别字幕 (识别中…)'
                  : (_aiIsPrimary
                      ? 'AI 语音识别字幕（主字幕）'
                      : 'AI 语音识别字幕（副字幕）'),
              selected: _aiSubtitleActive,
            ),
          ],
        ),
        // 桌面端独立的 AI 语音字幕快捷按钮（点击弹出控制面板）
        IconButton(
          onPressed: _showAiSubtitleSheet,
          tooltip: 'AI 语音识别字幕',
          icon: _aiSubtitleRunning
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                )
              : Icon(
                  Icons.auto_awesome_rounded,
                  color: _aiSubtitleActive
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                ),
        ),
      ],
    );
  }

  /// 统一风格的轨道菜单项。
  ///
  /// 不用 CheckedPopupMenuItem：它内部包的是 ListTile，文字走 bodyLarge
  /// （16px / 字重 400），而 PopupMenuItem 走 labelLarge（14px / 字重 500）。
  /// 两者放进同一个菜单就会出现"一大一小、一粗一细"。这里统一成同一种项：
  /// 固定宽度的勾选位 + 一致的字号字重。
  PopupMenuItem<String> _trackMenuItem({
    required String value,
    required String label,
    required bool selected,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: selected
                ? Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
          ),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  /// 不可选的说明项（如"该视频没有内嵌字幕"）。
  ///
  /// 字号字重与 [_trackMenuItem] 完全一致，只把颜色调淡，表达"这里只是说明、
  /// 不是可选项"，避免看起来像换了一种字体。
  PopupMenuItem<String> _infoMenuItem(String label) {
    return PopupMenuItem<String>(
      enabled: false,
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 26),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                // 用主题的禁用色（Material 对"不可点项"的标准淡色），
                // 比 onSurfaceVariant 更浅，保持它是"说明文字"的观感。
                color: Theme.of(context).disabledColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showSpeedSheet() async {
    setState(() => _controlsVisible = true);
    final speed = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF202027),
      showDragHandle: true,
      builder: (context) => _SpeedSheet(current: _speed),
    );
    if (speed != null) await _setSpeed(speed);
  }

  // ------------------------------------------------------------ AI 字幕

  /// 打开 AI 语音识别字幕设置与控制面板。
  Future<void> _showAiSubtitleSheet() async {
    setState(() => _controlsVisible = true);
    await AiSubtitleSheet.show(
      context: context,
      videoPath: _streamServer?.url ?? _sourcePath,
      videoTitle: _title,
      isAiSubtitleActive: _aiSubtitleActive,
      onToggleSubtitleActive: (active) {
        setState(() => _aiSubtitleActive = active);
      },
      onSeekTo: (position) {
        _player.seek(position);
      },
    );
  }
}

/// 拖拽换片时的提示遮罩。
class _PlayerDropHint extends StatelessWidget {
  const _PlayerDropHint();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: .72),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.play_circle_outline_rounded,
              size: 72,
              color: Colors.white,
            ),
            SizedBox(height: 16),
            Text(
              '松开即可播放这个视频',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 画面右上角的瞬时提示浮层（音量/静音/切轨反馈）。
class _PlayerOsd extends StatelessWidget {
  const _PlayerOsd({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topRight,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 16, 0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .72),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
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

class _PlayerScrim extends StatelessWidget {
  const _PlayerScrim({required this.showControls});

  final bool showControls;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: showControls ? 1 : 0,
        child: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Colors.transparent, Color(0x99000000)],
              stops: [0, .46, 1],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerTopBar extends StatelessWidget {
  const _PlayerTopBar({
    required this.visible,
    required this.title,
    required this.isPflx,
    required this.closeIcon,
    required this.onClose,
  });

  final bool visible;
  final String title;
  final bool isPflx;
  final IconData closeIcon;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        bottom: false,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, -1.2),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: IgnorePointer(
              ignoring: !visible,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 10),
                child: Row(
                  children: [
                    _RoundControl(
                      tooltip: '返回',
                      icon: closeIcon,
                      onPressed: onClose,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isPflx ? Icons.auto_awesome_rounded : Icons.movie_outlined,
                                color: const Color(0xFFD5D1FF),
                                size: 13,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isPflx ? 'PFLX 隐藏视频' : '本地视频',
                                style: const TextStyle(color: Color(0xFFD5D1FF), fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 44,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .16),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: size * .54),
          ),
        ),
      ),
    );
  }
}

class _CenterControls extends StatelessWidget {
  const _CenterControls({
    required this.playing,
    required this.onReplay,
    required this.onPlayPause,
    required this.onForward,
  });

  final bool playing;
  final VoidCallback onReplay;
  final VoidCallback onPlayPause;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundControl(
          tooltip: '后退 $_kSeekStepSeconds 秒',
          icon: Icons.replay_10_rounded,
          onPressed: onReplay,
          size: 54,
        ),
        const SizedBox(width: 22),
        Tooltip(
          message: playing ? '暂停' : '播放',
          child: Material(
            color: Colors.white,
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: .55),
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onPlayPause,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 74,
                height: 74,
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: const Color(0xFF252432),
                  size: 42,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 22),
        _RoundControl(
          tooltip: '前进 $_kSeekStepSeconds 秒',
          icon: Icons.forward_10_rounded,
          onPressed: onForward,
          size: 54,
        ),
      ],
    );
  }
}

class _PlayerBottomControls extends StatelessWidget {
  const _PlayerBottomControls({
    required this.visible,
    required this.playing,
    required this.isLandscape,
    required this.showOrientationToggle,
    required this.position,
    required this.duration,
    required this.speed,
    required this.onPlayPause,
    required this.onSpeedTap,
    required this.onToggleOrientation,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    this.desktopControls,
    this.mobileTrackControls,
  });

  final bool visible;
  final bool playing;
  final bool isLandscape;
  final bool showOrientationToggle;
  final Duration position;
  final Duration duration;
  final double speed;
  final VoidCallback onPlayPause;
  final VoidCallback onSpeedTap;
  final VoidCallback onToggleOrientation;
  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrubUpdate;
  final ValueChanged<double> onScrubEnd;

  /// 桌面端附加控件（音量/音轨/字幕），移动端为 null。
  final Widget? desktopControls;

  /// 移动端附加控件（音轨/字幕入口），桌面端为 null。
  final Widget? mobileTrackControls;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds.toDouble();
    final current = position.inMilliseconds.toDouble().clamp(0.0, total <= 0 ? 1.0 : total);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 1.25),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: IgnorePointer(
              ignoring: !visible,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white.withValues(alpha: .28),
                        thumbColor: Colors.white,
                        overlayColor: Colors.white.withValues(alpha: .14),
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                      ),
                      child: Slider(
                        value: current,
                        min: 0,
                        max: total <= 0 ? 1 : total,
                        onChangeStart: onScrubStart,
                        onChanged: onScrubUpdate,
                        onChangeEnd: onScrubEnd,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        IconButton(
                          onPressed: onPlayPause,
                          tooltip: playing ? '暂停' : '播放',
                          icon: Icon(
                            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          _formatDuration(position),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          ' / ${_formatDuration(duration)}',
                          style: const TextStyle(
                            color: Color(0xFFCAC7D0),
                            fontSize: 13,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const Spacer(),
                        ?desktopControls,
                        ?mobileTrackControls,
                        TextButton(
                          onPressed: onSpeedTap,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.white.withValues(alpha: .16),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            '${speed.toStringAsFixed(speed % 1 == 0 ? 0 : 2)}x',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (showOrientationToggle) ...[
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: onToggleOrientation,
                            tooltip: isLandscape ? '切换竖屏' : '切换横屏',
                            icon: Icon(
                              isLandscape
                                  ? Icons.screen_lock_portrait_rounded
                                  : Icons.screen_rotation_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeedSheet extends StatelessWidget {
  const _SpeedSheet({required this.current});

  final double current;
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '播放速度',
              style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              '选择适合当前视频的播放节奏。',
              style: TextStyle(color: Color(0xFFCBC7D2)),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _speeds.map((speed) {
                final selected = (speed - current).abs() < .001;
                return _SpeedOption(
                  label: '${speed.toStringAsFixed(speed % 1 == 0 ? 0 : 2)}x',
                  selected: selected,
                  onTap: () => Navigator.of(context).pop(speed),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 倍速档位按钮（自绘）。
///
/// 不用 Material 的 [ChoiceChip]：M3 下它由 ChipThemeData/_ChoiceChipDefaultsM3
/// 提供一层 outline 描边，描边与填充色的解析链路较长（side → shape.side →
/// chipDefaults.side），实测传 `side: BorderSide.none` 也无法可靠去掉，在深色
/// 面板上会留一圈突兀的框。这里用纯色圆角块 + InkWell 自己画，外观完全可控，
/// 也避免受主题变更影响。
class _SpeedOption extends StatelessWidget {
  const _SpeedOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFC4BEFF) : const Color(0xFF302F39),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 76,
          height: 40,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? const Color(0xFF29245A) : Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部弹窗里的一个轨道选项。
class _TrackOption {
  const _TrackOption({
    required this.id,
    required this.label,
    required this.selected,
  });

  final String id;
  final String label;
  final bool selected;
}

/// 音轨/字幕选择的底部弹窗（移动端）。
///
/// 视觉与 [_SpeedSheet] 保持同一套：深色面板、标题 + 说明、内容项自绘。
/// 选中项用强调色高亮并带勾选标记，与桌面端弹出菜单的勾选语义一致。
class _TrackSelectionSheet extends StatelessWidget {
  const _TrackSelectionSheet({
    required this.title,
    required this.subtitle,
    required this.options,
    this.footerNote,
  });

  final String title;
  final String subtitle;
  final List<_TrackOption> options;

  /// 底部的灰色说明文字（如"该视频没有内嵌字幕"），null 表示不显示。
  final String? footerNote;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Color(0xFFCBC7D2)),
            ),
            const SizedBox(height: 8),
            for (final option in options)
              _TrackOptionTile(
                option: option,
                onTap: () => Navigator.of(context).pop(option.id),
              ),
            if (footerNote != null) ...[
              const SizedBox(height: 4),
              Text(
                footerNote!,
                style: const TextStyle(color: Color(0xFF8D8A96), fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 音轨/字幕弹窗里的单行选项。
class _TrackOptionTile extends StatelessWidget {
  const _TrackOptionTile({required this.option, required this.onTap});

  final _TrackOption option;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = option.selected;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            // 与桌面端 _trackMenuItem 相同的固定宽度勾选位，保证列表左对齐。
            SizedBox(
              width: 26,
              child: selected
                  ? const Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: Color(0xFFC4BEFF),
                    )
                  : null,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? const Color(0xFFC4BEFF) : Colors.white,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Duration _clampDuration(Duration value, Duration minimum, Duration maximum) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${duration.inMinutes}:${seconds.toString().padLeft(2, '0')}';
}
