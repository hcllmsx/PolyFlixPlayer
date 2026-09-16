# 影现播放器移动端 PolyFlixPlayer-Mobile

影现播放器 [PolyFlixPlayer](https://github.com/hcllmsx/PolyFlixPlayer) 的移动端版本 —— 基于 Flutter 开发的跨平台万能视频播放器，能够智能识别并播放影藏多态视频中“藏在里面的另一个视频”。

影藏：[hcllmsx/PolyFlix](https://github.com/hcllmsx/PolyFlix)，把文件藏进正常播放的 MP4 视频中。

影现播放器桌面版：[hcllmsx/PolyFlixPlayer](https://github.com/hcllmsx/PolyFlixPlayer)，基于 PySide6 + libmpv 的万能播放器。

## 功能特性

- **万能格式播放**：内置高性能 `media_kit` (基于 libmpv / FFmpeg)，通吃 MP4、MKV、MOV、FLV、WebM、AVI、TS 等全格式主流视频解码。
- **智能识别双视频**：导入视频时自动嗅探 PFLX 标识，瞬间识别隐藏视频内容；无需重命名、无需解压、无需输入密码即可直接解码播放。
- **一键提取与导出**：支持将影藏文件中的隐藏视频一键导出保存至手机本地存储或自定义文件夹。

## 快速开始

### 准备环境

- 安装 [Flutter SDK](https://docs.flutter.dev/get-started/install) (推荐 3.24+ / Dart 3.5+)
- 配置 Android SDK 开发环境

### 本地运行

```bash
# 1. 克隆仓库
git clone https://github.com/hcllmsx/PolyFlixPlayer-Mobile.git
cd PolyFlixPlayer-Mobile

# 2. 安装依赖
flutter pub get

# 3. 运行到连接的设备/模拟器
flutter run
```

### 打包发布

```bash
# 打包 Android APK (Release)
flutter build apk --release

# 打包 Android App Bundle (AAB)
flutter build appbundle --release
```

## 开源协议

本项目基于 [GNU General Public License v3.0](LICENSE)（GPL-3.0）开源。

这意味着你可以自由使用、学习、修改和再分发本项目的源代码，但任何基于本项目或其衍生部分的发行版本，也必须以 GPL-3.0 协议继续开源，并附带本协议全文。

## 致谢

本项目基于以下优秀的开源项目与框架构建，在此致以诚挚谢意：

| 项目 | 用途 | 主页 |
|------|------|------|
| [Flutter](https://flutter.dev/) | 跨平台移动端 UI 框架 | https://flutter.dev/ |
| [media_kit](https://github.com/media-kit/media-kit) | 基于 libmpv 的全平台视频播放内核 | https://github.com/media-kit/media-kit |
| [libmpv](https://github.com/mpv-player/mpv) / [FFmpeg](https://ffmpeg.org/) | 核心音视频解码渲染引擎 | https://mpv.io/ |
| [file_picker](https://github.com/miguelpruivo/flutter_file_picker) | 移动端原生文件选择与存储访问 | https://github.com/miguelpruivo/flutter_file_picker |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | 本地配置持久化 | https://pub.dev/packages/shared_preferences |
