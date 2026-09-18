import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'home/home_page.dart';
import 'settings/app_settings.dart';
import 'subtitle/ai_task_manager.dart';
import 'subtitle/device_capability.dart';
import 'subtitle/whisper_server.dart';
import 'utils/native_file_helper.dart';
import 'utils/platform_utils.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    MediaKit.ensureInitialized();
  } catch (_) {}
  // 初始化跨平台持久数据目录（Android 端映射到 filesDir，防止清理缓存误删播放列表与配置）
  await NativeFileHelper.initializeDataDir();
  // 桌面端需要 window_manager 才能按视频比例调整窗口大小；移动端没有该实现。
  if (isDesktopPlatform) {
    try {
      await windowManager.ensureInitialized();
    } catch (_) {
      // 初始化失败只是无法自动调整窗口，不影响其它功能。
    }
  }
  // 设置在首帧之前读上来，否则界面会先按默认值渲染再跳变。
  await loadAppSettings();
  // 恢复持久化的 AI 识别任务记录（历史记录 + 上次异常退出时的中断标记）
  await AiTaskManager.instance.loadPersisted();
  // 异步检查设备硬件能力：若不满足最低要求（如低配模拟器），强制将 AI 字幕总开关关闭
  detectDeviceCapabilities().then((caps) {
    if (!caps.meetsMinimumRequirements && aiSubtitleEnabled.value) {
      setAiSubtitleEnabled(false);
    }
  });
  runApp(const PolyFlixApp());
}

/// 应用统一的视觉色彩令牌。
abstract final class PolyFlixColors {
  static const violet = Color(0xFF6657E8);
  static const indigo = Color(0xFF3730A3);
  static const coral = Color(0xFFFF775F);
  static const softViolet = Color(0xFFE9E7FF);
  static const midnight = Color(0xFF12121C);
}

/// 基准字体族。
///
/// 不能用 'sans' —— 它不是任何平台的真实字体名（Android 上是 'sans-serif'，
/// Windows 上不存在这个名字）。Flutter 查不到这个字体后只能走系统回退，
/// 而回退链对个别简体字（例如"闭"）可能落到另一个字体上，表现为同一行里
/// 有的字粗、有的字细。这里显式指定自带完整简体字形的字体。
String? get _baseFontFamily =>
    isWindowsPlatform ? 'Microsoft YaHei' : null;

/// 基准字体缺字时的回退顺序：优先其它中文字体，避免落到西文字体上。
const List<String> _fontFallback = <String>[
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
];

enum AppThemeMode { light, dark, system }

class ThemeNotifier extends ChangeNotifier {
  AppThemeMode _mode = AppThemeMode.system;
  AppThemeMode get mode => _mode;

  void setMode(AppThemeMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
  }

  ThemeMode get themeMode {
    switch (_mode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }
}

final themeNotifier = ThemeNotifier();

class PolyFlixApp extends StatefulWidget {
  const PolyFlixApp({super.key});

  @override
  State<PolyFlixApp> createState() => _PolyFlixAppState();
}

class _PolyFlixAppState extends State<PolyFlixApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 退出应用前先关掉常驻的识别服务进程。
  ///
  /// whisper-server 是独立子进程，父进程退出它不会自动跟着退，
  /// 不清理会一直占着显存（GPU 引擎包场景）直到重启电脑。
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await WhisperServerSession.shutdownAny();
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeNotifier,
      builder: (context, _) {
        return MaterialApp(
          title: '影现播放器',
          debugShowCheckedModeBanner: false,
          themeMode: themeNotifier.themeMode,
          theme: _lightTheme(),
          darkTheme: _darkTheme(),
          home: const HomePage(),
        );
      },
    );
  }

  ThemeData _lightTheme() {
    const scheme = ColorScheme.light(
      primary: PolyFlixColors.violet,
      onPrimary: Colors.white,
      primaryContainer: PolyFlixColors.softViolet,
      onPrimaryContainer: PolyFlixColors.indigo,
      secondary: PolyFlixColors.coral,
      onSecondary: Colors.white,
      surface: Color(0xFFFFFBFF),
      onSurface: Color(0xFF1B1B25),
      surfaceContainerHighest: Color(0xFFEDECF3),
      outline: Color(0xFF787680),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF7F7FB),
      fontFamily: _baseFontFamily,
      fontFamilyFallback: _fontFallback,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Color(0xFF1B1B25),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1),
    );
  }

  ThemeData _darkTheme() {
    const scheme = ColorScheme.dark(
      primary: Color(0xFFC4BEFF),
      onPrimary: Color(0xFF27215A),
      primaryContainer: Color(0xFF46408E),
      onPrimaryContainer: Color(0xFFE4E1FF),
      secondary: Color(0xFFFFB4A5),
      onSecondary: Color(0xFF5F160B),
      surface: Color(0xFF12121C),
      onSurface: Color(0xFFE5E1EB),
      surfaceContainerHighest: Color(0xFF2A2934),
      outline: Color(0xFF928F99),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: PolyFlixColors.midnight,
      fontFamily: _baseFontFamily,
      fontFamilyFallback: _fontFallback,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Color(0xFFE5E1EB),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: const Color(0xFF1D1C27),
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF24232E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1),
    );
  }
}

class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  static const _labels = {
    AppThemeMode.system: '跟随系统',
    AppThemeMode.light: '浅色模式',
    AppThemeMode.dark: '深色模式',
  };

  static const _icons = {
    AppThemeMode.system: Icons.brightness_auto_rounded,
    AppThemeMode.light: Icons.light_mode_rounded,
    AppThemeMode.dark: Icons.dark_mode_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '切换外观',
      onPressed: () => _showThemeSheet(context),
      icon: Icon(_icons[themeNotifier.mode]),
    );
  }

  void _showThemeSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('外观模式', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              ...AppThemeMode.values.map(
                (mode) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(_icons[mode]),
                  title: Text(_labels[mode]!),
                  trailing: mode == themeNotifier.mode
                      ? Icon(Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  onTap: () {
                    themeNotifier.setMode(mode);
                    Navigator.of(sheetContext).pop();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
