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

import '../main.dart';
import '../pflx/pflx.dart';
import '../pflx/pflx_stream_server.dart';
import '../settings/app_settings.dart';
import '../settings/playback_progress.dart';
import '../subtitle/ai_subtitle_sheet.dart';
import '../subtitle/ai_task_manager.dart';
import '../subtitle/model_manager.dart';
import '../subtitle/subtitle_generator.dart';
import '../subtitle/subtitle_overlay.dart';
import '../subtitle/translation/builtin_subtitle_extractor.dart';
import '../subtitle/translation/translation_service.dart';
import '../utils/platform_media_helper.dart';
import '../utils/platform_utils.dart';

/// 移动端手势调节类型（左侧亮度，右侧音量）。
enum _VerticalDragType { brightness, volume }

/// 桌面端单次调节音量的步进值（键盘 ↑/↓）。
const double _kVolumeStep = 5;

/// 桌面端键盘快进/快退的秒数（←/→），与界面按钮的 ±10s 保持一致。
const int _kSeekStepSeconds = 10;

/// 桌面端控制条隐藏后，鼠标需要移动这么多逻辑像素才会重新唤出。
///
/// 原先是任何 1 像素的 hover 就立刻弹出来 —— 手搭在鼠标上、桌面轻微震动都会
/// 把控制条和光标"晃"出来，看片时很打断。改成以「隐藏那一刻的光标位置」为基准，
/// 移动超过这个距离才算一次有意的动作（缓慢移动同样会累积距离）。
///
/// 取 100 而不是更小的值：点画面隐藏控制条时，手在点完之后往往还有一个自然的
/// 收尾动作，光标会跟着挪一截，阈值太小就会出现"刚点了隐藏、立刻又弹回来"。
const double _kPointerWakeDistance = 100;

/// 播放进度落盘步长：位置每前进 5 秒写一次。
///
/// 不按每个 position 事件写（大约 4 次/秒），也不必攒到退出才写 ——
/// 进程被强杀时最多丢 5 秒进度，而写的是 1KB 左右的 JSON，代价可以忽略。
const Duration _kProgressSaveStep = Duration(seconds: 5);

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
  'mp4',
  'mkv',
  'mov',
  'avi',
  'flv',
  'wmv',
  'webm',
  'ts',
  'm4v',
  '3gp',
  'rmvb',
  'f4v',
  'mpg',
  'mpeg',
  'vob',
  'ogv',
  'm2ts',
  'mts',
  'divx',
  'asf',
  'rm',
  'dat',
  'h264',
  'h265',
  'hevc',
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
    this.initialNotice,
  });

  final String sourcePath;
  final PflxInfo? info;
  final bool isPflx;
  final String? initialNotice;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WindowListener {
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

  // ---------------- 主/副字幕状态 ----------------
  /// 当前主字幕源 ID（'none', 'ai_translation', 'ai_original', 'builtin_0', ...）。
  String _primarySubId = 'none';

  /// 当前副字幕源 ID（'none', 'ai_translation', 'ai_original', 'builtin_0', ...）。
  String _secondarySubId = 'none';

  /// 内置字幕文本解析缓存（以字幕轨序号为 key）。
  final Map<int, List<SubtitleEntry>> _builtinTracksCache = {};


  /// AI 字幕是否正在显示（主或副选了 AI 字幕）。
  bool _aiSubtitleActive = false;

  /// AI 字幕是否正在运行 ASR 识别。
  bool _aiSubtitleRunning = false;

  /// ASR 进度与状态监听器。
  StreamSubscription<AsrProgress>? _asrProgressSub;

  /// 当前播放源是否已经检查过"本地有没有 AI 字幕缓存"。
  /// 每次切换播放源都要重置，否则新视频不会自动恢复字幕。
  bool _aiCacheChecked = false;

  /// 恢复 AI 字幕的延时器。
  ///
  /// 轨道列表与时长是两个独立事件，谁先谁后不确定，而"有没有内嵌字幕"直接
  /// 决定 AI 字幕要不要自动显示。所以收到任一信号都重新计时，等 500ms 内
  /// 不再有新信号（说明 mpv 已把轨道报全）才真正做判断。
  Timer? _aiRestoreDebounce;

  /// 当前播放源的时长是否已读到。
  ///
  /// 不能直接看 [_duration]：换片时它还留着上一个视频的值，会让"轨道是否
  /// 已报全"的判断提前通过。
  bool _durationKnown = false;

  // ---------------- 桌面端专用状态 ----------------
  /// 当前音量（0~100）。移动端音量交给系统管理，桌面端由滑块/键盘调节。
  double _volume = 100;

  /// 静音前的音量，用于取消静音时恢复。
  double _volumeBeforeMute = 100;

  bool _muted = false;

  /// 操作反馈浮层文案（音量/静音/切轨等瞬时提示），null 表示不显示。
  String? _osdText;
  IconData? _osdIcon;
  Timer? _osdTimer;

  // ---------------- 移动端手势调节亮度与音量 ----------------
  /// 当前屏幕亮度（0.01 ~ 1.0）。进入时为系统亮度。
  double _brightness = 0.5;

  /// 本次进入播放页期间是否通过手势调整过亮度。
  bool _brightnessModified = false;

  /// 垂直手势调节目标（左侧亮度，右侧音量）。
  _VerticalDragType? _dragType;
  double _dragStartY = 0.0;
  double _dragStartValue = 0.0;

  /// 水平手势调节播放进度（快进/快退）。
  bool _horizontalDragging = false;
  double _dragStartX = 0.0;
  Duration _seekDragStartPosition = Duration.zero;
  Duration _seekDragTargetPosition = Duration.zero;

  // ---------------- 播放进度（续播） ----------------
  /// 读到续播位置后暂存，等媒体加载完再 seek（此时 seek 才生效）。
  Duration? _pendingResume;

  /// 上次已落盘的播放位置，用于按 [_kProgressSaveStep] 节流写盘。
  Duration _lastRecordedPosition = Duration.zero;

  /// 是否在进度条上方浮出"从头播放"按钮（续播后短暂出现）。
  bool _showRestartButton = false;
  Timer? _restartHintTimer;

  /// 是否有文件正被拖到画面上方。
  bool _dropActive = false;

  /// 正在切换播放源（拖放换片），用于避免并发切换。
  bool _switchingSource = false;

  /// 鼠标活动时间戳，用于节流 onHover —— 鼠标每移动一像素都触发 setState
  /// 会造成大量无谓重建，这里限制最短间隔。
  DateTime _lastPointerActivity = DateTime.fromMillisecondsSinceEpoch(0);

  /// 最近一次鼠标位置（全局逻辑坐标），每次 hover 都更新。
  Offset? _lastPointerPos;

  /// 控制条隐藏那一刻的光标位置，作为"移动了多远"的判断基准。
  Offset? _pointerAnchor;

  /// 上一次点画面的时间与位置，用于识别双击（桌面端双击 = 全屏切换）。
  ///
  /// 自己判断而不是用 `GestureDetector.onDoubleTap`：那个会让单击回调先等
  /// 300ms（等着看有没有第二击），"点一下画面藏控制条"会明显变迟钝。
  DateTime? _lastSurfaceTapAt;
  Offset? _lastSurfaceTapPos;

  /// 是否处于全屏（仅桌面端，跟随窗口状态同步）。
  bool _isFullScreen = false;

  /// 键盘事件接收节点。配合 ExcludeFocus 保证焦点不会跑到按钮上。
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'player');

  /// 顶部标题栏下方的临时轻量提示（如"已添加 1 个视频"），几秒后自动淡出
  String? _noticeText;
  Timer? _noticeTimer;

  @override
  void initState() {
    super.initState();
    _noticeText = widget.initialNotice;
    if (_noticeText != null) {
      _noticeTimer = Timer(const Duration(milliseconds: 2600), () {
        if (mounted) setState(() => _noticeText = null);
      });
    }
    _sourcePath = widget.sourcePath;
    _sourceInfo = widget.info;
    _sourceIsPflx = widget.isPflx;
    // SystemChrome 只在移动端有意义；桌面端调用是空操作，直接跳过更清晰。
    if (isMobilePlatform) {
      PlatformMediaHelper.getBrightness().then((b) {
        if (mounted) _brightness = b;
      });
      PlatformMediaHelper.getVolume().then((v) {
        if (mounted) {
          setState(() {
            _volume = v * 100.0;
            _muted = v == 0;
          });
        }
      });
      PlatformMediaHelper.addVolumeListener(_onSystemVolumeChanged);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: Colors.black,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );
    } else {
      // 桌面端：跟踪窗口全屏状态（用户用系统方式切全屏时界面图标也要跟着变）
      windowManager.addListener(this);
      _syncFullScreenState();
    }
    _syncAiSubtitleRunningState();
    AiTaskManager.instance.addListener(_onAiTaskManagerUpdated);
    _asrProgressSub = SubtitleGenerator.instance.progressStream.listen((p) {
      if (!mounted) return;
      // 识别用的是同一个全局生成器：只有当完成的这批字幕属于"当前播放的视频"
      // 时才自动显示，否则会给正在看的另一部片子叠上别人的字幕。
      final activeKey = _streamServer?.url ?? _sourcePath;
      final forThisVideo = SubtitleGenerator.instance.holdsEntriesFor(
        activeKey,
      );

      setState(() {
        _syncAiSubtitleRunningState();
        if (p.state == AsrState.completed) {
          if (forThisVideo) {
            _aiSubtitleActive = true;
            _showOsd(
              'AI 字幕识别完成 (共 ${SubtitleGenerator.instance.entries.length} 条)',
            );
          }
        } else if (p.state == AsrState.idle) {
          if (!forThisVideo || SubtitleGenerator.instance.entries.isEmpty) {
            _aiSubtitleActive = false;
          }
        } else if (p.state == AsrState.error && forThisVideo) {
          _showOsd(p.message ?? 'AI 语音识别失败');
        }
      });
    });
    // AI 字幕与翻译开关：设置页变化后播放页要立刻同步，因此监听触发重建。
    aiSubtitleEnabled.addListener(_onAiSubtitleSettingChanged);
    aiTranslationEnabled.addListener(_onAiSubtitleSettingChanged);
    _initPlayer();
  }

  /// 同步当前播放视频自身的 AI 语音识别运行状态。
  void _syncAiSubtitleRunningState() {
    final activeKey = _streamServer?.url ?? _sourcePath;
    final task = AiTaskManager.instance.getTask(activeKey);
    final running = task != null && task.isRunning;
    if (_aiSubtitleRunning != running) {
      setState(() => _aiSubtitleRunning = running);
    }
  }

  void _onAiTaskManagerUpdated() {
    if (!mounted) return;
    _syncAiSubtitleRunningState();
  }

  /// AI 字幕与翻译开关变化：重建界面，让 AI 入口与叠层同步显隐。
  void _onAiSubtitleSettingChanged() {
    if (mounted) setState(() {});
  }

  /// 移动端系统音量变化回调（响应手机侧边实体音量键）。
  void _onSystemVolumeChanged(double v) {
    if (!mounted) return;
    final percent = (v * 100.0).clamp(0.0, 100.0);
    // 若当前正在用屏幕手势滑动调节音量，手势自身在实时驱动显示，忽略外部广播避免冲突
    if (_dragType == _VerticalDragType.volume) return;
    setState(() {
      _volume = percent;
      _muted = percent == 0;
    });
    _showOsd(
      '音量 ${percent.round()}%',
      icon: percent == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
    );
  }

  @override
  void dispose() {
    if (isDesktopPlatform) windowManager.removeListener(this);
    aiSubtitleEnabled.removeListener(_onAiSubtitleSettingChanged);
    aiTranslationEnabled.removeListener(_onAiSubtitleSettingChanged);
    AiTaskManager.instance.removeListener(_onAiTaskManagerUpdated);
    _asrProgressSub?.cancel();
    _aiRestoreDebounce?.cancel();
    _cancelAutoHide();
    _osdTimer?.cancel();
    _restartHintTimer?.cancel();
    _keyboardFocus.dispose();
    if (isMobilePlatform) {
      PlatformMediaHelper.removeVolumeListener(_onSystemVolumeChanged);
      if (_brightnessModified) {
        PlatformMediaHelper.resetBrightness();
      }
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
      );
    }
    // 不在这里同步销毁 player 和 streamServer：_closePlayer 已先暂停播放
    // 并停止了 streamServer。底层资源（mpv 纹理）延迟释放，确保 Flutter
    // 渲染管线完成当前帧的合成、不再引用该纹理后才真正回收。
    final player = _player;
    final server = _streamServer;
    Future.delayed(const Duration(milliseconds: 150), () {
      try {
        server?.stop();
      } catch (_) {}
      try {
        player.dispose();
      } catch (_) {}
    });
    _noticeTimer?.cancel();
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
    if (isMobilePlatform) {
      // 移动端音频由系统媒体音量全权驱动，确保播放器自身始终为 100% 全额输出
      await _player.setVolume(100.0);
    }

    _player.stream.playing.listen((value) {
      if (mounted) {
        setState(() => _playing = value);
        if (value) {
          _scheduleAutoHide();
        } else {
          _cancelAutoHide();
          // 暂停时立刻落一次进度：用户按了暂停往往会直接关掉播放器
          _recordProgressNow();
        }
      }
    });
    _player.stream.position.listen((value) {
      if (mounted && !_scrubbing) setState(() => _position = value);
      _maybeRecordProgress(value);
    });
    _player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
      // 时长到位说明 mpv 已读完文件头，此时判断"有没有内嵌字幕"才有依据，
      // 也只有这时 seek 到续播位置才会生效。
      if (value > Duration.zero) {
        _durationKnown = true;
        _scheduleAiSubtitleRestore();
        _maybeApplyResume();
      }
    });
    // 音量双向同步：滑块调节 / 系统变化都反映到本地状态（桌面端生效）。
    _player.stream.volume.listen((value) {
      if (mounted && !isMobilePlatform) setState(() => _volume = value);
    });
    // 轨道列表与当前轨道由播放器驱动，供音轨/字幕菜单使用。
    _player.stream.tracks.listen((value) {
      if (!mounted) return;
      setState(() => _tracks = value);
      // 轨道信息到位后，主动把字幕真正加载上（见方法内注释）。
      _maybeAutoSelectSubtitle();
      _scheduleAiSubtitleRestore();
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
    _aiCacheChecked = false;
    _durationKnown = false;
    _primarySubId = 'none';
    _secondarySubId = 'none';
    _builtinTracksCache.clear();
    _aiRestoreDebounce?.cancel();
    _restartHintTimer?.cancel();
    _showRestartButton = false;
    _pendingResume = null;
    _lastRecordedPosition = Duration.zero;
    // 续播位置：只有播放列表里的视频才有记录（拖进来的临时文件查不到），
    // 传入 Media(start: resumePos) 让底层 mpv 原生从目标点解封装，从源头避免从 0 播起
    _pendingResume = await PlaybackProgressStore.resumePositionOf(path);
    final resumePos = _pendingResume;
    await _streamServer?.stop();
    _streamServer = null;
    if (info != null) {
      _streamServer = await PflxStreamServer.start(path, info);
      await _player.open(Media(_streamServer!.url, start: resumePos));
    } else {
      await _player.open(Media(path, start: resumePos));
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
      final isPflx =
          info != null &&
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
    // "从头播放"提示还在时先别隐藏：它跟着控制条一起显示
    if (_showRestartButton) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && _controlsVisible && !_scrubbing) {
        _hideControls();
      }
    });
  }

  void _cancelAutoHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _toggleControls() {
    if (_controlsVisible) {
      _hideControls();
    } else {
      setState(() => _controlsVisible = true);
      _scheduleAutoHide();
    }
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

  /// 当前视频是否确实持有有效的 AI 翻译字幕。
  bool get _hasTranslation {
    final activeKey = _streamServer?.url ?? _sourcePath;
    if (!SubtitleGenerator.instance.holdsEntriesFor(activeKey)) return false;
    return SubtitleGenerator.instance.entries.any(
      (e) => e.translatedText != null && e.translatedText!.isNotEmpty,
    );
  }

  /// 当前视频是否确实持有有效的 AI 语音原声字幕。
  bool get _hasAiOriginal {
    final activeKey = _streamServer?.url ?? _sourcePath;
    return SubtitleGenerator.instance.holdsEntriesFor(activeKey) &&
        SubtitleGenerator.instance.entries.isNotEmpty;
  }

  /// 当前视频是否确实持有有效的 AI 字幕条目。
  bool get _hasAiSubtitleEntries => _hasAiOriginal;

  /// 是否有任意有效的主字幕或副字幕处于激活状态。
  bool get _hasAnyActiveSubtitle =>
      _primarySubId != 'none' || _secondarySubId != 'none';

  /// 主字幕是否为视频内置字幕（由底层 mpv 直接原生渲染）。
  bool get _isBuiltinPrimary => _primarySubId.startsWith('builtin_');

  /// 根据字幕源 ID 检索当前对应的文本条目列表。
  List<SubtitleEntry>? _getEntriesForSubId(String id) {
    if (id == 'none') return null;
    final activeKey = _streamServer?.url ?? _sourcePath;
    if (id == 'ai_original') {
      if (!SubtitleGenerator.instance.holdsEntriesFor(activeKey)) return null;
      return SubtitleGenerator.instance.entries;
    }
    if (id == 'ai_translation') {
      if (!SubtitleGenerator.instance.holdsEntriesFor(activeKey)) return null;
      final raw = SubtitleGenerator.instance.entries;
      return raw.map((e) => SubtitleEntry(
        start: e.start,
        end: e.end,
        text: (e.translatedText != null && e.translatedText!.isNotEmpty)
            ? e.translatedText!
            : e.text,
      )).toList();
    }
    if (id.startsWith('builtin_')) {
      final idx = int.tryParse(id.substring(8));
      if (idx != null && _builtinTracksCache.containsKey(idx)) {
        return _builtinTracksCache[idx];
      }
    }
    return null;
  }

  /// 提取并缓存指定的内置字幕轨（用于作为副字幕或供外部调用）。
  Future<void> _ensureBuiltinTrackLoaded(int idx) async {
    if (_builtinTracksCache.containsKey(idx)) return;
    if (idx < 0 || idx >= _subtitleTracks.length) return;
    final track = _subtitleTracks[idx];
    if (BuiltInSubtitleExtractor.isGraphicSubtitle(track)) return;

    final videoPath = _streamServer?.url ?? _sourcePath;
    try {
      final entries = await BuiltInSubtitleExtractor.extractSubtitles(
        videoPath: videoPath,
        subtitleIndex: idx,
      );
      if (mounted) {
        setState(() {
          _builtinTracksCache[idx] = entries;
        });
      }
    } catch (e) {
      if (mounted) {
        _showOsd('内置字幕提取失败: $e');
      }
    }
  }

  /// 切换主字幕（位于画面上方，大字号）。
  Future<void> _selectPrimarySubtitle(String id, {bool showOsd = true}) async {
    _primarySubId = id;
    _aiSubtitleActive = _primarySubId.startsWith('ai_') || _secondarySubId.startsWith('ai_');

    if (id == 'none') {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      if (mounted) {
        setState(() {});
        if (showOsd) _showOsd('已关闭主字幕');
      }
      return;
    }

    if (id.startsWith('builtin_')) {
      final idx = int.tryParse(id.substring(8)) ?? 0;
      if (idx >= 0 && idx < _subtitleTracks.length) {
        final track = _subtitleTracks[idx];
        // 关键修复：内置字幕直接交由底层 mpv 原生渲染！
        // 0 延迟、100% 格式兼容（SRT/ASS/PGS/VobSub），彻底避免提取延迟或失败导致黑屏无字幕
        await _player.setSubtitleTrack(track);
        if (mounted) {
          setState(() {});
          if (showOsd) _showOsd('主字幕：${_subtitleLabel(track)}');
        }
        return;
      }
    }

    // AI 识别或翻译字幕：关闭底层 mpv 原生字幕，统一由 Flutter 叠层渲染
    await _player.setSubtitleTrack(SubtitleTrack.no());
    if (mounted) {
      setState(() {});
      if (showOsd) {
        final label = id == 'ai_translation' ? 'AI 翻译字幕' : 'AI 语音原字幕';
        _showOsd('主字幕：$label');
      }
    }
  }

  /// 切换副字幕（位于画面下方，小字号）。
  Future<void> _selectSecondarySubtitle(String id, {bool showOsd = true}) async {
    _secondarySubId = id;
    _aiSubtitleActive = _primarySubId.startsWith('ai_') || _secondarySubId.startsWith('ai_');

    if (id == 'none') {
      if (mounted) {
        setState(() {});
        if (showOsd) _showOsd('已关闭副字幕');
      }
      return;
    }

    if (id.startsWith('builtin_')) {
      final idx = int.tryParse(id.substring(8)) ?? 0;
      if (idx >= 0 && idx < _subtitleTracks.length) {
        final track = _subtitleTracks[idx];
        if (!_builtinTracksCache.containsKey(idx)) {
          _ensureBuiltinTrackLoaded(idx);
        }
        if (mounted) {
          setState(() {});
          if (showOsd) _showOsd('副字幕：${_subtitleLabel(track)}');
        }
        return;
      }
    }

    if (mounted) {
      setState(() {});
      if (showOsd) {
        final label = id == 'ai_translation' ? 'AI 翻译字幕' : 'AI 语音原字幕';
        _showOsd('副字幕：$label');
      }
    }
  }

  /// 关闭全部主副字幕。
  Future<void> _closeAllSubtitles() async {
    _primarySubId = 'none';
    _secondarySubId = 'none';
    _aiSubtitleActive = false;
    await _player.setSubtitleTrack(SubtitleTrack.no());
    if (mounted) {
      setState(() {});
      _showOsd('已关闭全部字幕');
    }
  }

  /// AI 识别或翻译总开关是否至少有一个启用。
  bool get _aiFeatureEnabled => aiSubtitleEnabled.value || aiTranslationEnabled.value;

  /// AI 按钮的提示文本。
  String get _aiButtonTooltip {
    if (aiSubtitleEnabled.value && aiTranslationEnabled.value) {
      return 'AI 语音字幕 · 识别与翻译';
    } else if (aiTranslationEnabled.value) {
      return 'AI 字幕翻译';
    } else {
      return 'AI 语音识别字幕';
    }
  }

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
    final defaultIdx = tracks.indexWhere((t) => t.isDefault == true);
    final targetIdx = defaultIdx >= 0 ? defaultIdx : 0;
    await _selectPrimarySubtitle('builtin_$targetIdx', showOsd: false);
  }

  /// 安排一次"恢复 AI 字幕"检查（带 500ms 去抖）。
  ///
  /// 轨道列表与时长是先后不定的两个事件，而"视频有没有内嵌字幕"决定了
  /// AI 字幕要不要自动显示，所以每收到一个信号都重新计时，等 500ms 内不再有
  /// 新信号（说明 mpv 已把轨道报全）才真正做判断，避免误判成"没有内嵌字幕"。
  void _scheduleAiSubtitleRestore() {
    if (_aiCacheChecked) return;
    _aiRestoreDebounce?.cancel();
    _aiRestoreDebounce = Timer(
      const Duration(milliseconds: 500),
      _maybeRestoreAiSubtitle,
    );
  }

  /// 打开视频后自动恢复"上次识别过的 AI 字幕"（本地有该视频缓存时才生效）。
  ///
  /// 优先级：**内嵌字幕 > AI 字幕**
  ///  1. 视频**有**内嵌字幕：自动选中内嵌字幕作主字幕，AI 字幕只做"就绪预载"
  ///     —— 缓存读进生成器但不在画面上显示，两行字幕同时出现太干扰阅读；
  ///     此时点一下 AI 字幕按钮就能立刻显示，不需要重新识别；
  ///  2. 视频**没有**内嵌字幕：直接把缓存的 AI 字幕作为主字幕显示出来，
  ///     打开视频就有字幕，不用再手动开启；
  ///  3. 多个模型都识别过：优先"上次使用的模型"（[aiAsrModelId]），它没有
  ///     缓存时在其余缓存里挑体积最大（精度最高）的那份。
  ///
  /// 每个播放源只判断一次（由 [_aiCacheChecked] 控制）。
  Future<void> _maybeRestoreAiSubtitle() async {
    if (_aiCacheChecked) return;
    // 轨道还没报全时不下结论：已经有轨道、或本视频时长已读到，才算信息可信
    if (_subtitleTracks.isEmpty && !_durationKnown) return;
    _aiCacheChecked = true;
    // 总开关关着就不自作主张
    if (!aiSubtitleEnabled.value) return;

    final activeKey = _streamServer?.url ?? _sourcePath;
    final generator = SubtitleGenerator.instance;

    // 生成器里已经载着本视频的字幕（刚识别完就退出、又进来）：直接按需显示
    if (generator.holdsEntriesFor(activeKey)) {
      if (_subtitleTracks.isEmpty && _primarySubId == 'none') {
        final targetSubId = _hasTranslation ? 'ai_translation' : 'ai_original';
        final subLabel = _hasTranslation ? 'AI 翻译字幕' : 'AI 语音识别字幕';
        await _selectPrimarySubtitle(targetSubId, showOsd: false);
        _showOsd('已自动显示 $subLabel');
      }
      return;
    }

    // 缓存按 _sourcePath 查（PFLX 也稳定），归属仍按本次会话的地址
    final restored = await _loadAiSubtitleCache(
      _sourcePath,
      ownerKey: activeKey,
    );
    if (restored == null || !mounted) return;

    if (_subtitleTracks.isNotEmpty) {
      // 视频已有内嵌字幕时，内嵌字幕为主，AI字幕静默就绪，不强行弹出干扰
      return;
    }

    // 视频无内嵌字幕时：若有翻译缓存则优先使用翻译字幕为主字幕，否则使用识别字幕；副字幕默认保持关闭
    final targetSubId = restored.hasTranslation ? 'ai_translation' : 'ai_original';
    final subLabel = restored.hasTranslation ? 'AI 翻译字幕' : 'AI 语音识别字幕';
    await _selectPrimarySubtitle(targetSubId, showOsd: false);
    _showOsd(
      '已自动显示 $subLabel（${restored.modelId.toUpperCase()} · ${restored.count} 条）',
    );
  }

  /// 从本地缓存里挑一份适合当前视频的 AI 字幕并载入生成器。
  ///
  /// 返回实际使用的模型、条数以及是否包含已翻译内容；该视频没有任何缓存时返回 null。
  Future<({String modelId, int count, bool hasTranslation})?> _loadAiSubtitleCache(
    String cacheKey, {
    required String ownerKey,
  }) async {
    final manager = AiTaskManager.instance;
    final cachedIds = await manager.getCachedModelIds(cacheKey);
    if (cachedIds.isEmpty) return null;

    // 上次使用的模型优先；其余按"模型越大越靠前"排 —— 同一条视频有多份缓存时
    // 优先用精度更高的那份，识别早已做过，这里没必要再为速度让步。
    final preferred = aiAsrModelId.value;
    final ordered = cachedIds.toList()
      ..sort((a, b) {
        if (a == preferred) return -1;
        if (b == preferred) return 1;
        return _modelWeight(b).compareTo(_modelWeight(a));
      });

    for (final id in ordered) {
      final cached = await manager.loadCachedSubtitles(cacheKey, modelId: id);
      if (cached == null || cached.isEmpty) continue;

      // 检查是否有该模型 ASR 字幕的历史翻译缓存
      final targetLang = aiTranslationTargetLang.value;
      final engineId = TranslationService.instance.getActiveEngine().id;
      final transCached = await TranslationService.instance.loadTranslationCache(
        sourceKey: cacheKey,
        sourceType: 'asr_$id',
        targetLang: targetLang,
        engineId: engineId,
      );

      final entriesToLoad = (transCached != null && transCached.isNotEmpty)
          ? transCached
          : cached;
      final hasTranslation = entriesToLoad.any(
        (e) => e.translatedText != null && e.translatedText!.isNotEmpty,
      );

      SubtitleGenerator.instance.setEntries(
        entriesToLoad,
        // 归属用本次会话的播放地址（面板/叠加层据此判断"是不是本视频"）
        videoPath: ownerKey,
        modelId: id,
        markCompleted: true,
      );
      return (modelId: id, count: entriesToLoad.length, hasTranslation: hasTranslation);
    }
    return null;
  }

  /// 模型在清单里的位置（越靠后体积越大、精度越高）。
  static int _modelWeight(String modelId) =>
      availableModels.indexWhere((m) => m.id == modelId);

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
    if (isMobilePlatform && _brightnessModified) {
      PlatformMediaHelper.resetBrightness();
    }
    // 1. 暂停播放，停止 mpv 的解码/渲染循环。
    try {
      await _player.pause();
    } catch (_) {}
    // 2. 落一次播放进度：下次打开这个视频从当前位置继续。
    //    放在 pause 之后 —— 位置已经稳定，记的就是用户实际看到的地方。
    await _recordProgressNow();
    // 3. 退出全屏再走：否则回到首页仍是全屏，而首页没有全屏入口，
    //    用户会觉得"窗口卡在全屏了"。
    if (isDesktopPlatform && _isFullScreen) {
      try {
        await windowManager.setFullScreen(false);
      } catch (_) {}
    }
    // 4. 提前停止流式服务（如有），减少 dispose 中的工作量。
    try {
      _streamServer?.stop();
      _streamServer = null;
    } catch (_) {}
    // 5. 等一帧，让 Flutter 渲染管线完成当前帧的合成，
    //    之后的帧就不会再引用播放器纹理了。
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    // 6. 现在安全 pop。
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
    // 全屏时改窗口尺寸会跟全屏状态打架（还可能把全屏顶掉）
    if (_isFullScreen) return;

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
      await windowManager.setSize(
        Size(
          targetClientWidth + chromeWidth,
          targetClientHeight + chromeHeight,
        ),
      );
    } catch (_) {
      // 调整失败不影响播放。
    }
  }

  // ------------------------------------------------------------ 桌面端交互

  /// 读取一次窗口的全屏状态，保证界面图标与真实状态一致。
  Future<void> _syncFullScreenState() async {
    try {
      final value = await windowManager.isFullScreen();
      if (!mounted || value == _isFullScreen) return;
      setState(() => _isFullScreen = value);
    } catch (_) {
      // 取不到就按当前记录显示，不影响播放
    }
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted) setState(() => _isFullScreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted) setState(() => _isFullScreen = false);
  }

  /// 切换全屏（仅桌面端；移动端本来就是沉浸式全屏，没有这个概念）。
  ///
  /// 全屏与双击画面、F11、控制条上的按钮三处入口共用，Esc 会优先退出全屏。
  Future<void> _toggleFullScreen() async {
    if (!isDesktopPlatform) return;
    final next = !_isFullScreen;
    try {
      await windowManager.setFullScreen(next);
    } catch (_) {
      return; // 切换失败不影响播放
    }
    if (!mounted) return;
    setState(() {
      _isFullScreen = next;
      // 全屏切换后保持控制条可见：用户多半接着还要操作
      _controlsVisible = true;
    });
    _scheduleAutoHide();
  }

  /// 画面被点击（[position] 为全局坐标，用于识别双击）。
  ///
  /// 桌面端：单击 = 显隐控制条，双击 = 全屏切换。
  /// 移动端：保持原来的单击显隐控制条。
  void _handleSurfaceTap(Offset? position) {
    if (!isDesktopPlatform) {
      _toggleControls();
      return;
    }

    final now = DateTime.now();
    final lastAt = _lastSurfaceTapAt;
    final lastPos = _lastSurfaceTapPos;
    final isDoubleClick =
        lastAt != null &&
        now.difference(lastAt) < const Duration(milliseconds: 300) &&
        (position == null ||
            lastPos == null ||
            (position - lastPos).distance < 32);

    _lastSurfaceTapAt = isDoubleClick ? null : now;
    _lastSurfaceTapPos = position;

    if (isDoubleClick) {
      _toggleFullScreen();
      return;
    }
    _toggleControls();
  }

  /// 鼠标在画面上活动：显示控件并重置自动隐藏计时。
  ///
  /// 带 250ms 节流——onHover 在鼠标移动时触发极其频繁，无节流会导致
  /// 移动鼠标时疯狂重建整棵组件树。
  ///
  /// 控制条处于隐藏状态时还有一道"移动距离"门槛（见 [_kPointerWakeDistance]）：
  /// 以隐藏那一刻的光标位置为基准，移动不够远就不唤出，免得轻微抖动就弹出来。
  void _onPointerActivity(PointerHoverEvent event) {
    final pos = event.position;
    // 每次都记：这样"隐藏瞬间的位置"始终是最新的
    _lastPointerPos = pos;

    if (!_controlsVisible) {
      final anchor = _pointerAnchor;
      if (anchor == null) {
        // 还没有基准点（例如隐藏后第一次收到 hover）：先记下来，不唤出
        _pointerAnchor = pos;
        return;
      }
      if ((pos - anchor).distance < _kPointerWakeDistance) return;
      _pointerAnchor = null;
    }

    final now = DateTime.now();
    if (now.difference(_lastPointerActivity).inMilliseconds < 250) return;
    _lastPointerActivity = now;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleAutoHide();
  }

  /// 隐藏控制条（同时记下光标位置，作为"要移动多远才唤回"的基准）。
  void _hideControls() {
    _cancelAutoHide();
    if (!_controlsVisible) return;
    setState(() => _controlsVisible = false);
    _pointerAnchor = _lastPointerPos;
  }

  /// 在画面右上角弹出一条瞬时提示（音量/静音/切轨反馈）。
  void _showOsd(String text, {IconData? icon}) {
    _osdTimer?.cancel();
    setState(() {
      _osdText = text;
      _osdIcon = icon;
    });
    _osdTimer = Timer(const Duration(milliseconds: 1600), _clearOsd);
  }

  /// 收起 OSD 提示。
  void _clearOsd() {
    _osdTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _osdText = null;
      _osdIcon = null;
    });
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    _dragStartY = details.globalPosition.dy;
    if (details.globalPosition.dx < screenWidth / 2) {
      _dragType = _VerticalDragType.brightness;
      _dragStartValue = _brightness;
    } else {
      _dragType = _VerticalDragType.volume;
      _dragStartValue = _volume;
    }
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_dragType == null) return;
    final screenHeight = MediaQuery.of(context).size.height;
    // 向上滑动为正，向下滑动为负
    final deltaY = _dragStartY - details.globalPosition.dy;
    final ratio = deltaY / (screenHeight * 0.6);

    if (_dragType == _VerticalDragType.brightness) {
      final next = (_dragStartValue + ratio).clamp(0.01, 1.0);
      _brightness = next;
      _brightnessModified = true;
      PlatformMediaHelper.setBrightness(next);
      _showOsd(
        '亮度 ${(next * 100).round()}%',
        icon: next > 0.5
            ? Icons.brightness_7_rounded
            : Icons.brightness_medium_rounded,
      );
    } else if (_dragType == _VerticalDragType.volume) {
      final next = (_dragStartValue + ratio * 100.0).clamp(0.0, 100.0);
      _volume = next;
      _muted = next == 0;
      if (isMobilePlatform) {
        PlatformMediaHelper.setVolume(next / 100.0);
      } else {
        _player.setVolume(next);
      }
      _showOsd(
        '音量 ${next.round()}%',
        icon: next == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      );
    }
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    _dragType = null;
  }

  void _handleVerticalDragCancel() {
    _dragType = null;
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    if (_duration <= Duration.zero) return;
    _horizontalDragging = true;
    _dragStartX = details.globalPosition.dx;
    _seekDragStartPosition = _scrubbing ? _scrubPosition : _position;
    _seekDragTargetPosition = _seekDragStartPosition;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_horizontalDragging || _duration <= Duration.zero) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final deltaX = details.globalPosition.dx - _dragStartX;
    // 滑动整屏宽度对应 90 秒快进/快退，手感适中细腻
    final seekDeltaSeconds = (deltaX / screenWidth) * 90.0;
    final deltaDuration = Duration(
      milliseconds: (seekDeltaSeconds * 1000).round(),
    );
    final target = _clampDuration(
      _seekDragStartPosition + deltaDuration,
      Duration.zero,
      _duration,
    );
    _seekDragTargetPosition = target;

    final diffSeconds = (target - _seekDragStartPosition).inSeconds;
    final signStr = diffSeconds > 0 ? '+$diffSeconds' : '$diffSeconds';
    final icon = diffSeconds >= 0
        ? Icons.fast_forward_rounded
        : Icons.fast_rewind_rounded;
    final text =
        '${_formatDuration(target)} / ${_formatDuration(_duration)} ($signStr秒)';

    _showOsd(text, icon: icon);
  }

  Future<void> _handleHorizontalDragEnd(DragEndDetails details) async {
    if (!_horizontalDragging) return;
    _horizontalDragging = false;
    final target = _seekDragTargetPosition;
    await _player.seek(target);
    _scheduleAutoHide();
  }

  void _handleHorizontalDragCancel() {
    _horizontalDragging = false;
  }

  // ------------------------------------------------------------ 播放进度（续播）

  /// 媒体加载完成后跳到上次的播放位置（每个播放源只做一次）。
  ///
  /// 执行续播定位：首选通过 Media(start: resumePosition) 原生起播。
  /// 此处作为双重保障，并在界面上呈现"已从 xx 继续播放"和"从头播放"快捷按钮。
  Future<void> _maybeApplyResume() async {
    final target = _pendingResume;
    if (target == null) return;
    _pendingResume = null;
    final current = _player.state.position;
    // 如果当前播放位置距离目标位置明显过远（例如底层起播延迟或未直接定位），执行显式 seek
    if ((current - target).abs() > const Duration(seconds: 2)) {
      await _player.seek(target);
    }
    _lastRecordedPosition = target;
    if (!mounted) return;
    _showOsd('已从 ${_formatDuration(target)} 继续播放');
    _showRestartHint();

    // 防御性校准：针对 Android 某些机型 MediaCodec 异步就绪后将时间轴冲回 0 的问题
    if (isMobilePlatform && target > const Duration(seconds: 3)) {
      Future.delayed(const Duration(milliseconds: 380), () async {
        if (!mounted) return;
        final posNow = _player.state.position;
        if (posNow < const Duration(seconds: 2)) {
          await _player.seek(target);
        }
      });
    }
  }

  /// 续播后在进度条上方浮出"从头播放"按钮，几秒后自动收起。
  ///
  /// 放在进度条正上方而不是右上角的 OSD 里：它是个**可点的操作**，
  /// 位置要贴着播放进度条；OSD 是纯提示，两者混在一起既不好点也不好看。
  void _showRestartHint() {
    _restartHintTimer?.cancel();
    setState(() {
      _showRestartButton = true;
      // 移动端控制条 4 秒后自动隐藏，会把这个按钮一起带走：
      // 按钮在场时先别隐藏，给它留出点击时间（见 _scheduleAutoHide）。
      _controlsVisible = true;
    });
    _cancelAutoHide();
    _restartHintTimer = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      setState(() => _showRestartButton = false);
      _scheduleAutoHide();
    });
  }

  /// 收起"从头播放"按钮。
  void _hideRestartHint() {
    _restartHintTimer?.cancel();
    _restartHintTimer = null;
    if (!mounted) return;
    setState(() => _showRestartButton = false);
    _scheduleAutoHide();
  }

  /// 从头播放：回到片头并清掉续播记录。
  Future<void> _restartFromBeginning() async {
    _hideRestartHint();
    _pendingResume = null;
    _lastRecordedPosition = Duration.zero;
    await _player.seek(Duration.zero);
    await PlaybackProgressStore.clear(_sourcePath);
    if (mounted) _showOsd('已从头播放');
  }

  /// 播放中按 [_kProgressSaveStep] 节流记录进度，避免每个 position 事件都写盘。
  ///
  /// 片源还没加载完（_[_durationKnown] 为 false）时位置没有意义 —— 换片途中
  /// `state.position` 可能还是上一个视频的值，写下去就成了张冠李戴的续播点。
  void _maybeRecordProgress(Duration position) {
    if (!_durationKnown) return;
    // 续播尚未完成或正处于起播定位期间，忽略过小的进度，避免误将 0 秒写盘覆盖历史续播点
    if (_pendingResume != null) return;
    if ((position - _lastRecordedPosition).abs() < _kProgressSaveStep) return;
    _lastRecordedPosition = position;
    PlaybackProgressStore.record(
      _sourcePath,
      position: position,
      duration: _duration,
    );
  }

  /// 立即记录当前进度（暂停、退出播放页时调用）。
  Future<void> _recordProgressNow() async {
    if (!_durationKnown) return;
    // 续播还没生效时不要误把 0 秒记录下去
    if (_pendingResume != null) return;
    final position = _player.state.position;
    _lastRecordedPosition = position;
    await PlaybackProgressStore.record(
      _sourcePath,
      position: position,
      duration: _duration,
    );
  }

  Future<void> _changeVolume(double delta) async {
    final next = (_volume + delta).clamp(0.0, 100.0);
    if (next == _volume && !_muted) {
      // 已到边界：仍给一次反馈，避免用户以为按键没生效。
      _showOsd('音量 ${next.round()}%');
      return;
    }
    _muted = false;
    if (isMobilePlatform) {
      await PlatformMediaHelper.setVolume(next / 100.0);
    } else {
      await _player.setVolume(next);
    }
    if (mounted) {
      setState(() => _volume = next);
      _showOsd('音量 ${next.round()}%');
    }
  }

  Future<void> _toggleMute() async {
    if (_muted) {
      _muted = false;
      if (isMobilePlatform) {
        await PlatformMediaHelper.setVolume(_volumeBeforeMute / 100.0);
      } else {
        await _player.setVolume(_volumeBeforeMute);
      }
      if (mounted) {
        setState(() => _volume = _volumeBeforeMute);
        _showOsd('已取消静音');
      }
    } else {
      _volumeBeforeMute = _volume > 0 ? _volume : 50;
      _muted = true;
      if (isMobilePlatform) {
        await PlatformMediaHelper.setVolume(0);
      } else {
        await _player.setVolume(0);
      }
      if (mounted) {
        setState(() => _volume = 0);
        _showOsd('已静音');
      }
    }
  }

  /// 桌面端键盘快捷键（对齐桌面播放器通用习惯）。
  ///
  /// 空格=播放/暂停，←/→=±10s，↑/↓=音量，M=静音，F11=全屏，
  /// Esc=退全屏（已全屏时）/ 退出播放。双击画面同样切换全屏。
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
    if (key == LogicalKeyboardKey.f11) {
      if (!isRepeat) _toggleFullScreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (!isRepeat) {
        // 全屏时先退全屏，再按一次才退出播放页（与常见播放器一致）
        if (_isFullScreen) {
          _toggleFullScreen();
        } else {
          _closePlayer();
        }
      }
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
        // 画面字幕叠加层（统一由 Flutter 渲染在视频画面上，主字幕在上、副字幕在下）
        if (_hasAnyActiveSubtitle)
          SubtitleOverlay(
            position: currentPosition,
            visible: true,
            primaryEntries: _isBuiltinPrimary ? null : _getEntriesForSubId(_primarySubId),
            secondaryEntries: _getEntriesForSubId(_secondarySubId),
            bottomOffset: _isBuiltinPrimary ? 132 : 80,
          ),
        _PlayerScrim(showControls: _controlsVisible),
        _PlayerTopBar(
          visible: _controlsVisible,
          title: _title,
          isPflx: _sourceIsPflx,
          closeIcon: Icons.arrow_back_rounded,
          onClose: _closePlayer,
        ),
        if (_noticeText != null) _PlayerTopNotice(text: _noticeText!),
        // 画面中央的大号播放按钮只服务触屏；桌面端点底部控制条即可。
        // 左右滑动已能快进快退，两侧的 ±10s 按钮不再需要。
        if (!isDesktopPlatform)
          Center(
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _CenterControls(
                  playing: _playing,
                  onPlayPause: _togglePlayback,
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
          showRestartHint: _showRestartButton,
          showFullScreenToggle: isDesktopPlatform,
          isFullScreen: _isFullScreen,
          desktopControls: isDesktopPlatform
              ? _buildDesktopTrackControls()
              : null,
          mobileTrackControls: isMobilePlatform
              ? _buildMobileTrackControls()
              : null,
          onPlayPause: _togglePlayback,
          onSpeedTap: () => _showSpeedSheet(),
          onToggleOrientation: _toggleOrientation,
          onRestart: _restartFromBeginning,
          onToggleFullScreen: _toggleFullScreen,
          onScrubStart: _onScrubStart,
          onScrubUpdate: _onScrubUpdate,
          onScrubEnd: _onScrubEnd,
        ),
        if (_switchingSource)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        // 本视频正在识别时的常驻提示（右上角）：切走再回来依然在，
        // 不像 OSD 那样一闪即逝。点一下直接打开 AI 面板。
        //
        // 有瞬时 OSD 时先让位——两者同在右上角会叠字；OSD 只显示 1.6 秒，
        // 消失后这里会自动重新出现。
        if (_aiSubtitleRunning && _osdText == null)
          Positioned(
            top: 72,
            left: MediaQuery.of(context).size.width * 0.35,
            right: 16,
            child: Align(
              alignment: Alignment.centerRight,
              child: _PlayerTaskBadge(
                videoKey: _streamServer?.url ?? _sourcePath,
                onTap: _showAiSubtitleSheet,
              ),
            ),
          ),
        if (_osdText != null) _PlayerOsd(text: _osdText!, icon: _osdIcon),
      ],
    );

    final player = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 用 onTapUp 而不是 onTap：需要拿到点击位置来识别"双击画面"（桌面端切全屏）
      onTapUp: (details) => _handleSurfaceTap(details.globalPosition),
      onVerticalDragStart: !isDesktopPlatform ? _handleVerticalDragStart : null,
      onVerticalDragUpdate: !isDesktopPlatform
          ? _handleVerticalDragUpdate
          : null,
      onVerticalDragEnd: !isDesktopPlatform ? _handleVerticalDragEnd : null,
      onVerticalDragCancel: !isDesktopPlatform
          ? _handleVerticalDragCancel
          : null,
      onHorizontalDragStart: !isDesktopPlatform
          ? _handleHorizontalDragStart
          : null,
      onHorizontalDragUpdate: !isDesktopPlatform
          ? _handleHorizontalDragUpdate
          : null,
      onHorizontalDragEnd: !isDesktopPlatform ? _handleHorizontalDragEnd : null,
      onHorizontalDragCancel: !isDesktopPlatform
          ? _handleHorizontalDragCancel
          : null,
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
                  onHover: _onPointerActivity,
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
        children: [player, if (_dropActive) const _PlayerDropHint()],
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
          onPressed: _showSubtitleSettingsSheet,
          tooltip: '字幕设置',
          icon: Icon(
            _hasAnyActiveSubtitle ? Icons.subtitles_rounded : Icons.subtitles_outlined,
            color: Colors.white,
          ),
        ),
        // AI 字幕按钮（总开关打开时常驻可见，点击弹出控制面板）
        if (_aiFeatureEnabled)
          IconButton(
            onPressed: _showAiSubtitleSheet,
            tooltip: _aiButtonTooltip,
            icon: _aiSubtitleRunning
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
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
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: _TrackSelectionSheet(
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
      ),
    );
    if (selected != null) await _selectAudio(selected);
  }

  /// 底部弹窗：设置主字幕与副字幕通道。
  Future<void> _showSubtitleSettingsSheet() async {
    setState(() => _controlsVisible = true);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202027),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (context) => _SubtitleSettingsSheet(
        primarySubId: _primarySubId,
        secondarySubId: _secondarySubId,
        hasTranslation: _hasTranslation,
        hasAiOriginal: _hasAiOriginal,
        subtitleTracks: _subtitleTracks,
        onSelectPrimary: (id) => _selectPrimarySubtitle(id),
        onSelectSecondary: (id) => _selectSecondarySubtitle(id),
        onCloseAll: _closeAllSubtitles,
        formatTrackLabel: _subtitleLabel,
      ),
    );
  }

  /// 桌面端控制条右侧附加区：音量滑块 + 音轨 + 字幕。
  Widget _buildDesktopTrackControls() {
    final audioTracks = _audioTracks;
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
        IconButton(
          tooltip: '字幕设置',
          icon: Icon(
            _hasAnyActiveSubtitle ? Icons.subtitles_rounded : Icons.subtitles_outlined,
            color: Colors.white,
          ),
          onPressed: _showSubtitleSettingsSheet,
        ),
        // 桌面端独立的 AI 字幕与翻译快捷按钮（只要启用了识别或翻译就显示）
        if (_aiFeatureEnabled)
          IconButton(
            onPressed: _showAiSubtitleSheet,
            tooltip: _aiButtonTooltip,
            icon: _aiSubtitleRunning
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
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

  /// 打开 AI 字幕与翻译控制面板。
  Future<void> _showAiSubtitleSheet() async {
    setState(() => _controlsVisible = true);

    await AiSubtitleSheet.show(
      context: context,
      // 提取音频要用能读的地址（PFLX 走本地流）
      videoPath: _streamServer?.url ?? _sourcePath,
      videoTitle: _title,
      // 但字幕缓存按源文件路径存：PFLX 的流地址端口每次都变
      cacheKey: _sourcePath,
      isAiSubtitleActive: _aiSubtitleActive,
      onToggleSubtitleActive: (active) {
        setState(() => _aiSubtitleActive = active);
      },
      onSeekTo: (position) {
        _player.seek(position);
      },
      subtitleTracks: _subtitleTracks,
      activeSubtitleId: _activeSubtitleId,
    );

    // 面板关闭后，若当前已无可用字幕，强制将 _aiSubtitleActive 置为 false，
    // 并触发 setState 确保左下角按钮与画面叠加层立即同步变为未激活状态
    if (mounted) {
      setState(() {
        if (!_hasAiSubtitleEntries) {
          _aiSubtitleActive = false;
        }
      });
    }
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

/// 画面右上角的瞬时提示浮层（音量/亮度/静音/切轨反馈）。
class _PlayerOsd extends StatelessWidget {
  const _PlayerOsd({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topRight,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(0, isPortrait ? 76 : 16, 16, 0),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.6,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .72),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          text,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
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
              colors: [
                Color(0x66000000),
                Colors.transparent,
                Color(0x99000000),
              ],
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
                                isPflx
                                    ? Icons.auto_awesome_rounded
                                    : Icons.movie_outlined,
                                color: const Color(0xFFD5D1FF),
                                size: 13,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isPflx ? 'PFLX 隐藏视频' : '本地视频',
                                style: const TextStyle(
                                  color: Color(0xFFD5D1FF),
                                  fontSize: 12,
                                ),
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

/// 位于标题栏下方的独立悬浮提示条（如"已添加 1 个视频"），相互独立，自动平滑淡出
class _PlayerTopNotice extends StatelessWidget {
  const _PlayerTopNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 72),
          child: Align(
            alignment: Alignment.topCenter,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 220),
              builder: (context, opacity, child) {
                return Opacity(opacity: opacity, child: child);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .78),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .22),
                    width: 0.6,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: Color(0xFFD5D1FF),
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
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
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
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
  const _CenterControls({required this.playing, required this.onPlayPause});

  final bool playing;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context) {
    // 只有中央一个大号播放/暂停按钮：快进快退交给屏幕左右滑动。
    return Tooltip(
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
    );
  }
}

/// 进度条上方的"从头播放"小按钮。
///
/// 续播时浮出来，提示"这条视频是从中间接着播的，想从头看就点这里"；
/// 几秒后自动收起（见播放页的 `_showRestartHint`）。
class _RestartFromStartChip extends StatelessWidget {
  const _RestartFromStartChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.restart_alt_rounded, size: 16, color: Colors.white),
              SizedBox(width: 6),
              Text(
                '从头播放',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
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
    required this.onRestart,
    required this.onToggleFullScreen,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    this.showRestartHint = false,
    this.showFullScreenToggle = false,
    this.isFullScreen = false,
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

  /// 是否显示进度条上方的"从头播放"小按钮（续播后短暂出现）。
  final bool showRestartHint;

  /// 是否显示全屏按钮（仅桌面端；移动端本来就是沉浸式全屏）。
  final bool showFullScreenToggle;

  /// 当前是否处于全屏（决定按钮图标）。
  final bool isFullScreen;

  final VoidCallback onPlayPause;
  final VoidCallback onSpeedTap;
  final VoidCallback onToggleOrientation;
  final VoidCallback onRestart;
  final VoidCallback onToggleFullScreen;
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
    final current = position.inMilliseconds.toDouble().clamp(
      0.0,
      total <= 0 ? 1.0 : total,
    );
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
                    // "从头播放"小按钮：续播后浮在进度条正上方居中
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      alignment: Alignment.bottomCenter,
                      child: showRestartHint
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _RestartFromStartChip(onTap: onRestart),
                            )
                          : const SizedBox.shrink(),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white.withValues(alpha: .28),
                        thumbColor: Colors.white,
                        overlayColor: Colors.white.withValues(alpha: .14),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 18,
                        ),
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
                        // 移动端竖屏时屏幕中央已有大号播放/进退按钮，底部最左侧播放按钮隐藏以防宽度不足溢出；
                        // 横屏或桌面端保留底部播放按钮。
                        if (isDesktopPlatform || isLandscape) ...[
                          IconButton(
                            onPressed: onPlayPause,
                            tooltip: playing ? '暂停' : '播放',
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 2),
                        ] else
                          const SizedBox(width: 4),
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
                            backgroundColor: Colors.white.withValues(
                              alpha: .16,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
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
                        if (showFullScreenToggle) ...[
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: onToggleFullScreen,
                            tooltip: isFullScreen ? '退出全屏 (Esc)' : '全屏 (F11)',
                            icon: Icon(
                              isFullScreen
                                  ? Icons.fullscreen_exit_rounded
                                  : Icons.fullscreen_rounded,
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
              style: TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w700,
              ),
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
  });

  final String title;
  final String subtitle;
  final List<_TrackOption> options;

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
            Text(subtitle, style: const TextStyle(color: Color(0xFFCBC7D2))),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    _TrackOptionTile(
                      option: option,
                      onTap: () => Navigator.of(context).pop(option.id),
                    ),
                ],
              ),
            ),
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

/// 播放页右上角的"本视频正在识别"常驻提示。
///
/// 之前只有一条 1.6 秒的 OSD 瞬时提示，切到别的视频再回来就看不到了。
/// 这里改成常驻浮标：只要**本视频**的任务还在跑就一直显示进度与已耗时，
/// 每秒刷新一次；点一下直接打开 AI 面板。别的视频的任务不会显示在这里。
class _PlayerTaskBadge extends StatefulWidget {
  const _PlayerTaskBadge({required this.videoKey, required this.onTap});

  /// 当前播放视频的标识（流地址或本地路径），用于匹配属于本视频的任务。
  final String videoKey;

  final Future<void> Function() onTap;

  @override
  State<_PlayerTaskBadge> createState() => _PlayerTaskBadgeState();
}

class _PlayerTaskBadgeState extends State<_PlayerTaskBadge> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 每秒刷新，让"已耗时"走动；任务结束后这个组件会自动消失
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = AiTaskManager.instance.getTask(widget.videoKey);
    if (task == null || !task.isRunning) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final percentText = task.percent > 0
        ? ' ${(task.percent * 100).toStringAsFixed(0)}%'
        : '';
    final actionName = task.taskType == AiTaskType.translation
        ? '字幕翻译中'
        : (task.state == AsrState.preparing ? '正在提取音频' : 'AI 识别中');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => widget.onTap(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .68),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.primary.withValues(alpha: .55)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '$actionName$percentText · 已用 ${AiTask.formatDuration(task.elapsed)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主/副字幕通道设置面板。
///
/// 视觉与交互全面升级：支持独立配置主字幕（上方 · 主要阅读）与副字幕（下方 · 对照辅助），
/// 排除无法转为文本的图形字幕（图形字幕仅保留在主字幕中直通 mpv 渲染）。
class _SubtitleSettingsSheet extends StatefulWidget {
  const _SubtitleSettingsSheet({
    required this.primarySubId,
    required this.secondarySubId,
    required this.hasTranslation,
    required this.hasAiOriginal,
    required this.subtitleTracks,
    required this.onSelectPrimary,
    required this.onSelectSecondary,
    required this.onCloseAll,
    required this.formatTrackLabel,
  });

  final String primarySubId;
  final String secondarySubId;
  final bool hasTranslation;
  final bool hasAiOriginal;
  final List<SubtitleTrack> subtitleTracks;
  final ValueChanged<String> onSelectPrimary;
  final ValueChanged<String> onSelectSecondary;
  final VoidCallback onCloseAll;
  final String Function(SubtitleTrack) formatTrackLabel;

  @override
  State<_SubtitleSettingsSheet> createState() => _SubtitleSettingsSheetState();
}

class _SubtitleSettingsSheetState extends State<_SubtitleSettingsSheet> {
  late String _currentPrimary;
  late String _currentSecondary;

  @override
  void initState() {
    super.initState();
    _currentPrimary = widget.primarySubId;
    _currentSecondary = widget.secondarySubId;
  }

  void _choosePrimary(String id) {
    setState(() {
      _currentPrimary = id;
      // 若副字幕正好选了同一个有效字幕，则自动重置副字幕为关闭
      if (id != 'none' && _currentSecondary == id) {
        _currentSecondary = 'none';
        widget.onSelectSecondary('none');
      }
    });
    widget.onSelectPrimary(id);
  }

  void _chooseSecondary(String id) {
    setState(() {
      _currentSecondary = id;
      // 若主字幕正好选了同一个有效字幕，则自动重置主字幕为关闭
      if (id != 'none' && _currentPrimary == id) {
        _currentPrimary = 'none';
        widget.onSelectPrimary('none');
      }
    });
    widget.onSelectSecondary(id);
  }

  void _closeAll() {
    setState(() {
      _currentPrimary = 'none';
      _currentSecondary = 'none';
    });
    widget.onCloseAll();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNone = _currentPrimary == 'none' && _currentSecondary == 'none';

    // 构建主字幕候选池
    final allPrimaryItems = <_SubDropdownItem>[
      const _SubDropdownItem(id: 'none', label: '关闭主字幕'),
      if (widget.hasTranslation)
        const _SubDropdownItem(
          id: 'ai_translation',
          label: 'AI 翻译字幕',
          badge: '已翻译',
          badgeColor: Color(0xFF00796B),
        ),
      if (widget.hasAiOriginal)
        const _SubDropdownItem(
          id: 'ai_original',
          label: 'AI 语音原字幕',
          badge: '已识别',
          badgeColor: PolyFlixColors.violet,
        ),
      ...widget.subtitleTracks.asMap().entries.map((entry) {
        final i = entry.key;
        final track = entry.value;
        final isGraphic = BuiltInSubtitleExtractor.isGraphicSubtitle(track);
        return _SubDropdownItem(
          id: 'builtin_$i',
          label: widget.formatTrackLabel(track),
          badge: isGraphic ? '图形' : null,
          badgeColor: const Color(0xFFBF360C),
        );
      }),
    ];

    // 构建副字幕候选池（过滤掉图形字幕，副字幕仅提供可文本渲染的轨道）
    final allSecondaryItems = <_SubDropdownItem>[
      const _SubDropdownItem(id: 'none', label: '关闭副字幕'),
      if (widget.hasAiOriginal)
        const _SubDropdownItem(
          id: 'ai_original',
          label: 'AI 语音原字幕',
          badge: '已识别',
          badgeColor: PolyFlixColors.violet,
        ),
      if (widget.hasTranslation)
        const _SubDropdownItem(
          id: 'ai_translation',
          label: 'AI 翻译字幕',
          badge: '已翻译',
          badgeColor: Color(0xFF00796B),
        ),
      ...widget.subtitleTracks.asMap().entries
          .where((e) => !BuiltInSubtitleExtractor.isGraphicSubtitle(e.value))
          .map((entry) {
        final i = entry.key;
        final track = entry.value;
        return _SubDropdownItem(
          id: 'builtin_$i',
          label: widget.formatTrackLabel(track),
        );
      }),
    ];

    // 互斥过滤：已经在主字幕选中的项，不在副字幕下拉框中出现；
    // 已经在副字幕选中的项，也不在主字幕下拉框中出现（'none' 除外）
    final primaryItems = allPrimaryItems.where((item) {
      if (item.id == 'none') return true;
      return item.id != _currentSecondary;
    }).toList();

    final secondaryItems = allSecondaryItems.where((item) {
      if (item.id == 'none') return true;
      return item.id != _currentPrimary;
    }).toList();

    final effectivePrimary = primaryItems.any((it) => it.id == _currentPrimary)
        ? _currentPrimary
        : 'none';
    final effectiveSecondary = secondaryItems.any((it) => it.id == _currentSecondary)
        ? _currentSecondary
        : 'none';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶栏：标题 + 一键关闭全部
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.subtitles_rounded,
                    color: theme.colorScheme.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  '字幕设置',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (!isNone)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent.shade100,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _closeAll,
                    icon: const Icon(Icons.subtitles_off_outlined, size: 16),
                    label: const Text('关闭全部字幕', style: TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 16),

            // 1. 主字幕板块（上层 · 大号）
            _buildSectionHeader(
              icon: Icons.vertical_align_top_rounded,
              title: '主字幕',
              subTitle: '显示在上方 · 主要阅读',
              theme: theme,
            ),
            const SizedBox(height: 8),
            _buildDropdown(
              selectedValue: effectivePrimary,
              items: primaryItems,
              onChanged: _choosePrimary,
              theme: theme,
            ),

            const SizedBox(height: 18),

            // 2. 副字幕板块（下层 · 对照辅助）
            _buildSectionHeader(
              icon: Icons.vertical_align_bottom_rounded,
              title: '副字幕',
              subTitle: '显示在下方 · 对照辅助',
              theme: theme,
            ),
            const SizedBox(height: 8),
            _buildDropdown(
              selectedValue: effectiveSecondary,
              items: secondaryItems,
              onChanged: _chooseSecondary,
              theme: theme,
            ),

            const SizedBox(height: 16),
            const Center(
              child: Text(
                '提示：主字幕在上方、副字幕在下方。图形类字幕仅能在主字幕中由底层硬件直接渲染。',
                style: TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String subTitle,
    required ThemeData theme,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          subTitle,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildDropdown({
    required String selectedValue,
    required List<_SubDropdownItem> items,
    required ValueChanged<String> onChanged,
    required ThemeData theme,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF262630),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: selectedValue,
          dropdownColor: const Color(0xFF262630),
          borderRadius: BorderRadius.circular(12),
          menuMaxHeight: 320,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70),
          items: items.map((item) {
            final isSelected = item.id == selectedValue;
            return DropdownMenuItem<String>(
              value: item.id,
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: isSelected
                        ? Icon(
                            Icons.check_rounded,
                            size: 17,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (item.badge != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: item.badgeColor ?? Colors.white24,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.badge!,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) onChanged(val);
          },
        ),
      ),
    );
  }
}

class _SubDropdownItem {
  const _SubDropdownItem({
    required this.id,
    required this.label,
    this.badge,
    this.badgeColor,
  });

  final String id;
  final String label;
  final String? badge;
  final Color? badgeColor;
}
