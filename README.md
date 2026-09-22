# 影现播放器 PolyFlixPlayer

基于 Flutter 开发的跨平台万能视频播放器，支持 **Windows** 与 **Android**。

不仅支持播放几乎所有主流视频格式，还能够自动识别并播放影藏多态视频中“藏在里面的另一个视频”，并深度集成本地离线 AI 语音转录字幕、大模型智能翻译与双语字幕对照功能。

> 姊妹项目：[影藏 hcllmsx/PolyFlix](https://github.com/hcllmsx/PolyFlix) —— 把文件藏进正常播放的 MP4 视频中。

---

## 核心特性

- **万能格式播放**：基于高性能 `media_kit`（libmpv / FFmpeg 内核），支持 MP4、MKV、MOV、FLV、WebM、AVI、TS 等主流视频格式，支持硬件解码加速。
- **智能识别双视频**：自动嗅探视频文件中的 PFLX 影藏标识，免解压、免重命名、无需密码，直接以流式方式秒级解码播放隐藏视频，并支持一键提取导出。
- **本地 AI 语音转录**：基于 Whisper 实现完全离线的音频识别与时间戳对齐，全程无需联网保护隐私；设置页提供 33 个官方规格模型对照表（tiny ~ large-v3），支持按需导入与切换。
- **智能翻译与双语字幕**：
  - 支持多翻译引擎：集成**百度翻译**（支持大模型 LLM 与传统通用 NMT 双模式，支持智能提炼视频片名作为语义上下文辅助翻译）与 **Azure Translator**；
  - 双语对照显示：支持内置字幕与 AI 字幕、或识别原语与翻译译语同屏上下对齐显示；
  - 导出与管理：支持将生成字幕一键导出为标准 SRT 文件（原语、译语、双语对照），支持字幕缓存智能物理清理。
- **后台 AI 任务队列**：支持后台异步转录与“转录完成自动预约翻译”一体化流水线，主页状态栏实时跟踪进度，支持任务持久化管理与取消。
- **多端体验优化**：
  - **Windows 桌面端**：快捷键控制（空格/方向键/M/Esc 等）、拖放视频文件换片、窗口比例自适应。
  - **Android 移动端**：横竖屏旋转自适应、低高度屏幕弹窗防溢出优化、沉浸式全屏与手势控制。

---

## AI 语音与翻译说明

### 1. 语音识别引擎（CPU / GPU）
- **内置插件**：开箱即用，基于 CPU 多线程推理（自动根据 CPU 核心数调度 4~12 线程）。
- **可选 GPU 加速（Windows）**：支持导入 whisper.cpp 官方预编译包（如 CUDA 12.4 / 11.8），在设置页点「导入引擎」选择 zip 即可自动完成识别与安装，识别速度可提升数倍（以 RTX 40 系为例，1 小时音频约 40 秒完成）。

### 2. 模型导入
播放器安装包轻量纯净，不捆绑臃肿的模型权重。在「设置」或「AI 字幕面板」中可查看 33 个官方模型规格对照表，下载对应的 `.bin` 文件后通过「导入模型」即可快速载入。推荐：
- 追求速度与轻量：`ggml-tiny-q5_1.bin` 或 `ggml-base.bin`；
- 日常通用：`ggml-small.bin`；
- 搭配 GPU 引擎包：`ggml-large-v3-turbo-q5_0.bin`。

### 3. 字幕翻译配置
在「设置」→「AI 翻译设置」中配置凭据后即可启用字幕翻译：
- **百度翻译**：建议填入开放平台的 `APP ID` 与 `密钥`，支持在“大模型模式”和“传统模式”间无缝切换；大模型模式下会自动提取干净片名辅助提升翻译质量。
- **Azure 翻译**：填入密钥与区域即可使用。

---

## 下载安装

前往 [Releases](https://github.com/hcllmsx/PolyFlixPlayer/releases) 下载最新发行版：

| 平台 | 安装形式 |
|------|----------|
| **Windows** | 下载 `PolyFlixPlayer-v*.zip`，解压后直接运行 `PolyFlixPlayer.exe`（绿色免安装） |
| **Android** | 下载 `PolyFlixPlayer-v*.apk`，直接在手机上安装 |

> Windows 端为绿色免安装：字幕识别所需的音频处理组件（FFmpeg）已内置于软件中，**无需另行安装 FFmpeg、无需配置 PATH 或任何环境变量**，解压即用。

---

## 从源码构建

### 环境准备
- 安装 [Flutter SDK](https://docs.flutter.dev/get-started/install)（推荐 3.24+ / Dart 3.5+）；
- 构建 Windows：安装 Visual Studio 并勾选“使用 C++ 的桌面开发”；
- 构建 Android：配置好 Android SDK 与构建工具。

### 本地编译与运行
```bash
# 1. 克隆代码库
git clone https://github.com/hcllmsx/PolyFlixPlayer.git
cd PolyFlixPlayer

# 2. 安装依赖
flutter pub get

# 3. 本地调试运行
flutter run -d windows   # 运行 Windows 桌面端
flutter run              # 运行 Android 端（需连接设备或启动模拟器）

# 4. 构建发布产物
flutter build windows --release     # Windows 发布版
flutter build apk --release         # Android 通用 APK
flutter build apk --split-per-abi   # Android 架构分包 APK
```

### 离线构建（可选）

构建期默认会从 GitHub 拉取若干预编译产物（Windows：FFmpegKit 原生库、media_kit 的 `libmpv` / `ANGLE`；Android：4 个 libmpv jar）。若构建机网络受限，可预先下载并按下述结构放到 `_temp/prebuilt/`，构建时**自动复用、不再联网**；某处缺失时自动回退为联网下载，不影响普通构建。（`_temp/` 已被 gitignore，不会进版本库。）

```
_temp/prebuilt/
├─ ffmpeg_kit/                        # Windows：FFmpegKit 原生库（构建后随应用分发）
│  ├─ ffmpeg-kit-windows-x86_64-min-8.1.2.zip
│  └─ bundle/                         # 解压后的 bin/libffmpegkit.dll + include/
├─ media_kit/                         # Windows：libmpv / ANGLE
│  ├─ mpv-dev-x86_64-20230924-git-652a1dd.7z
│  └─ ANGLE.7z
└─ media_kit_android/                 # Android：libmpv 的 jar（按版本分目录）
   ├─ v1.1.11/                        # 当前使用的版本
   │  ├─ default-arm64-v8a.jar
   │  ├─ default-armeabi-v7a.jar
   │  ├─ default-x86.jar
   │  └─ default-x86_64.jar
   └─ v1.1.7/                         # 旧版本，仅作回滚备用
```

归档下载地址：

- FFmpegKit：`https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/8.1.2-min/ffmpeg-kit-windows-x86_64-min-8.1.2.zip`
- libmpv（Windows）：`https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z`
- ANGLE：`https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z`
- libmpv（Android）：`https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.11/default-<abi>.jar`（`<abi>` 为 `arm64-v8a` / `armeabi-v7a` / `x86` / `x86_64`）

> Android 的 jar 有 `default-` 与 `full-` 两种变体。本项目与 media_kit 保持一致，**必须用 `default-`**；`full-` 含更多编解码器，混用会让不同 CPU 架构的行为不一致。

---

### 本地 vendor 的插件（`third_party/`）

有两个插件必须修改上游代码才能在本项目里正常工作，因此直接 vendor 进仓库，并在 `pubspec.yaml` 里用 `dependency_overrides` 指向本地路径：

| 包 | 改动 | 原因 |
|---|---|---|
| `whisper_ggml` | `android/build.gradle`：`compileSdk 34 → 36`；`pubspec.yaml`：`ffmpeg_kit` 约束 `^2.1.0 → ^3.6.2` | 它的依赖链上有要求 `compileSdk >= 35` 的 `ffmpeg_kit_flutter_new_min`，不改就过不了 AGP 的 AAR 元数据校验 |
| `media_kit_libs_android_video` | libmpv jar `v1.1.7 → v1.1.11`（含 MD5）；下载前优先复用 `_temp/prebuilt/media_kit_android/<版本>/` | 用上最新 libmpv，并让 Android 构建可以离线完成 |

> 这两个包的**版权归其各自作者所有**（均为 MIT 许可），本仓库只是内置了它们的源码副本；各自的 `LICENSE` 与版权声明已随源码一并保留在 `third_party/<包名>/` 下，未作改动。

两处改动都在文件内用 **【本仓库补丁】** 标注。**升级上游版本时请把这些补丁一并移植过去。**

---

## 反馈与交流

- 提交建议或问题：[GitHub Issues](https://github.com/hcllmsx/PolyFlixPlayer/issues)
- 意见收集表单：[软件意见建议反馈收集表](https://docs.qq.com/form/page/DRHJ3bmd6Q3RqaENT)

---

## 开源协议

本项目基于 [GNU General Public License v3.0](LICENSE)（GPL-3.0）协议开源。

---

## 致谢

本项目基于以下优秀的开源项目与框架构建：
- [Flutter](https://flutter.dev/) - 跨平台客户端 UI 框架
- [media_kit](https://github.com/media-kit/media-kit) - 基于 libmpv 的全平台媒体播放引擎
- [libmpv](https://mpv.io/) / [FFmpeg](https://ffmpeg.org/) - 核心音视频解码与流媒体处理
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) / [whisper_ggml](https://pub.dev/packages/whisper_ggml) - 本地 Whisper 语音识别推理
- [FFmpegKit](https://github.com/sk3llo/ffmpeg_kit_flutter) / [ffmpeg_kit_flutter_new_min](https://pub.dev/packages/ffmpeg_kit_flutter_new_min) - 音频提取与内置字幕流提取（LGPL-3.0，采用不含 GPL 编解码器的 `min` 变体）

其中 [`whisper_ggml`](https://github.com/sk3llo/whisper_ggml) 与 [`media_kit_libs_android_video`](https://github.com/media-kit/media-kit) 的**源码副本**被内置在本仓库的 [`third_party/`](third_party) 目录下，并作了小幅修改（改动点见上文「本地 vendor 的插件」一节）。两者的版权分别归 **Hrvoje Cukman** 与 **Hitesh Kumar Saini** 所有，均为 MIT 许可，原始 `LICENSE` 与版权声明已随源码一并保留。
