# 影现播放器 PolyFlixPlayer

基于 Flutter 开发的跨平台万能视频播放器，支持 **Windows** 与 **Android**，能够智能识别并播放影藏多态视频中"藏在里面的另一个视频"。

> 本项目原为基于 PySide6 + libmpv 的 Windows 桌面播放器，现已在同一仓库内以 Flutter 重写，统一覆盖桌面端与移动端。

姊妹项目：[影藏 hcllmsx/PolyFlix](https://github.com/hcllmsx/PolyFlix) —— 把文件藏进正常播放的 MP4 视频中。

## 功能特性

- **跨平台**：一套代码同时覆盖 Windows 桌面端与 Android 移动端。
- **万能格式播放**：内置高性能 `media_kit`（基于 libmpv / FFmpeg），通吃 MP4、MKV、MOV、FLV、WebM、AVI、TS 等主流视频格式，支持硬件加速。
- **智能识别双视频**：导入视频时自动嗅探 PFLX 标识，瞬间识别隐藏视频内容；无需重命名、无需解压、无需输入密码即可直接解码播放，且全程流式播放、不落盘。
- **一键提取与导出**：支持将影藏文件中的隐藏视频一键导出保存至本地存储或自定义文件夹。
- **播放控制**：倍速调节、音轨 / 字幕轨切换、进度拖动。
- **桌面端体验**：键盘快捷键（空格 / ←→ / ↑↓ / M / Esc）、拖放换片、窗口自动适应视频比例。
- **移动端体验**：沉浸式全屏、横竖屏切换、点击画面显隐控件。

## 下载安装

前往 [Releases](https://github.com/hcllmsx/PolyFlixPlayer/releases) 下载对应平台的安装包：

| 平台 | 产物 |
|------|------|
| Windows | `PolyFlixPlayer-v*.zip`（解压后运行其中的 `PolyFlixPlayer.exe`） |
| Android | `PolyFlixPlayer-v*.apk`（universal 通用包，或按架构分包） |

## 从源码构建

### 准备环境

- 安装 [Flutter SDK](https://docs.flutter.dev/get-started/install)（推荐 3.24+ / Dart 3.5+）
- 构建 Windows 端：安装 Visual Studio，并勾选"使用 C++ 的桌面开发"工作负载
- 构建 Android 端：配置 Android SDK 开发环境

### 本地运行

```bash
# 1. 克隆仓库
git clone https://github.com/hcllmsx/PolyFlixPlayer.git
cd PolyFlixPlayer

# 2. 安装依赖
flutter pub get

# 3. 运行（择一）
flutter run -d windows   # Windows 桌面端
flutter run              # Android（需连接设备或模拟器）
```

### 打包发布

```bash
# Windows 发布版
flutter build windows --release

# Android 通用 APK
flutter build apk --release

# Android 按架构分包 APK
flutter build apk --split-per-abi

# Android App Bundle（Google Play）
flutter build appbundle --release
```

## 开源协议

本项目基于 [GNU General Public License v3.0](LICENSE)（GPL-3.0）开源。

这意味着你可以自由使用、学习、修改和再分发本项目的源代码，但任何基于本项目或其衍生部分的发行版本，也必须以 GPL-3.0 协议继续开源，并附带本协议全文。

## 致谢

本项目基于以下优秀的开源项目与框架构建，在此致以诚挚谢意：

| 项目 | 用途 | 主页 |
|------|------|------|
| [Flutter](https://flutter.dev/) | 跨平台 UI 框架 | https://flutter.dev/ |
| [media_kit](https://github.com/media-kit/media-kit) | 基于 libmpv 的全平台视频播放内核 | https://github.com/media-kit/media-kit |
| [libmpv](https://github.com/mpv-player/mpv) / [FFmpeg](https://ffmpeg.org/) | 核心音视频解码渲染引擎 | https://mpv.io/ |
| [file_picker](https://github.com/miguelpruivo/flutter_file_picker) | 原生文件选择与存储访问 | https://github.com/miguelpruivo/flutter_file_picker |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | 本地配置持久化 | https://pub.dev/packages/shared_preferences |
| [window_manager](https://github.com/leanflutter/window_manager) | 桌面端窗口控制 | https://github.com/leanflutter/window_manager |
| [desktop_drop](https://github.com/MixinNetwork/flutter-plugins) | 桌面端拖放文件 | https://github.com/MixinNetwork/flutter-plugins |
