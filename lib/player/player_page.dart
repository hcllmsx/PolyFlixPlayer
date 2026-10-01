/// 播放页：基于 media_kit 的沉浸式播放器，提供播放、快进、进度拖动与倍速控制。
///
/// 移动端与桌面端的差异集中在这几处：
/// - 移动端用 SystemChrome 做沉浸式全屏、屏幕方向旋转，并靠点击画面显隐控件；
///   桌面端没有这些概念，改为鼠标移动显隐 + 键盘快捷键。两端在播放中都会于
///   4 秒无操作后自动隐藏控件（桌面端移动鼠标唤回，门槛见
///   [_kPointerWakeDistance]；移动端点击画面唤回）。
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
import '../settings/external_subtitle_store.dart';
import '../settings/playback_progress.dart';
import '../subtitle/ai_subtitle_sheet.dart';
import '../subtitle/ai_task_manager.dart';
import '../subtitle/external_subtitle.dart';
import '../subtitle/model_manager.dart';
import '../subtitle/subtitle_generator.dart';
import '../subtitle/subtitle_overlay.dart';
import '../subtitle/translation/builtin_subtitle_extractor.dart';
import '../subtitle/translation/translation_service.dart';
import '../utils/native_file_helper.dart';
import '../utils/platform_media_helper.dart';
import '../utils/platform_utils.dart';

/// 移动端手势调节类型（左侧亮度，右侧音量）。
enum _VerticalDragType { brightness, volume }

/// 桌面端单次调节音量的步进值（键盘 ↑/↓）。
const double _kVolumeStep = 5;

/// 桌面端键盘快进/快退的秒数（←/→），与界面按钮的 ±10s 保持一致。
const int _kSeekStepSeconds = 10;

/// 桌面端控制条隐藏后，要"短时间内快速划动"这么多逻辑像素才会重新唤出。
///
/// 只在 [_kPointerWakeWindow] 这个时间窗内累计：慢慢挪动时，每个窗口只有
/// 一点点位移，窗口到期就清零重来，永远攒不够，因此不会唤出；而左右快速
/// 晃动几下（每一下的位移都落在同一个 2 秒窗口内）会累加，攒够即唤出。
const double _kPointerWakeDistance = 1680;

/// 鼠标位移累计的时间窗：超过这么久就清零重开，避免缓慢移动被慢慢累加。
const Duration _kPointerWakeWindow = Duration(seconds: 2);

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

/// 时间轴偏移的显示文本：`+1.5s` / `-0.5s` / `0`。
String _formatOffsetLabel(int ms) {
  if (ms == 0) return '0';
  final seconds = (ms / 1000).toStringAsFixed(1);
  return ms > 0 ? '+${seconds}s' : '${seconds}s';
}

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
  /// 当前主字幕源 ID。
  ///
  /// 取值：`none` / `ai_translation` / `ai_original` / `builtin_下标`
  /// （内置轨原生渲染）/ `builtin_下标_text`（内置轨文本化后走叠层）/
  /// `external_uid`（外挂字幕，渲染方式由该条目的模式决定）。
  String _primarySubId = 'none';

  /// 当前副字幕源 ID（取值同 [_primarySubId]，但原生渲染的源不能当副字幕）。
  String _secondarySubId = 'none';

  /// 内置字幕文本解析缓存（以字幕轨序号为 key）。
  final Map<int, List<SubtitleEntry>> _builtinTracksCache = {};

  /// 已加载的外挂字幕（用户手动选的 + 同目录同名自动匹配到的）。
  final List<_ExternalSub> _externalSubs = [];

  /// 第一次往 mpv 挂外挂轨之前，视频自带字幕轨的 id 快照。
  ///
  /// 外挂轨的识别全靠它（标题不可靠，见 [_isBuiltinSubtitleTrack]）。
  /// 换片时清空，因为 mpv 会连同外挂轨一起丢掉。
  Set<String>? _builtinSubtitleIdsSnapshot;

  /// 本次播放源的外挂字幕计划（在打开播放源前就打探好，见 [_planExternalSubtitles]）。
  ///
  /// 非 null 表示"这次会自动挂外挂字幕"，内嵌 / AI 字幕的自动选择据此主动让位：
  /// 否则两者会各发一条 mpv 命令抢 `sid`，谁后到谁赢——表现就是"面板里勾着外挂
  /// 字幕、画面却是内置字幕"。
  ({ExternalSubtitleMemory memory, List<String> paths, bool fromMemory})?
      _externalPlan;

  /// mpv 实际的字幕轨 id（读 `sid` 得到，用于核对外挂轨到底挂上没有）。
  String _lastMpvSid = '';

  /// 最近一条 mpv 错误日志。
  ///
  /// media_kit 把 `sub-add` 的失败只写进日志（不抛异常），挂外挂字幕失败时
  /// 靠它把 mpv 的原话带出来，免得只能回一句"挂不上"。
  String? _lastMpvError;

  /// 本机这份 mpv 是否已证实渲染不了图形位图字幕（PGS / VobSub）。
  ///
  /// 实测 media_kit 在 Windows 上自带的 libmpv 没编译 PGS 解码器，mpv 会直接报
  /// `Could not find subtitle decoder for format 'hdmv_pgs_subtitle'` 并把轨丢掉。
  /// 一旦撞上就记住，后续同类字幕直接快速失败，不再白试。
  ///
  /// 默认构建用的是支持 PGS 的增强内核（见 windows/CMakeLists.txt），所以这条
  /// 只在用 `-DPFLX_LIBMPV_ENHANCED=OFF` 退回裁剪版内核时才会触发；
  /// 留着它是为了让那种构建给出"快速失败 + 说明原因"，而不是静默挂不上。
  bool _bitmapSubtitleUnsupported = false;

  /// 当前播放内核的 mpv 版本号（懒读一次，只用于排障提示）。
  ///
  /// 出问题时"到底是哪份 libmpv 在跑"最难判断：裁剪版和增强版 DLL 同名，
  /// 构建产物没更新时表现一模一样。把版本号带进提示里，一眼就能对上号。
  String? _mpvVersion;
  bool _mpvVersionQueried = false;

  /// 自增的外挂字幕编号，用作稳定 ID。
  ///
  /// 不能用列表下标当 ID：移掉一份外挂字幕后其余下标会整体前移，
  /// 已经选在主/副通道上的那个 ID 就会指到别人身上。
  int _externalUidSeq = 0;

  /// 当前播放源是否已经尝试过"自动恢复/匹配外挂字幕"。
  bool _externalRestoreApplied = false;

  /// 是否正在选字幕文件（防止重复弹出选择器）。
  bool _externalPicking = false;


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

  /// 控制条隐藏后，当前这一轮鼠标位移累计窗口的起始时刻。
  ///
  /// 为 null 表示尚未开窗（刚隐藏 / 刚唤出），下一次 hover 会重新开窗。
  DateTime? _pointerWakeWindowStart;

  /// 当前 [_kPointerWakeWindow] 窗口内已累计的鼠标位移（逻辑像素）。
  double _pointerWakeAccum = 0;

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
    // 字幕必须由 mpv 真正画出来：media_kit 的默认配置（libass: false）会把 mpv
    // 设成 `sub-visibility=no` —— 按 mpv 手册的说法是"只选中与解码，但不显示"
    //（"Can be used to disable display of subtitles, but still select and decode
    // them"）。本项目把内置字幕与原生外挂字幕（ASS 特效、PGS 图形）都交给 mpv
    // 渲染，所以必须开这个模式；走 Flutter 叠层那几条路（AI 字幕、文本化字幕）
    // 各自会用 setSubtitleTrack(no()) 关掉 mpv 字幕，不受影响。
    _player = Player(configuration: const PlayerConfiguration(libass: true));
    _controller = VideoController(_player);
    // 再加一道保险：即使 media_kit 日后改了默认值，也确保字幕显示开关是开的。
    await _forceMpvSubtitleVisible();
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
    // 留一条 mpv 的错误原文：挂外挂字幕失败时能把真正的原因带出来
    _player.stream.log.listen((event) {
      if (event.level != 'error' && event.level != 'fatal') return;
      _lastMpvError = '${event.prefix}: ${event.text}';
      _noteUnsupportedBitmapSubtitle(event.text);
    });

    await _openSource(_sourcePath, _sourceIsPflx ? _sourceInfo : null);

    if (!mounted) return;
    setState(() => _ready = true);
    _scheduleAutoHide();
  }

  /// 打开播放源：PFLX 产物走本地 HTTP Range 流（不落盘），普通文件直接播放。
  Future<void> _openSource(String path, PflxInfo? info) async {
    // 先认下新播放源：拖放换片时调用方要等本方法返回才更新 _sourcePath，
    // 而下面那些异步动作（外挂字幕恢复、落盘）都用它当身份，晚了会写到上一个视频头上。
    _sourcePath = path;
    _autoSubtitleApplied = false;
    _windowFitApplied = false;
    _aiCacheChecked = false;
    _durationKnown = false;
    _primarySubId = 'none';
    _secondarySubId = 'none';
    _builtinTracksCache.clear();
    // 外挂字幕是跟着播放源走的：换片后整批丢掉，由下面重新恢复/匹配
    _externalSubs.clear();
    _builtinSubtitleIdsSnapshot = null;
    _externalRestoreApplied = false;
    _externalPlan = null;
    _lastMpvSid = '';
    _aiRestoreDebounce?.cancel();
    _restartHintTimer?.cancel();
    _showRestartButton = false;
    _pendingResume = null;
    _lastRecordedPosition = Duration.zero;
    // 续播位置：只有播放列表里的视频才有记录（拖进来的临时文件查不到），
    // 传入 Media(start: resumePos) 让底层 mpv 原生从目标点解封装，从源头避免从 0 播起
    _pendingResume = await PlaybackProgressStore.resumePositionOf(path);
    final resumePos = _pendingResume;
    // 起播前先打探"这个视频有没有可用的外挂字幕"：只查记忆与同目录同名，
    // 不读字幕内容、不外呼 ffmpeg（代价是一次 JSON 读 + 一次目录列举）。
    // 有了这个结论，内嵌 / AI 字幕的自动选择才知道该让位。
    _externalPlan = await _planExternalSubtitles(path);
    await _streamServer?.stop();
    _streamServer = null;
    if (info != null) {
      _streamServer = await PflxStreamServer.start(path, info);
      await _player.open(Media(_streamServer!.url, start: resumePos));
    } else {
      await _player.open(Media(path, start: resumePos));
    }
    // 外挂字幕（记忆恢复 / 同目录同名匹配）不阻塞起播：媒体已经在放了，
    // 字幕文件读完后自己挂上去即可。这里显式传 path：拖放换片时
    // [_sourcePath] 要等本方法返回后才更新，不能读它。
    unawaited(_maybeAutoLoadExternalSubtitles(path));
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

  /// 真实可切换的**内置**字幕轨。
  ///
  /// 必须把我们自己 `sub-add` 上去的外挂轨排除掉：下面所有"内置轨下标"都要和
  /// ffmpeg 的 `0:s:下标` 一一对齐（提取文本、翻译都靠它），而外挂轨并不属于
  /// 输入文件，混进来会让下标整体错位、提取到错误的字幕流。
  List<SubtitleTrack> get _subtitleTracks =>
      _allSubtitleTracks.where(_isBuiltinSubtitleTrack).toList(growable: false);

  /// mpv 实际报上来的全部字幕轨（含外挂轨）。
  List<SubtitleTrack> get _allSubtitleTracks => _tracks.subtitle
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList(growable: false);

  /// 这条轨是不是视频**自带的**字幕轨。
  ///
  /// 判定不看轨道标题：`.ass` 文件自带 `Title:` 元数据时，mpv 可能拿它盖掉我们
  /// `sub-add` 时给的标题。改为在"第一次挂外挂轨之前"给内置轨拍一张快照
  /// （见 [_builtinSubtitleIdsSnapshot]），快照之外的必然是外挂轨。
  bool _isBuiltinSubtitleTrack(SubtitleTrack track) {
    if (ExternalSubtitleLoader.isExternalTrack(track)) return false;
    final snapshot = _builtinSubtitleIdsSnapshot;
    // 还没挂过任何外挂轨：列表里不可能有外挂轨，全部按内置处理
    if (snapshot == null) return true;
    return snapshot.contains(track.id);
  }

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

  /// 主字幕是否由底层 mpv 原生渲染（内置轨，或原生模式的特效外挂字幕）。
  bool get _isNativePrimary {
    final builtin = _parseBuiltinId(_primarySubId);
    if (builtin != null) return !builtin.text;
    final ext = _externalById(_primarySubId);
    return ext != null && ext.rendersNatively;
  }

  /// 主字幕是否为"特效 / 图形"类原生字幕。
  ///
  /// 这类字幕由 mpv 直接画在画面上（带样式、定位、特效或整幅位图），再叠一层
  /// AI 字幕必然互相遮挡，所以此时 AI 字幕一律置灰，只在面板里给一句说明。
  bool get _isExclusivePrimary {
    final builtin = _parseBuiltinId(_primarySubId);
    if (builtin != null) {
      if (builtin.text) return false;
      if (builtin.index < 0 || builtin.index >= _subtitleTracks.length) {
        return false;
      }
      final track = _subtitleTracks[builtin.index];
      return BuiltInSubtitleExtractor.isGraphicSubtitle(track) ||
          _isEffectsCodec(track.codec);
    }
    final ext = _externalById(_primarySubId);
    return ext != null && ext.rendersNatively;
  }

  /// 当前主字幕能否"降级成纯文本"（图形位图字幕做不到，只能原生渲染）。
  bool get _canConvertPrimaryToText {
    final builtin = _parseBuiltinId(_primarySubId);
    if (builtin != null) {
      if (builtin.text) return false;
      if (builtin.index < 0 || builtin.index >= _subtitleTracks.length) {
        return false;
      }
      return !BuiltInSubtitleExtractor.isGraphicSubtitle(
        _subtitleTracks[builtin.index],
      );
    }
    final ext = _externalById(_primarySubId);
    // 图形位图字幕（.sup / VobSub）抽不出文字，没有"转文本"这条路
    return ext != null &&
        ext.rendersNatively &&
        ext.kind == ExternalSubtitleKind.effects;
  }

  /// 特效 / 图形主字幕的说明文案。
  String get _exclusivePrimaryHint {
    const graphicsHint = '该字幕是图形位图字幕（PGS / VobSub），只能由底层原生渲染，'
        '也无法转成文本，因此不能与 AI 字幕同时显示。';
    final builtin = _parseBuiltinId(_primarySubId);
    if (builtin != null &&
        builtin.index >= 0 &&
        builtin.index < _subtitleTracks.length &&
        BuiltInSubtitleExtractor.isGraphicSubtitle(_subtitleTracks[builtin.index])) {
      return '该内置$graphicsHint';
    }
    final ext = _externalById(_primarySubId);
    if (ext != null && ext.kind == ExternalSubtitleKind.graphics) {
      return '该外挂$graphicsHint';
    }
    return '该字幕带特效 / 定位，为保真交由底层原生渲染，'
        '与 AI 字幕同屏会互相遮挡，因此 AI 字幕暂不可选。';
  }

  /// 编码是否属于"带特效"的字幕格式（ASS / SSA）。
  static bool _isEffectsCodec(String? codec) {
    final c = (codec ?? '').toLowerCase();
    return c.contains('ass') || c.contains('ssa');
  }

  /// 解析内置字幕轨 ID：`builtin_2`（原生渲染）/ `builtin_2_text`（文本化）。
  ({int index, bool text})? _parseBuiltinId(String id) {
    if (!id.startsWith('builtin_')) return null;
    final rest = id.substring(8);
    final text = rest.endsWith('_text');
    final index = int.tryParse(
      text ? rest.substring(0, rest.length - '_text'.length) : rest,
    );
    if (index == null) return null;
    return (index: index, text: text);
  }

  /// 外挂字幕的稳定 ID（用自增编号，不用列表下标，见 [_externalUidSeq]）。
  String _externalIdOf(_ExternalSub ext) => 'external_${ext.uid}';

  /// 按 ID 找外挂字幕；不是外挂字幕或找不着时返回 null。
  _ExternalSub? _externalById(String id) {
    if (!id.startsWith('external_')) return null;
    final uid = int.tryParse(id.substring('external_'.length));
    if (uid == null) return null;
    for (final ext in _externalSubs) {
      if (ext.uid == uid) return ext;
    }
    return null;
  }

  /// 是否已经有外挂字幕占着主字幕位。
  bool get _hasExternalPrimary => _externalById(_primarySubId) != null;

  /// 是否已经有外挂字幕挂在主或副通道上。
  bool get _hasExternalActive =>
      _externalById(_primarySubId) != null ||
      _externalById(_secondarySubId) != null;

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
    // 内置轨的"文本化"变体与副字幕通道共用同一份提取缓存
    final builtin = _parseBuiltinId(id);
    if (builtin != null) {
      return _builtinTracksCache[builtin.index];
    }
    // 外挂字幕：只有纯文本模式才有条目，原生模式的由 mpv 直接画
    return _externalById(id)?.displayEntries;
  }

  /// 提取并缓存指定的内置字幕轨（用于作为副字幕、主字幕文本化或翻译）。
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

    // 主字幕换成原生渲染的"特效/图形"字幕时，同屏的 AI 副字幕必须先摘掉：
    // 两者叠在同一片画面上就是互相遮挡，不如只留一条干净的。
    var droppedAiSecondary = false;
    if (_isExclusivePrimary && _secondarySubId.startsWith('ai_')) {
      _secondarySubId = 'none';
      _aiSubtitleActive = false;
      droppedAiSecondary = true;
    }

    if (id == 'none') {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      await _syncMpvSubtitleDelay();
      if (mounted) {
        setState(() {});
        if (showOsd) _showOsd('已关闭主字幕');
      }
      return;
    }

    final builtin = _parseBuiltinId(id);
    final ext = _externalById(id);
    final isNative = (builtin != null && !builtin.text) ||
        (ext != null && ext.rendersNatively);

    if (isNative) {
      if (builtin != null) {
        if (builtin.index < 0 || builtin.index >= _subtitleTracks.length) {
          // 轨道列表变了（换片/轨道消失）：别把字幕停在一个已经不存在的下标上
          _primarySubId = 'none';
          if (mounted) setState(() {});
          return;
        }
        final track = _subtitleTracks[builtin.index];
        // 关键：内置字幕直接交由底层 mpv 原生渲染！
        // 0 延迟、100% 格式兼容（SRT/ASS/PGS/VobSub），彻底避免提取延迟或失败导致黑屏无字幕
        await _player.setSubtitleTrack(track);
        _lastMpvSid = track.id;
      } else if (ext != null) {
        final attached = await _attachExternalTrackToMpv(ext);
        if (!attached) {
          // 挂不上就如实回退：面板状态必须和画面一致
          await _handleExternalAttachFailed(ext);
          return;
        }
      }
      await _syncMpvSubtitleDelay();
      if (mounted) {
        setState(() {});
        if (showOsd) {
          _showOsd(
            '主字幕：${_primarySubtitleLabel()}${droppedAiSecondary ? '（已关闭同屏 AI 字幕）' : ''}',
          );
        }
      }
      unawaited(_persistExternalSubtitles());
      return;
    }

    // 叠层渲染：AI 字幕 / 文本化内置轨 / 纯文本外挂字幕。
    // 统一关掉底层 mpv 原生字幕，避免两套渲染叠在一起。
    await _player.setSubtitleTrack(SubtitleTrack.no());
    await _syncMpvSubtitleDelay();

    if (builtin != null && builtin.text) {
      await _ensureBuiltinTrackLoaded(builtin.index);
      if (!_builtinTracksCache.containsKey(builtin.index)) {
        // 提取失败（图形字幕/损坏）：别把下拉停在一个永远不显示的项上
        _primarySubId = 'none';
        if (mounted) {
          setState(() {});
          if (showOsd) _showOsd('该内置字幕无法转为文本显示');
        }
        return;
      }
    } else if (ext != null) {
      final ok = await _ensureExternalTextLoaded(ext);
      if (!ok) {
        _primarySubId = 'none';
        if (mounted) {
          setState(() {});
          if (showOsd) _showOsd('外挂字幕加载失败：${ext.name}');
        }
        return;
      }
    }

    if (mounted) {
      setState(() {});
      if (showOsd) {
        _showOsd(
          '主字幕：${_primarySubtitleLabel()}${droppedAiSecondary ? '（已关闭同屏 AI 字幕）' : ''}',
        );
      }
    }
    unawaited(_persistExternalSubtitles());
  }

  /// 主字幕的显示名（OSD / 提示用）。
  String _primarySubtitleLabel() {
    final id = _primarySubId;
    if (id == 'ai_translation') return 'AI 翻译字幕';
    if (id == 'ai_original') return 'AI 语音原字幕';
    final builtin = _parseBuiltinId(id);
    if (builtin != null) {
      final label = builtin.index >= 0 && builtin.index < _subtitleTracks.length
          ? _subtitleLabel(_subtitleTracks[builtin.index])
          : '内置字幕 ${builtin.index}';
      return builtin.text ? '$label（纯文本）' : label;
    }
    final ext = _externalById(id);
    // 外挂字幕只报文件名：文件名本身已经说明它是哪一份，再缀"原生特效/纯文本"
    // 只是噪音（用户明确提过不要这类提示）
    if (ext != null) return ext.name;
    return '无';
  }

  /// 把外挂原生字幕（特效 `.ass` / 图形 `.sup`、VobSub）交给 mpv 渲染。
  ///
  /// 返回 false 表示**没真正挂上**（格式不受内核支持等），调用方要如实回退。
  ///
  /// 这里要绕开两个坑：
  ///  1. media_kit 的 `sub-add` 出错时**只写日志、不抛异常**（见其 `_command`），
  ///     光看"调用没报错"完全靠不住——必须回读 mpv 的 `sid` 核对；
  ///  2. media_kit 每次 `setSubtitleTrack(SubtitleTrack.uri(...))` 都会重新
  ///     `sub-add`，同名文件反复切换会挂出一堆重复轨，所以先查是否已经挂过。
  Future<bool> _attachExternalTrackToMpv(_ExternalSub ext) async {
    // 本机内核已证实渲染不了图形位图字幕：直接失败，别再白试一遍
    if (ext.kind == ExternalSubtitleKind.graphics && _bitmapSubtitleUnsupported) {
      return false;
    }

    // 已经挂过 → 只切 sid，不重复添加
    final existing = _findAttachedExternalTrack(ext);
    if (existing != null) {
      try {
        await _player.setSubtitleTrack(existing);
        _lastMpvSid = existing.id;
        return true;
      } catch (_) {
        return false;
      }
    }

    // 第一次挂外挂轨：先把当前的字幕轨拍成"内置快照"，之后靠它区分内外
    _snapshotBuiltinSubtitleIds();
    _lastMpvError = null;
    _lastMpvSid = '';

    final path = ext.mpvPath ??=
        await ExternalSubtitleLoader.ensureMpvReadable(ext.path);

    // 1. 原文件：裸路径 → Windows 长路径写法（视频自己也是这么打开的）
    //    核对窗口给到约 0.9 秒：图形字幕（.sup 几十 MB）在新内核上要建索引，
    //    慢了半拍就误判成"挂不上"会把能用的字幕冤枉掉。
    for (final uri in ExternalSubtitleLoader.uriCandidates(path)) {
      if (await _tryAttachExternalUri(ext, uri, attempts: 6)) return true;
    }

    // 2. 文件可能已经进去了、只是 sid 没落到它身上（被内置轨抢了）→ 显式再选一次
    final attached = _findAttachedExternalTrack(ext);
    if (attached != null) {
      try {
        await _player.setSubtitleTrack(attached);
        if (await _verifyExternalSubtitleSelected(attempts: 4)) {
          ext.mpvTrackId = _lastMpvSid;
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// 用给定地址发一次 `sub-add` 并核对是否真的选中；成功返回 true。
  Future<bool> _tryAttachExternalUri(
    _ExternalSub ext,
    String uri, {
    required int attempts,
  }) async {
    try {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(
          uri,
          title: ExternalSubtitleLoader.trackTitleFor(ext.path),
          language: 'external',
        ),
      );
    } catch (_) {
      return false;
    }
    if (!await _verifyExternalSubtitleSelected(attempts: attempts)) return false;
    ext.mpvTrackId = _lastMpvSid;
    return true;
  }

  /// 拍一次"内置字幕轨 id"快照（只在第一次挂外挂轨前拍，之后不再变）。
  ///
  /// 轨道还没报全（快照为空）时宁可不拍：否则后面才报上来的内置轨会被当成外挂轨。
  void _snapshotBuiltinSubtitleIds() {
    if (_builtinSubtitleIdsSnapshot != null) return;
    final ids = _allSubtitleTracks.map((t) => t.id).toSet();
    if (ids.isNotEmpty) _builtinSubtitleIdsSnapshot = ids;
  }

  /// 找出这个外挂文件已经挂到 mpv 上的那条轨（没有则 null）。
  ///
  /// 优先用上次成功挂载时记下的轨 id；退一步按标题找（标题可能被 mpv 用 ASS 自带的
  /// `Title:` 元数据盖掉）。
  SubtitleTrack? _findAttachedExternalTrack(_ExternalSub ext) {
    final id = ext.mpvTrackId;
    if (id != null && id.isNotEmpty) {
      final byId = _allSubtitleTracks.where((t) => t.id == id).firstOrNull;
      if (byId != null) return byId;
      ext.mpvTrackId = null; // 轨没了（换过片源等）
    }
    final title = ExternalSubtitleLoader.trackTitleFor(ext.path);
    return _allSubtitleTracks.where((t) => t.title == title).firstOrNull;
  }

  /// 核对 mpv 是不是真的选中了外挂轨（读 `sid` 对账）。
  ///
  /// 判据：sid 指向的轨不在"内置快照"里 ⇒ 那就是刚挂上去的外挂轨。
  /// 读不到属性时按成功处理，避免把能用的情况误判成失败。
  Future<bool> _verifyExternalSubtitleSelected({int attempts = 5}) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return true;
    final snapshot = _builtinSubtitleIdsSnapshot ?? const <String>{};

    for (var attempt = 0; attempt < attempts; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted) return true;
      String sid;
      try {
        sid = (await platform.getProperty('sid')).trim();
      } catch (_) {
        return true;
      }
      if (sid.isEmpty) return true;
      _lastMpvSid = sid;
      if (sid == 'no' || sid == 'auto') continue;
      // 视频本来一条字幕都没有（快照为空）时，能报出 id 的只可能是我们刚挂的那条
      if (!snapshot.contains(sid)) return true;
    }
    return false;
  }

  /// mpv 报出"图形字幕没解码器"时记下来（本机内核渲染不了 PGS / VobSub）。
  ///
  /// 记下之后同类字幕直接快速失败，并在用户正看着这类字幕时当场说明原因，
  /// 免得他对着一个永远不出现的字幕反复点。
  void _noteUnsupportedBitmapSubtitle(String text) {
    if (!text.contains('subtitle decoder') &&
        !text.contains('subtitle converter')) {
      return;
    }
    if (_bitmapSubtitleUnsupported) return;
    _bitmapSubtitleUnsupported = true;
    debugPrint('[PolyFlix][external-subtitle] 本机 mpv 缺少图形字幕解码器：$text');
    if (!mounted) return;
    if (_isGraphicPrimary) {
      _showOsd('本机内核不支持图形位图字幕（PGS / VobSub）');
    }
  }

  /// 当前主字幕是否为图形位图字幕（内置 PGS/VobSub，或外挂图形字幕）。
  bool get _isGraphicPrimary {
    final builtin = _parseBuiltinId(_primarySubId);
    if (builtin != null) {
      return builtin.index >= 0 &&
          builtin.index < _subtitleTracks.length &&
          BuiltInSubtitleExtractor.isGraphicSubtitle(_subtitleTracks[builtin.index]);
    }
    final ext = _externalById(_primarySubId);
    return ext != null && ext.kind == ExternalSubtitleKind.graphics;
  }

  /// 确保 mpv 的字幕显示开关是打开的。
  ///
  /// `sub-visibility=no` 时 mpv 会"只解码不显示"，画面里不会有任何字幕，
  /// 而其它状态（sid、sub-start、sub-text）看起来都正常，极难排查。
  Future<void> _forceMpvSubtitleVisible() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('sub-visibility', 'yes');
        // 回读一次记进日志：这条状态一旦是 no，任何字幕都不会出现在画面上，
        // 而其它迹象（sid / sub-start / sub-text）全都正常，极难排查。
        final vis = (await platform.getProperty('sub-visibility')).trim();
        debugPrint('[PolyFlix][subtitle] mpv sub-visibility=$vis');
      }
    } catch (_) {
      // 设置失败不拦播放：最坏就是回到 media_kit 的默认行为
    }
  }

  /// 读一次当前内核的 mpv 版本号（拿不到就返回 null）。
  Future<String?> _resolveMpvVersion() async {
    if (_mpvVersionQueried) return _mpvVersion;
    _mpvVersionQueried = true;
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        final value = (await platform.getProperty('mpv-version')).trim();
        if (value.isNotEmpty) _mpvVersion = value;
      }
    } catch (_) {
      // 读不到就不带版本号，不影响其它逻辑
    }
    return _mpvVersion;
  }

  /// 外挂字幕没能真正挂上时的善后。
  ///
  /// 关键是别让界面骗人：面板里勾着外挂字幕、画面却是原来那条字幕，
  /// 比直接报一句错更让人摸不着头脑。
  Future<void> _handleExternalAttachFailed(_ExternalSub ext) async {
    // 把面板对齐到 mpv 的真实情况：它现在显示哪条内置轨就选哪条
    var restored = 'none';
    for (var i = 0; i < _subtitleTracks.length; i++) {
      if (_subtitleTracks[i].id == _lastMpvSid) {
        restored = 'builtin_$i';
        break;
      }
    }
    _primarySubId = restored;
    // mpv 的原话打到控制台：OSD 上只报一句，细节留给排查
    final version = await _resolveMpvVersion();
    final versionTag = version == null ? '' : '（当前内核 $version）';
    debugPrint(
      '[PolyFlix][external-subtitle] "${ext.name}" 挂载失败，'
      'sid=$_lastMpvSid，'
      '内核=${version ?? '未知'}，'
      'mpv 报错：${_lastMpvError ?? '（无）'}',
    );
    if (mounted) {
      setState(() {});
      // 图形位图字幕挂不上基本只有一种原因（内核没有 PGS/VobSub 解码器），
      // 这时给一句能照做的建议 + 当前内核版本，比"无法播放"有用得多
      _showOsd(
        ext.kind == ExternalSubtitleKind.graphics
            ? '本机内核$versionTag不支持图形位图字幕（PGS / VobSub），'
                '请改用 .srt / .ass 字幕'
            : '该外挂字幕无法播放：${ext.name}$versionTag',
      );
    }
    unawaited(_persistExternalSubtitles());
  }

  /// 把当前主字幕的时间轴偏移同步给 mpv。
  ///
  /// 原生渲染的字幕由 mpv 自己排版，偏移只能靠 `sub-delay` 生效；
  /// 叠层渲染的字幕是我们在条目上直接加偏移的，这里要把它复位成 0。
  Future<void> _syncMpvSubtitleDelay() async {
    final ext = _externalById(_primarySubId);
    final seconds = (ext != null && ext.rendersNatively) ? ext.offsetMs / 1000.0 : 0.0;
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('sub-delay', seconds.toString());
      }
    } catch (_) {
      // 设置失败不影响播放：最坏就是偏移不生效
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
      final builtin = _parseBuiltinId(id);
      final idx = builtin?.index ?? -1;
      if (idx >= 0 && idx < _subtitleTracks.length) {
        final track = _subtitleTracks[idx];
        // 副字幕只能走叠层渲染，所以这里一律按"文本化"处理（样式丢失）
        if (!_builtinTracksCache.containsKey(idx)) {
          await _ensureBuiltinTrackLoaded(idx);
        }
        if (mounted) {
          setState(() {});
          if (showOsd) _showOsd('副字幕：${_subtitleLabel(track)}');
        }
        return;
      }
    }

    // 外挂字幕作副字幕：同样只支持纯文本模式（原生特效字幕独占画面，不当副字幕）
    final ext = _externalById(id);
    if (ext != null) {
      if (ext.rendersNatively) return;
      final ok = await _ensureExternalTextLoaded(ext);
      if (!ok) {
        _secondarySubId = 'none';
        if (mounted) {
          setState(() {});
          if (showOsd) _showOsd('外挂字幕加载失败：${ext.name}');
        }
        return;
      }
      if (mounted) {
        setState(() {});
        if (showOsd) _showOsd('副字幕：${ext.name}');
      }
      unawaited(_persistExternalSubtitles());
      return;
    }

    // AI 字幕作副字幕时，如果主字幕是特效/图形字幕，两者会同屏打架，直接拒绝
    if (id.startsWith('ai_') && _isExclusivePrimary) {
      _secondarySubId = 'none';
      if (mounted) {
        setState(() {});
        if (showOsd) _showOsd(_exclusivePrimaryHint);
      }
      return;
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
    await _syncMpvSubtitleDelay();
    if (mounted) {
      setState(() {});
      _showOsd('已关闭全部字幕');
    }
    // 一并记下"这次一条都没挂"：下次打开同一个视频不要自作主张再弹出来
    unawaited(_persistExternalSubtitles());
  }

  // ---------------- 外挂字幕（加载 / 模式 / 偏移 / 记忆） ----------------

  /// 确保外挂字幕的文本条目已解析出来（首次会读文件，必要时外呼 ffmpeg 转码）。
  Future<bool> _ensureExternalTextLoaded(_ExternalSub ext) async {
    if (ext.displayEntries != null) return true;
    try {
      final entries = await ExternalSubtitleLoader.loadEntries(ext.path);
      if (entries.isEmpty) return false;
      ext.baseEntries = entries;
      _applyExternalOffset(ext);
      if (mounted) setState(() {});
      return true;
    } catch (e) {
      if (mounted) _showOsd('外挂字幕解析失败：${ext.name}（$e）');
      return false;
    }
  }

  /// 按当前偏移重建外挂字幕的显示条目。
  ///
  /// 叠层每帧都要拿这份列表做二分查找，所以偏移一变就整批算好缓存下来，
  /// 不在渲染路径上做逐条加减。
  void _applyExternalOffset(_ExternalSub ext) {
    final base = ext.baseEntries;
    if (base == null) {
      ext.displayEntries = null;
      return;
    }
    ext.displayEntries = ExternalSubtitleLoader.applyOffset(
      base,
      Duration(milliseconds: ext.offsetMs),
    );
  }

  /// 加载一份外挂字幕；同一路径只会留一份。
  Future<_ExternalSub?> _loadExternalSubtitle(
    String rawPath, {
    bool plainText = false,
    int offsetMs = 0,
  }) async {
    if (!ExternalSubtitleLoader.isSupported(rawPath)) {
      if (mounted) {
        _showOsd('不支持的字幕格式：${ExternalSubtitleLoader.fileNameOf(rawPath)}');
      }
      return null;
    }

    // VobSub 递过来 `.sub` 时换成同名的 `.idx`（mpv 要的是索引文件）
    final path = await ExternalSubtitleLoader.resolveCompanion(rawPath);

    for (final ext in _externalSubs) {
      if (ext.path == path) return ext;
    }

    final ext = _ExternalSub(
      uid: _externalUidSeq++,
      path: path,
      name: ExternalSubtitleLoader.fileNameOf(path),
      kind: ExternalSubtitleLoader.kindOf(path),
      plainText: plainText,
      offsetMs: offsetMs,
    );

    // 纯文本模式的先解析出内容再入列：读不出来的话加进来也只是个永远不显示的项
    if (!ext.rendersNatively) {
      final ok = await _ensureExternalTextLoaded(ext);
      if (!ok) return null;
    }

    _externalSubs.add(ext);
    if (mounted) setState(() {});
    return ext;
  }

  /// 「加载外挂字幕…」：选文件 → 加载 → 挂为主字幕。
  Future<void> _pickExternalSubtitle() async {
    if (_externalPicking) return;
    _externalPicking = true;
    try {
      final picked = await NativeFileHelper.pickSubtitleFile(
        allowedExtensions: kExternalSubtitleExtensions.toList(),
      );
      if (picked == null) return;
      if (!ExternalSubtitleLoader.isSupported(picked.path)) {
        if (mounted) {
          _showOsd(
            '不支持的字幕格式：${picked.name}（支持 srt / vtt / ass / ssa / sup / idx）',
          );
        }
        return;
      }
      if (mounted) _showOsd('正在加载字幕：${picked.name}');

      final ext = await _loadExternalSubtitle(picked.path);
      if (ext == null || !mounted) return;

      await _selectPrimarySubtitle(_externalIdOf(ext), showOsd: false);
      if (!mounted) return;
      // 渲染方式（原生特效 / 纯文本）在面板里能看到，这里只报一句结果；
      // 挂不上时 _handleExternalAttachFailed 已经报过原因，不再重复
      if (_hasExternalPrimary) _showOsd('已加载外挂字幕：${ext.name}');
    } catch (e) {
      if (mounted) _showOsd('加载外挂字幕失败：$e');
    } finally {
      _externalPicking = false;
    }
  }

  /// 卸载一份外挂字幕（并把它从主/副通道上摘掉）。
  Future<void> _removeExternalSubtitle(String id) async {
    final ext = _externalById(id);
    if (ext == null) return;
    if (_primarySubId == id) await _selectPrimarySubtitle('none', showOsd: false);
    if (_secondarySubId == id) {
      await _selectSecondarySubtitle('none', showOsd: false);
    }
    _externalSubs.remove(ext);
    if (mounted) {
      setState(() {});
      _showOsd('已移除外挂字幕：${ext.name}');
    }
    unawaited(_persistExternalSubtitles());
  }

  /// 微调外挂字幕的时间轴偏移（正数 = 字幕整体延后）。
  Future<void> _nudgeExternalOffset(String id, int deltaMs) async {
    final ext = _externalById(id);
    if (ext == null) return;
    final next = (ext.offsetMs + deltaMs).clamp(-30000, 30000);
    if (next == ext.offsetMs) return;
    ext.offsetMs = next;
    _applyExternalOffset(ext);
    if (ext.rendersNatively && _primarySubId == id) {
      await _syncMpvSubtitleDelay();
    }
    if (mounted) {
      setState(() {});
      _showOsd('${ext.name} 偏移 ${_formatOffsetLabel(next)}');
    }
    unawaited(_persistExternalSubtitles());
  }

  /// 把外挂字幕的时间轴偏移归零。
  Future<void> _resetExternalOffset(String id) async {
    final ext = _externalById(id);
    if (ext == null || ext.offsetMs == 0) return;
    ext.offsetMs = 0;
    _applyExternalOffset(ext);
    if (ext.rendersNatively && _primarySubId == id) {
      await _syncMpvSubtitleDelay();
    }
    if (mounted) {
      setState(() {});
      _showOsd('${ext.name} 偏移已归零');
    }
    unawaited(_persistExternalSubtitles());
  }

  /// 「改为纯文本模式」：把当前主字幕从原生渲染降级成叠层文本。
  ///
  /// 特效/图形字幕走原生渲染虽然保真，但会挡住 AI 字幕；这一步用 ffmpeg 把文字
  /// 抠出来（样式、定位、特效丢失），换回"可以和 AI 字幕并排"的能力。
  Future<void> _convertPrimaryToPlainText() async {
    if (!_isExclusivePrimary || !_canConvertPrimaryToText) return;
    final id = _primarySubId;
    final builtin = _parseBuiltinId(id);

    if (builtin != null) {
      final label = _primarySubtitleLabel();
      // 内置轨没有"模式"可言：改选它的文本化变体即可
      await _selectPrimarySubtitle(
        'builtin_${builtin.index}_text',
        showOsd: false,
      );
      if (!mounted) return;
      if (_parseBuiltinId(_primarySubId)?.text != true) return; // 提取失败已自行提示
      _showOsd('已将 $label 切换为纯文本模式');
    } else {
      final ext = _externalById(id);
      if (ext == null) return;
      if (ext.kind == ExternalSubtitleKind.graphics) {
        if (mounted) _showOsd('图形位图字幕无法转为文本，只能由底层原生渲染');
        return;
      }
      ext.plainText = true;
      final ok = await _ensureExternalTextLoaded(ext);
      if (!ok) {
        ext.plainText = false;
        if (mounted) _showOsd('该字幕无法转为文本，仍按原生特效渲染');
        return;
      }
      await _selectPrimarySubtitle(id, showOsd: false);
      if (!mounted) return;
      _showOsd('已将 ${ext.name} 切换为纯文本模式');
      unawaited(_persistExternalSubtitles());
    }

    // 顺手把已经就绪的 AI 字幕挂成副字幕，省得用户再点一次
    String? aiLabel;
    if (_hasTranslation) {
      await _selectSecondarySubtitle('ai_translation', showOsd: false);
      aiLabel = 'AI 翻译字幕';
    } else if (_hasAiOriginal) {
      await _selectSecondarySubtitle('ai_original', showOsd: false);
      aiLabel = 'AI 语音原字幕';
    }
    if (!mounted) return;
    _showOsd(
      aiLabel == null
          ? '已切换为纯文本模式，现在可以选择 AI 字幕了'
          : '已切换为纯文本模式，并把 $aiLabel 挂为副字幕',
    );
  }

  /// 打探这个视频该不该自动挂外挂字幕（只看路径，不读字幕内容）。
  ///
  /// 优先用"上次的选择"记忆（含模式与偏移），没有记忆才扫同目录同名文件。
  /// 返回 null 表示这次没有任何可用的外挂字幕。
  Future<({ExternalSubtitleMemory memory, List<String> paths, bool fromMemory})?>
      _planExternalSubtitles(String videoPath) async {
    try {
      final memory = await ExternalSubtitleStore.load(videoPath);
      final paths = <String>[];
      for (final record in memory.records) {
        if (await ExternalSubtitleLoader.exists(record.path)) {
          paths.add(record.path);
        }
      }
      if (paths.isNotEmpty) {
        return (memory: memory, paths: paths, fromMemory: true);
      }
      final siblings = await ExternalSubtitleLoader.findSiblingSubtitles(
        videoPath,
        limit: 2,
      );
      if (siblings.isEmpty) return null;
      return (
        memory: const ExternalSubtitleMemory(),
        paths: siblings,
        fromMemory: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 外挂字幕没挂上时，把"外挂字幕优先"的位子还给内嵌 / AI 字幕的自动选择。
  Future<void> _releaseExternalPriority() async {
    if (_externalPlan == null) return;
    _externalPlan = null;
    _autoSubtitleApplied = false;
    await _maybeAutoSelectSubtitle();
    if (!mounted) return;
    _aiCacheChecked = false;
    _scheduleAiSubtitleRestore();
  }

  /// 等媒体元数据到位（时长或字幕轨已经报上来）。
  ///
  /// 自动挂外挂字幕发生在 `open()` 刚返回时，此时 mpv 可能还没解析完文件头，
  /// 这个时机调 `sub-add` 会失败；等一小会儿再挂就稳了。
  Future<void> _awaitMediaReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (mounted && !_durationKnown && _subtitleTracks.isEmpty) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// 打开视频后恢复 / 匹配外挂字幕。
  ///
  /// 优先级：**外挂字幕 > 内嵌字幕 > AI 字幕**。
  ///  1. 上次给这个视频挂过外挂字幕（记忆里存着）→ 按原样恢复（模式、偏移、所在通道）；
  ///  2. 没有记忆 → 在同目录找同名外挂字幕（`movie.mp4` → `movie.srt`），命中就自动挂上；
  ///  3. 都没有 → 什么都不做，交回给内嵌 / AI 字幕的既有自动选择逻辑。
  Future<void> _maybeAutoLoadExternalSubtitles(String videoPath) async {
    if (_externalRestoreApplied) return;
    _externalRestoreApplied = true;

    final plan = _externalPlan;
    if (plan == null) return; // 起播前打探过：这个视频没有可用的外挂字幕

    try {
      await _awaitMediaReady();
      if (!mounted) return;

      if (plan.fromMemory) {
        final memory = plan.memory;
        final restored = <({int index, _ExternalSub ext})>[];
        for (var i = 0; i < memory.records.length; i++) {
          final record = memory.records[i];
          if (!await ExternalSubtitleLoader.exists(record.path)) continue;
          final ext = await _loadExternalSubtitle(
            record.path,
            plainText: record.plainText,
            offsetMs: record.offsetMs,
          );
          if (ext != null) restored.add((index: i, ext: ext));
        }

        if (restored.isNotEmpty) {
          // 记忆里存的是"当时那份清单的下标"，有文件加载失败时下标会错位，
          // 所以按原下标回查，最多退化成"只把文件备着不显示"。
          final primary = restored
              .where((r) => r.index == memory.primaryIndex)
              .firstOrNull
              ?.ext;
          final secondary = restored
              .where((r) => r.index == memory.secondaryIndex)
              .firstOrNull
              ?.ext;

          if (primary == null && secondary == null) {
            // 上次这些文件挂着但没用在任何通道上（用户后来关掉了全部字幕之类）：
            // 只把它们放回列表备选，不擅自弹出来显示。
            return;
          }
          if (primary != null) {
            await _selectPrimarySubtitle(_externalIdOf(primary), showOsd: false);
          }
          if (secondary != null && secondary != primary) {
            await _selectSecondarySubtitle(
              _externalIdOf(secondary),
              showOsd: false,
            );
          }
          if (!mounted) return;
          if (_hasExternalActive) {
            _showOsd('已恢复外挂字幕：${restored.map((r) => r.ext.name).join('、')}');
            return;
          }
        }
      } else {
        // 同目录同名：最多自动挂 2 份（原文 + 译文这种组合），第一份作主字幕
        _ExternalSub? first;
        for (final path in plan.paths) {
          final ext = await _loadExternalSubtitle(path);
          first ??= ext;
        }
        if (first != null && mounted) {
          await _selectPrimarySubtitle(_externalIdOf(first), showOsd: false);
          if (!mounted) return;
          if (_hasExternalPrimary) {
            _showOsd('已自动加载同名字幕：${first.name}');
            return;
          }
        }
      }

      // 一份都没挂上（文件损坏、格式不受支持、mpv 拒收…）：
      // 把优先权还给内嵌 / AI 字幕，别让这个视频一条字幕都没有。
      await _releaseExternalPriority();
    } catch (_) {
      // 自动匹配失败不影响播放
      await _releaseExternalPriority();
    }
  }

  /// 把当前的外挂字幕状态记到磁盘（路径、模式、偏移、所在通道）。
  Future<void> _persistExternalSubtitles() async {
    try {
      if (_externalSubs.isEmpty) {
        await ExternalSubtitleStore.clear(_sourcePath);
        return;
      }
      final primary = _externalById(_primarySubId);
      final secondary = _externalById(_secondarySubId);
      await ExternalSubtitleStore.save(
        _sourcePath,
        ExternalSubtitleMemory(
          records: _externalSubs
              .map((e) => ExternalSubtitleRecord(
                    path: e.path,
                    plainText: e.plainText,
                    offsetMs: e.offsetMs,
                  ))
              .toList(growable: false),
          primaryIndex:
              primary == null ? null : _externalSubs.indexOf(primary),
          secondaryIndex:
              secondary == null ? null : _externalSubs.indexOf(secondary),
        ),
      );
    } catch (_) {
      // 落盘失败不影响本次播放
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
    // 外挂字幕优先：已经挂上、或者这次预计会自动挂外挂字幕（[_externalPlan]）时，
    // 内嵌字幕都不去抢主字幕位——否则两条 mpv 命令抢 sid，谁后到谁赢，
    // 会出现"面板里勾着外挂字幕、画面却是内置字幕"。
    if (_hasExternalPrimary || _externalPlan != null) return;
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
      if (_subtitleTracks.isEmpty &&
          _primarySubId == 'none' &&
          !_hasExternalActive) {
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

    if (_subtitleTracks.isNotEmpty || _hasExternalActive || _externalPlan != null) {
      // 已有内嵌字幕 / 已挂（或将挂）外挂字幕时它们为主，AI 字幕只做"静默就绪"
      // —— 缓存已经读进生成器，用户点一下 AI 字幕就能立刻显示。
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
  /// 控制条处于隐藏状态时还有一道"快速划动"门槛（见 [_kPointerWakeDistance]）：
  /// 只有 [_kPointerWakeWindow]（2 秒）之内累计划够距离才唤出；慢慢挪动的话
  /// 每个窗口到期就被清零，攒不够，于是不会被轻微晃动/手抖唤出来。
  /// 直接点一下画面同样可以唤出（走 [_handleSurfaceTap]）。
  void _onPointerActivity(PointerHoverEvent event) {
    final pos = event.position;
    final prev = _lastPointerPos;
    // 每次都记：这样"隐藏瞬间的位置"始终是最新的
    _lastPointerPos = pos;

    if (!_controlsVisible) {
      final now = DateTime.now();
      final windowStart = _pointerWakeWindowStart;
      if (windowStart == null) {
        // 刚隐藏后的第一帧：开窗，从 0 开始累计
        _pointerWakeWindowStart = now;
        _pointerWakeAccum = 0;
        return;
      }
      if (now.difference(windowStart) > _kPointerWakeWindow) {
        // 窗口到期（说明移动得慢，中间有大段停顿或位移很小）：清零重开
        _pointerWakeWindowStart = now;
        _pointerWakeAccum = 0;
        return;
      }
      // 窗口内继续累加这一小段的位移
      if (prev != null) {
        _pointerWakeAccum += (pos - prev).distance;
      }
      if (_pointerWakeAccum < _kPointerWakeDistance) return;
      // 攒够了：唤出，并把窗口清零（下次隐藏后重新累计）
      _pointerWakeWindowStart = null;
      _pointerWakeAccum = 0;
    }

    final now = DateTime.now();
    if (now.difference(_lastPointerActivity).inMilliseconds < 250) return;
    _lastPointerActivity = now;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleAutoHide();
  }

  /// 隐藏控制条（同时把"快速划动唤回"的累计窗口清零）。
  void _hideControls() {
    _cancelAutoHide();
    if (!_controlsVisible) return;
    setState(() => _controlsVisible = false);
    _pointerWakeWindowStart = null;
    _pointerWakeAccum = 0;
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
    final screenSize = MediaQuery.sizeOf(context);
    final isEffectiveLandscape = _isLandscape && (screenSize.width > screenSize.height);
    final isPortraitMobile = isMobilePlatform && !isEffectiveLandscape;
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
            // 主字幕走 mpv 原生渲染时（内置轨 / 原生特效外挂），叠层不再画主通道，
            // 并整体抬高，给画面底部那些原生字幕让位。
            primaryEntries:
                _isNativePrimary ? null : _getEntriesForSubId(_primarySubId),
            secondaryEntries: _getEntriesForSubId(_secondarySubId),
            bottomOffset: _isNativePrimary ? 132 : 80,
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
              ? _buildMobileTrackControls(isCompact: isPortraitMobile)
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
  Widget _buildMobileTrackControls({bool isCompact = false}) {
    final audioTracks = _audioTracks;
    final iconConstraints = isCompact
        ? const BoxConstraints(minWidth: 34, minHeight: 34)
        : null;
    final iconPadding = isCompact
        ? const EdgeInsets.all(5)
        : const EdgeInsets.all(8);
    final iconSize = isCompact ? 20.0 : 24.0;
    final visualDensity = isCompact ? VisualDensity.compact : null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          constraints: iconConstraints,
          padding: iconPadding,
          visualDensity: visualDensity,
          iconSize: iconSize,
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
          constraints: iconConstraints,
          padding: iconPadding,
          visualDensity: visualDensity,
          iconSize: iconSize,
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
            constraints: iconConstraints,
            padding: iconPadding,
            visualDensity: visualDensity,
            iconSize: iconSize,
            onPressed: _showAiSubtitleSheet,
            tooltip: _aiButtonTooltip,
            icon: _aiSubtitleRunning
                ? SizedBox(
                    width: isCompact ? 17 : 20,
                    height: isCompact ? 17 : 20,
                    child: CircularProgressIndicator(
                      strokeWidth: isCompact ? 1.8 : 2,
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
    // 有几步操作要"先关面板 → 执行 → 再弹回来"（选文件、移除、转纯文本）：
    // 系统文件选择器会被模态面板压住点不到，而执行完用户也要立刻看到列表刷新。
    Future<void> Function()? pendingAction;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202027),
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: _SubtitleSettingsSheet(
          primarySubId: _primarySubId,
          secondarySubId: _secondarySubId,
          hasTranslation: _hasTranslation,
          hasAiOriginal: _hasAiOriginal,
          subtitleTracks: _subtitleTracks,
          externalSubs: _externalSubs
              .map((e) => _ExternalSubItem(
                    id: _externalIdOf(e),
                    name: e.name,
                    plainTextMode: !e.rendersNatively,
                    graphics: e.kind == ExternalSubtitleKind.graphics,
                    bitmapUnsupported: e.kind == ExternalSubtitleKind.graphics &&
                        _bitmapSubtitleUnsupported,
                    offsetMs: e.offsetMs,
                  ))
              .toList(growable: false),
          aiDisabled: _isExclusivePrimary,
          aiDisabledHint: _exclusivePrimaryHint,
          canConvertToText: _isExclusivePrimary && _canConvertPrimaryToText,
          bitmapUnsupported: _bitmapSubtitleUnsupported,
          onSelectPrimary: (id) => _selectPrimarySubtitle(id),
          onSelectSecondary: (id) => _selectSecondarySubtitle(id),
          onCloseAll: _closeAllSubtitles,
          formatTrackLabel: _subtitleLabel,
          onLoadExternal: () {
            pendingAction = _pickExternalSubtitle;
            Navigator.of(context).pop();
          },
          onRemoveExternal: (id) {
            pendingAction = () => _removeExternalSubtitle(id);
            Navigator.of(context).pop();
          },
          onConvertToPlainText: () {
            pendingAction = _convertPrimaryToPlainText;
            Navigator.of(context).pop();
          },
          onNudgeOffset: (id, deltaMs) => _nudgeExternalOffset(id, deltaMs),
          onResetOffset: (id) => _resetExternalOffset(id),
        ),
      ),
    );

    final action = pendingAction;
    if (action == null || !mounted) return;
    await action();
    if (!mounted) return;
    // 回到字幕面板：用户能立刻看到新条目 / 新的模式与偏移
    await _showSubtitleSettingsSheet();
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
    final screenSize = MediaQuery.sizeOf(context);
    final isEffectiveLandscape = isLandscape && (screenSize.width > screenSize.height);
    final isPortraitMobile = isMobilePlatform && !isEffectiveLandscape;

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
                        // 仅在横屏真正就绪或桌面端保留底部播放按钮（防止旋转瞬间宽度未变导致溢出）。
                        if (isDesktopPlatform || isEffectiveLandscape) ...[
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
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: isPortraitMobile ? 11.5 : 13,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          ' / ${_formatDuration(duration)}',
                          style: TextStyle(
                            color: const Color(0xFFCAC7D0),
                            fontSize: isPortraitMobile ? 11.5 : 13,
                            fontFeatures: const [FontFeature.tabularFigures()],
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
                            padding: EdgeInsets.symmetric(
                              horizontal: isPortraitMobile ? 7 : 12,
                              vertical: isPortraitMobile ? 4 : 8,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            '${speed.toStringAsFixed(speed % 1 == 0 ? 0 : 2)}x',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: isPortraitMobile ? 11.5 : 14,
                            ),
                          ),
                        ),
                        if (showOrientationToggle) ...[
                          SizedBox(width: isPortraitMobile ? 2 : 4),
                          IconButton(
                            constraints: isPortraitMobile
                                ? const BoxConstraints(minWidth: 34, minHeight: 34)
                                : null,
                            padding: isPortraitMobile
                                ? const EdgeInsets.all(5)
                                : const EdgeInsets.all(8),
                            visualDensity: isPortraitMobile
                                ? VisualDensity.compact
                                : null,
                            iconSize: isPortraitMobile ? 20.0 : 24.0,
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
      top: false,
      left: false,
      right: false,
      bottom: true,
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
      top: false,
      left: false,
      right: false,
      bottom: true,
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

/// 播放页已加载的一份外挂字幕。
class _ExternalSub {
  _ExternalSub({
    required this.uid,
    required this.path,
    required this.name,
    required this.kind,
    this.plainText = false,
    this.offsetMs = 0,
  });

  /// 稳定标识（自增编号），用来拼出字幕源 ID。
  ///
  /// 不用列表下标：移掉一份外挂字幕后其余下标会整体前移，
  /// 已经选在主/副通道上的那个 ID 就会指到别人身上。
  final int uid;

  /// 字幕文件路径。
  final String path;

  /// 文件名（界面显示用）。
  final String name;

  /// 文件本身的渲染类别（`.ass` / `.ssa` 是特效字幕）。
  final ExternalSubtitleKind kind;

  /// 是否被用户切成了"纯文本模式"（只对特效字幕有意义）。
  bool plainText;

  /// 时间轴偏移（毫秒，正数 = 字幕整体延后）。
  int offsetMs;

  /// 交给 mpv 的地址：非 UTF-8 的 `.ass` 会先转成 UTF-8 副本。
  String? mpvPath;

  /// 成功挂到 mpv 上之后，那条轨在 mpv 里的 id（用于避免重复 `sub-add`）。
  String? mpvTrackId;

  /// 解析出来的条目（不含偏移）。
  List<SubtitleEntry>? baseEntries;

  /// 叠加过偏移、可直接喂给叠层的条目（偏移一变就整批重建）。
  List<SubtitleEntry>? displayEntries;

  /// 是否交给 mpv 原生渲染。
  ///
  /// 图形位图字幕（`.sup`/VobSub）只能走这条路；特效字幕（`.ass`）默认也走，
  /// 但可以切成纯文本模式改走叠层。
  bool get rendersNatively =>
      kind == ExternalSubtitleKind.graphics ||
      (kind == ExternalSubtitleKind.effects && !plainText);
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
    required this.externalSubs,
    required this.aiDisabled,
    required this.aiDisabledHint,
    required this.canConvertToText,
    required this.bitmapUnsupported,
    required this.onSelectPrimary,
    required this.onSelectSecondary,
    required this.onCloseAll,
    required this.onLoadExternal,
    required this.onRemoveExternal,
    required this.onConvertToPlainText,
    required this.onNudgeOffset,
    required this.onResetOffset,
    required this.formatTrackLabel,
  });

  final String primarySubId;
  final String secondarySubId;
  final bool hasTranslation;
  final bool hasAiOriginal;
  final List<SubtitleTrack> subtitleTracks;

  /// 已加载的外挂字幕（主/副下拉里的候选 + 面板下方的偏移调节）。
  final List<_ExternalSubItem> externalSubs;

  /// 当前主字幕是特效/图形原生字幕：AI 字幕不可选（见 [aiDisabledHint]）。
  final bool aiDisabled;
  final String aiDisabledHint;

  /// 能否把当前主字幕降级成纯文本（图形位图字幕做不到）。
  final bool canConvertToText;

  /// 本机播放内核已证实渲染不了图形位图字幕（面板里如实标出来）。
  final bool bitmapUnsupported;

  final ValueChanged<String> onSelectPrimary;
  final ValueChanged<String> onSelectSecondary;
  final VoidCallback onCloseAll;
  final VoidCallback onLoadExternal;
  final ValueChanged<String> onRemoveExternal;
  final VoidCallback onConvertToPlainText;
  final void Function(String id, int deltaMs) onNudgeOffset;
  final ValueChanged<String> onResetOffset;
  final String Function(SubtitleTrack) formatTrackLabel;

  @override
  State<_SubtitleSettingsSheet> createState() => _SubtitleSettingsSheetState();
}

/// 面板用的外挂字幕条目（只带界面需要的信息）。
class _ExternalSubItem {
  const _ExternalSubItem({
    required this.id,
    required this.name,
    required this.plainTextMode,
    this.graphics = false,
    this.bitmapUnsupported = false,
    required this.offsetMs,
  });

  final String id;
  final String name;

  /// 是否处于纯文本模式（false = 交底层原生渲染，保特效但独占画面）。
  final bool plainTextMode;

  /// 图形位图字幕（`.sup` / VobSub）：原生渲染、且无法转文本。
  final bool graphics;

  /// 本机播放内核已证实渲染不了这类图形字幕（面板里如实标出来）。
  final bool bitmapUnsupported;

  final int offsetMs;
}

class _SubtitleSettingsSheetState extends State<_SubtitleSettingsSheet> {
  late String _currentPrimary;
  late String _currentSecondary;

  /// 点了置灰项时的临时提示（null 表示不显示）。
  String? _disabledNotice;

  @override
  void initState() {
    super.initState();
    _currentPrimary = widget.primarySubId;
    _currentSecondary = widget.secondarySubId;
  }

  void _choosePrimary(String id) {
    if (_isDisabled(id)) {
      setState(() => _disabledNotice = widget.aiDisabledHint);
      return;
    }
    setState(() {
      _disabledNotice = null;
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
    if (_isDisabled(id)) {
      setState(() => _disabledNotice = widget.aiDisabledHint);
      return;
    }
    setState(() {
      _disabledNotice = null;
      _currentSecondary = id;
      // 若主字幕正好选了同一个有效字幕，则自动重置主字幕为关闭
      if (id != 'none' && _currentPrimary == id) {
        _currentPrimary = 'none';
        widget.onSelectPrimary('none');
      }
    });
    widget.onSelectSecondary(id);
  }

  /// AI 字幕在主字幕是特效/图形原生字幕时不可选（会互相遮挡）。
  bool _isDisabled(String id) =>
      widget.aiDisabled && (id == 'ai_original' || id == 'ai_translation');

  /// 外挂字幕在下拉里的条目：区分外挂·图形 / 外挂·特效 / 外挂（纯文本）。
  _SubDropdownItem _externalItem(_ExternalSubItem sub) => _SubDropdownItem(
        id: sub.id,
        label: sub.name,
        badge: sub.graphics ? '外挂·图形' : (sub.plainTextMode ? '外挂' : '外挂·特效'),
        badgeColor: sub.graphics
            ? const Color(0xFFBF360C)
            : (sub.plainTextMode
                ? const Color(0xFF1565C0)
                : const Color(0xFF8E24AA)),
      );

  /// 内置轨的"纯文本"条目。
  ///
  /// 它只能通过提示条上的按钮切过去（不是常规候选），所以只在正被选中时补进
  /// 下拉——否则列表里会凭空多出一条几乎没人用的项。
  List<_SubDropdownItem> _plainTextBuiltinItems(String currentPrimary) {
    if (!currentPrimary.startsWith('builtin_') ||
        !currentPrimary.endsWith('_text')) {
      return const [];
    }
    final index = int.tryParse(
      currentPrimary.substring(8, currentPrimary.length - '_text'.length),
    );
    if (index == null ||
        index < 0 ||
        index >= widget.subtitleTracks.length) {
      return const [];
    }
    return [
      _SubDropdownItem(
        id: currentPrimary,
        label: '${widget.formatTrackLabel(widget.subtitleTracks[index])}（纯文本）',
        badge: '纯文本',
        badgeColor: const Color(0xFF1565C0),
      ),
    ];
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
      // 外挂字幕排在最上面：它是用户手动挑的 / 同目录同名匹配来的，优先级最高
      ...widget.externalSubs.map(_externalItem),
      if (widget.hasTranslation)
        _SubDropdownItem(
          id: 'ai_translation',
          label: 'AI 翻译字幕',
          badge: '已翻译',
          badgeColor: const Color(0xFF00796B),
          disabled: widget.aiDisabled,
        ),
      if (widget.hasAiOriginal)
        _SubDropdownItem(
          id: 'ai_original',
          label: 'AI 语音原字幕',
          badge: '已识别',
          badgeColor: PolyFlixColors.violet,
          disabled: widget.aiDisabled,
        ),
      ...widget.subtitleTracks.asMap().entries.map((entry) {
        final i = entry.key;
        final track = entry.value;
        final isGraphic = BuiltInSubtitleExtractor.isGraphicSubtitle(track);
        return _SubDropdownItem(
          id: 'builtin_$i',
          label: widget.formatTrackLabel(track),
          badge: isGraphic
              ? (widget.bitmapUnsupported ? '图形·本机不支持' : '图形')
              : null,
          badgeColor: const Color(0xFFBF360C),
        );
      }),
      // 内置轨的"纯文本"变体只在正被选中时列出来（它是从提示按钮切过去的，
      // 平时不该在列表里多占一行）
      ..._plainTextBuiltinItems(_currentPrimary),
    ];

    // 构建副字幕候选池（过滤掉图形字幕，副字幕仅提供可文本渲染的轨道）
    final allSecondaryItems = <_SubDropdownItem>[
      const _SubDropdownItem(id: 'none', label: '关闭副字幕'),
      // 外挂字幕同样排最上面
      ...widget.externalSubs.where((e) => e.plainTextMode).map(_externalItem),
      if (widget.hasAiOriginal)
        _SubDropdownItem(
          id: 'ai_original',
          label: 'AI 语音原字幕',
          badge: '已识别',
          badgeColor: PolyFlixColors.violet,
          disabled: widget.aiDisabled,
        ),
      if (widget.hasTranslation)
        _SubDropdownItem(
          id: 'ai_translation',
          label: 'AI 翻译字幕',
          badge: '已翻译',
          badgeColor: const Color(0xFF00796B),
          disabled: widget.aiDisabled,
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

    final isMobile = isMobilePlatform;

    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: true,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          isMobile ? 16 : 20,
          isMobile ? 0 : 6,
          isMobile ? 16 : 20,
          isMobile ? 12 : 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶栏：标题 + 加载外挂字幕 + 一键关闭全部
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(isMobile ? 5 : 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(isMobile ? 6 : 8),
                  ),
                  child: Icon(
                    Icons.subtitles_rounded,
                    color: theme.colorScheme.primary,
                    size: isMobile ? 17 : 20,
                  ),
                ),
                SizedBox(width: isMobile ? 8 : 10),
                // 用 Expanded 吃掉剩余宽度：窄屏上先省略标题，右侧按钮不会被挤爆
                Expanded(
                  child: Text(
                    '字幕设置',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isMobile ? 15.5 : 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.symmetric(horizontal: isMobile ? 6 : 8),
                  ),
                  onPressed: widget.onLoadExternal,
                  icon: Icon(Icons.add_rounded, size: isMobile ? 14 : 16),
                  label: Text(
                    '加载字幕',
                    style: TextStyle(fontSize: isMobile ? 11.5 : 12.5),
                  ),
                ),
                if (!isNone)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent.shade100,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _closeAll,
                    icon: Icon(Icons.subtitles_off_outlined, size: isMobile ? 14 : 16),
                    label: Text(
                      '关闭全部',
                      style: TextStyle(fontSize: isMobile ? 11.5 : 12.5),
                    ),
                  ),
              ],
            ),
            SizedBox(height: isMobile ? 8 : 12),
            const Divider(color: Colors.white10, height: 1),
            SizedBox(height: isMobile ? 10 : 14),

            // 1. 主字幕板块（上层 · 大号）
            _buildSectionHeader(
              icon: Icons.vertical_align_top_rounded,
              title: '主字幕',
              subTitle: '显示在上方 · 主要阅读',
              theme: theme,
              isMobile: isMobile,
            ),
            SizedBox(height: isMobile ? 6 : 8),
            _buildDropdown(
              selectedValue: effectivePrimary,
              items: primaryItems,
              onChanged: _choosePrimary,
              theme: theme,
              isMobile: isMobile,
            ),

            SizedBox(height: isMobile ? 10 : 14),

            // 2. 副字幕板块（下层 · 对照辅助）
            _buildSectionHeader(
              icon: Icons.vertical_align_bottom_rounded,
              title: '副字幕',
              subTitle: '显示在下方 · 对照辅助',
              theme: theme,
              isMobile: isMobile,
            ),
            SizedBox(height: isMobile ? 6 : 8),
            _buildDropdown(
              selectedValue: effectiveSecondary,
              items: secondaryItems,
              onChanged: _chooseSecondary,
              theme: theme,
              isMobile: isMobile,
            ),

            // 3. 特效/图形字幕独占时的说明与"降级成纯文本"入口
            if (widget.aiDisabled) ...[
              SizedBox(height: isMobile ? 10 : 14),
              _buildExclusiveHint(theme, isMobile),
            ],

            // 4. 已加载的外挂字幕：模式说明 + 时间轴偏移微调 + 移除
            if (widget.externalSubs.isNotEmpty) ...[
              SizedBox(height: isMobile ? 10 : 14),
              _buildExternalCard(theme, isMobile),
            ],

            SizedBox(height: isMobile ? 10 : 14),
            Center(
              child: Text(
                '提示：主字幕在上方、副字幕在下方。图形类字幕仅能在主字幕中由底层硬件直接渲染。',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: isMobile ? 10.5 : 11.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 主字幕是特效/图形原生字幕时的说明卡片。
  ///
  /// 顺带承载"点了置灰项"的即时反馈：文案换成对应提示并高亮，
  /// 让用户知道不是点不动，而是这条路当前走不通。
  Widget _buildExclusiveHint(ThemeData theme, bool isMobile) {
    final notice = _disabledNotice;
    final emphasized = notice != null;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2B2422),
        borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
        border: Border.all(
          color: const Color(0xFFFFB74D).withValues(alpha: emphasized ? .75 : .35),
        ),
      ),
      padding: EdgeInsets.all(isMobile ? 10 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                emphasized
                    ? Icons.report_problem_outlined
                    : Icons.info_outline_rounded,
                size: isMobile ? 14 : 16,
                color: const Color(0xFFFFB74D),
              ),
              SizedBox(width: isMobile ? 6 : 8),
              Expanded(
                child: Text(
                  notice ?? widget.aiDisabledHint,
                  style: TextStyle(
                    color: emphasized ? const Color(0xFFFFCC80) : Colors.white70,
                    fontSize: isMobile ? 11 : 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
          if (widget.canConvertToText) ...[
            SizedBox(height: isMobile ? 8 : 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 12),
                ),
                onPressed: widget.onConvertToPlainText,
                icon: Icon(Icons.text_fields_rounded, size: isMobile ? 14 : 16),
                label: Text(
                  '改为纯文本并显示 AI 字幕',
                  style: TextStyle(fontSize: isMobile ? 11 : 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 已加载的外挂字幕卡片：模式说明 + 时间轴偏移微调 + 移除。
  Widget _buildExternalCard(ThemeData theme, bool isMobile) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF262630),
        borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
        border: Border.all(color: Colors.white12),
      ),
      padding: EdgeInsets.all(isMobile ? 10 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: isMobile ? 14 : 16,
                color: Colors.white54,
              ),
              SizedBox(width: isMobile ? 6 : 8),
              Text(
                '外挂字幕',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: isMobile ? 12.5 : 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: isMobile ? 6 : 8),
              Expanded(
                child: Text(
                  '时间轴偏移按文件单独记忆',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: isMobile ? 10 : 11,
                  ),
                ),
              ),
            ],
          ),
          for (final sub in widget.externalSubs) ...[
            SizedBox(height: isMobile ? 8 : 10),
            _buildExternalRow(sub, theme, isMobile),
          ],
        ],
      ),
    );
  }

  Widget _buildExternalRow(_ExternalSubItem sub, ThemeData theme, bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                sub.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: isMobile ? 12 : 13,
                ),
              ),
            ),
            SizedBox(width: isMobile ? 6 : 8),
            Text(
              sub.graphics
                  ? (sub.bitmapUnsupported
                      ? '图形字幕 · 本机内核不支持'
                      : '图形字幕 · 独占画面')
                  : (sub.plainTextMode ? '纯文本 · 可与 AI 并排' : '原生特效 · 独占画面'),
              style: TextStyle(
                color: Colors.white38,
                fontSize: isMobile ? 9.5 : 10.5,
              ),
            ),
          ],
        ),
        SizedBox(height: isMobile ? 6 : 8),
        Row(
          children: [
            _buildOffsetButton('-0.5s', () => widget.onNudgeOffset(sub.id, -500), isMobile),
            SizedBox(width: isMobile ? 5 : 6),
            Text(
              _formatOffsetLabel(sub.offsetMs),
              style: TextStyle(
                color: sub.offsetMs == 0 ? Colors.white38 : theme.colorScheme.primary,
                fontSize: isMobile ? 11 : 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: isMobile ? 5 : 6),
            _buildOffsetButton('+0.5s', () => widget.onNudgeOffset(sub.id, 500), isMobile),
            SizedBox(width: isMobile ? 5 : 6),
            _buildOffsetButton('归零', () => widget.onResetOffset(sub.id), isMobile),
            const Spacer(),
            IconButton(
              onPressed: () => widget.onRemoveExternal(sub.id),
              tooltip: '移除此字幕',
              visualDensity: VisualDensity.compact,
              iconSize: isMobile ? 16 : 18,
              color: Colors.redAccent.shade100,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ],
    );
  }

  /// 时间轴偏移微调用的小按钮。
  Widget _buildOffsetButton(String label, VoidCallback onTap, bool isMobile) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: Colors.white70,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 8 : 10,
          vertical: 2,
        ),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: const BorderSide(color: Colors.white24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onPressed: onTap,
      child: Text(label, style: TextStyle(fontSize: isMobile ? 10.5 : 11.5)),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String subTitle,
    required ThemeData theme,
    required bool isMobile,
  }) {
    return Row(
      children: [
        Icon(icon, size: isMobile ? 14.5 : 16, color: theme.colorScheme.primary),
        SizedBox(width: isMobile ? 5 : 6),
        Text(
          title,
          style: TextStyle(
            color: Colors.white,
            fontSize: isMobile ? 13 : 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(width: isMobile ? 6 : 8),
        Text(
          subTitle,
          style: TextStyle(
            color: Colors.white54,
            fontSize: isMobile ? 11 : 12,
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown({
    required String selectedValue,
    required List<_SubDropdownItem> items,
    required ValueChanged<String> onChanged,
    required ThemeData theme,
    required bool isMobile,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF262630),
        borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
        border: Border.all(color: Colors.white12),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 14,
        vertical: isMobile ? 0 : 2,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: selectedValue,
          focusColor: Colors.transparent,
          dropdownColor: const Color(0xFF262630),
          borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
          menuMaxHeight: isMobile ? 240 : 320,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Colors.white70,
            size: isMobile ? 20 : 24,
          ),
          items: items.map((item) {
            final isSelected = item.id == selectedValue;
            return DropdownMenuItem<String>(
              value: item.id,
              child: Row(
                children: [
                  SizedBox(
                    width: isMobile ? 19 : 22,
                    child: isSelected
                        ? Icon(
                            Icons.check_rounded,
                            size: isMobile ? 15 : 17,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                  ),
                  SizedBox(width: isMobile ? 5 : 6),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isMobile ? 12 : 13,
                        // 置灰项：看得见但选不了（点了会在下方给出原因）
                        color: item.disabled
                            ? Colors.white24
                            : (isSelected ? Colors.white : Colors.white70),
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (item.badge != null) ...[
                    SizedBox(width: isMobile ? 6 : 8),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isMobile ? 4.5 : 5,
                        vertical: isMobile ? 1 : 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: item.disabled
                            ? Colors.white12
                            : (item.badgeColor ?? Colors.white24),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.badge!,
                        style: TextStyle(
                          fontSize: isMobile ? 8.5 : 9.5,
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
    this.disabled = false,
  });

  final String id;
  final String label;
  final String? badge;
  final Color? badgeColor;

  /// 置灰不可选（例如主字幕是特效/图形原生字幕时的 AI 字幕）。
  /// 仍然列在下拉里给出提示，而不是直接消失——否则用户会以为功能丢了。
  final bool disabled;
}
