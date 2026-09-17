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
- **本地 AI 语音字幕**：基于 Whisper 离线识别原声音频并自动生成带时间戳的字幕，全程不联网；内置 **33 个型号的对照表**（tiny ~ large-v3，含量化与英语专用版），模型按需自行下载后导入；可选装 whisper.cpp 官方引擎包启用 **NVIDIA GPU 加速**；可与内置字幕**同时显示**（内置在下作主字幕、AI 在上作副字幕），支持导出 SRT。
- **桌面端体验**：键盘快捷键（空格 / ←→ / ↑↓ / M / Esc）、拖放换片、窗口自动适应视频比例。
- **移动端体验**：沉浸式全屏、横竖屏切换、点击画面显隐控件。

## AI 语音识别：性能与硬件

### 识别引擎：内置 CPU 插件 + 可选 GPU 引擎包

识别有两条路径，**装有引擎包时优先用引擎包，没装则自动回落到内置插件**：

| 路径 | 说明 | GPU |
|---|---|---|
| **引擎包**（推荐） | whisper.cpp 官方预编译二进制，走 `whisper-server.exe`，模型常驻内存 | ✅ CUDA 包可直接用 N 卡 |
| **内置插件** | 项目依赖的 `whisper_ggml` 2.6.0，FFI 直调 | ❌ 纯 CPU |

内置插件是纯 CPU 构建（Windows / Android 都只编译 `GGML_USE_CPU`，原生 `main.cpp` 里硬编码 `use_gpu = false`），所以**不装引擎包就没有 GPU 加速**，设置页也不会给一个点了没用的假开关。

引擎包**同样不由应用内置下载**：设置页 →「**浏览全部引擎**」里有官方各平台包的对照表（Windows x64 的 CPU / BLAS / CUDA 12.4 / CUDA 11.8、Windows on ARM64、32 位等），按文件名从网盘下载对应 zip 后，用「**导入引擎**」导入即可；导入后会自动识别类型（CPU / CUDA / Vulkan）并优先使用 GPU 包。

### 模型清单与选择

模型选择统一收敛到「**浏览全部模型**」面板（设置 → AI 语音字幕，或 AI 字幕面板点「更换」）：

- 面板是一张**对照表**：按官方**原始文件名**（如 `ggml-small-q5_1.bin`）列出全部 33 个模型，含档位、体积、适用场景与纯 CPU 耗时参考；
- 应用**不内置任何下载链接**（官方源与国内镜像都不内置）。用户按表格选好型号 → 从网盘下载同名文件 → 用「**导入模型**」导入；
- 已导入的模型可在表格里直接点选切换，或点右侧垃圾桶删除。

分两大类：

- **多语言（21 个）**：tiny / base / small / medium / large-v1 / large-v2 / large-v3 / large-v3-turbo，每档都含 q5 / q8 量化版；
- **英语专用（12 个）**：`.en` 系列。只能识别英语（选中后语言会自动锁定为英语），英语场景下准确率略高、速度略快；喂其它语言会输出乱码式英文。

选型建议：

| 场景 | 推荐 | 说明 |
|---|---|---|
| 老设备、只想快点出结果 | `ggml-tiny-q5_1.bin`（31 MB） | 体积最小，精度一般 |
| 日常通用（CPU） | `ggml-small.bin` / `ggml-small-q5_1.bin` | 精度与速度的平衡点 |
| **有 GPU（如 RTX 40 系）** | **`ggml-large-v3-turbo-q5_0.bin`（547 MB）** | 精度接近 large-v3，速度快得多，配合 CUDA 引擎包性价比最高 |
| 想要最高精度、不在意耗时 | `ggml-large-v3.bin`（2.9 GB） | 纯 CPU 上反而慢到不实用，建议配合 CUDA 引擎包 |

> 另外，网盘里常见的 `ggml-*-encoder.mlmodelc.zip` 是 **Apple 平台（macOS / iOS）的 Core ML 编码器**，Windows 与 Android 用不到，**不需要下载**（面板里也标注了）。

### CPU 线程数（设置 → AI 语音字幕 → 识别性能）

`whisper.cpp` 是纯 CPU 推理，**线程数是目前唯一有效的速度杠杆**。默认「自动」取逻辑核心数的一半并限制在 4～12。实测（310 秒音频，Intel i9-13900 32 逻辑核心）：

| 模型 | 4 线程（旧版硬编码值） | 8 线程 | 12 线程 | 16 线程 |
|---|---|---|---|---|
| tiny | 6.6s（47× 实时） | 4.9s（64×） | 4.9s（63×） | 5.2s（60×，反而变慢） |
| base | 11.9s（26× 实时） | 7.6s（41×） | 7.5s（41×） | 7.5s（41×） |
| small | 38.8s（8.0× 实时） | 23.4s（13.3×） | 22.3s（13.9×） | 21.5s（14.4×） |

换算成 1 小时电影的大致耗时（仅作量级参考，实际取决于 CPU 性能）：

| 模型 | 4 线程 | 自动（本机取 12 线程） |
|---|---|---|
| tiny | 约 1.1 分钟 | 约 1 分钟 |
| base | 约 2.3 分钟 | 约 1.5 分钟 |
| small | 约 7.5 分钟 | 约 4.3 分钟 |

两条实测结论：

- **线程不是越多越好**：tiny 在 16 线程反而更慢，所以自动策略上限设为 12；
- `n_processors`（并行处理器数）实测**没有收益**（1/2/4 结果几乎一致），保持 1，避免损失上下文。

### 硬件品牌的影响

**Windows**

| 维度 | 影响 |
|---|---|
| CPU 品牌（Intel / AMD） | 影响很小。插件按 AVX2 / FMA / F16C 编译，2013 年之后的 Intel 与 AMD 均支持；同代差异主要来自核心数、频率与内存带宽，而非品牌。只有更老的 CPU 才需要 `WHISPER_GGML_AVX2=OFF` 的 SSE2 回退构建。 |
| CPU 型号 | 决定性因素：核心数越多越快（约 12 线程封顶），大核频率与内存带宽影响明显。 |
| GPU 品牌 | **装了引擎包才有差别**：NVIDIA 官方有 CUDA 包（最快）；AMD / Intel 目前没有官方预编译包，只能用 CPU 包或自行编译 Vulkan 包。不装引擎包时三家无差别（都走 CPU）。 |
| 显存 | 装了 GPU 引擎包后，small 模型约需 2GB 以上可用显存，核显共享内存更容易不足；显存不足时该分片会被跳过，建议改用 base / tiny。 |

**Android**

| 维度 | 影响 |
|---|---|
| CPU 品牌 / 型号 | 决定性因素。骁龙、天玑、Exynos、麒麟的 CPU 大核数量与频率差异很大，ARM64 上还依赖 dotprod / i8mm 等指令集加速。中低端机识别 1 小时视频会明显慢于桌面端。 |
| GPU 品牌 | Android 暂不支持 GPU 引擎包（官方无预编译，需自行编译并逐机型验证），全部走 CPU 推理。 |
| 内存 | 至少 4GB；small 模型配合长视频切片更容易触发内存压力，此时建议改用 base / tiny。 |

**结论**：现阶段真正决定识别速度的是「**CPU 核心数 + 所选的模型**」以及可用的线程数，与 CPU / GPU 品牌基本无关；品牌只有在将来启用 GPU 后才会成为关键变量。

### GPU 加速：安装引擎包

**Windows 用户**可以直接使用 whisper.cpp 官方预编译包启用 GPU，无需安装任何 SDK、无需自行编译。

**安装步骤**

1. 打开 [whisper.cpp Releases](https://github.com/ggml-org/whisper.cpp/releases)，二进制挂在 **nightly 构建**（`b` 开头的标签，如 `b5130`）下；正式版本标签（如 `v1.9.4`）只有源码；
2. 按显卡下载对应包（见下表）；
3. 解压到引擎目录（包内自带 `Release\` 子目录，会被自动识别）：

```
%LOCALAPPDATA%\PolyFlixPlayer\engine\
```

4. 重启播放器，设置 → AI 语音字幕 → **识别引擎** 会显示检测结果（如 `已安装：CUDA 引擎包，识别时优先使用 GPU`）。

> 嫌手动解压麻烦的话，直接点设置页「**导入引擎**」选择 zip 即可：应用会**先只读列出压缩包内容**（秒级），确认含 `whisper-server.exe` 且判断类型，再自动解压到引擎目录下按类型命名的子目录（`cuda` / `vulkan` / `cpu`）；不合格的包会被当场拒绝，不会留下残留文件。
>
> 模型同理：网络不好时可以自己下载 `ggml-*.bin`，点设置页「**导入模型**」导入，应用会校验文件头并按文件名/体积自动识别是 tiny / base / small。

**多个引擎包时的注意事项**

- 用「导入引擎」按钮导入时，若已有同类型引擎包，会询问 **替换 / 保留两个 / 取消**：
  - *替换*（推荐）：删掉旧包，改用新导入的；导入前会自动停掉正在运行的识别服务，避免文件被占用。
  - *保留两个*：新包落地为 `cuda-2` 之类的带序号目录；**同类型有多个时，默认使用最近导入的那个**（设置页会显示"当前使用：CUDA 引擎包（cuda-2）"）。同类型多个包会白占一倍空间，建议只留一个。
- **手动解压**时请务必给每个包单独一个子目录，例如：
  ```
  engine\cuda124\Release\...
  engine\cuda118\Release\...
  ```
  不要都解压到 `engine\` 根目录：两个包的 `ggml-cuda.dll` 同名会互相覆盖，`cudart64_11/12.dll`、`cublas64_11/12.dll` 也会混在一起，可能导致引擎直接加载失败。

模型与引擎都放在同一个持久目录下，不会被"清理缓存"或系统临时目录清理删掉：

| 路径（Windows） | 内容 |
|---|---|
| `%LOCALAPPDATA%\PolyFlixPlayer\models\whisper\` | Whisper 模型（tiny / base / small） |
| `%LOCALAPPDATA%\PolyFlixPlayer\engine\` | 识别引擎包（CUDA / Vulkan） |
| `%TEMP%\PolyFlixPlayer\` | 可随时清理的缓存（字幕缓存、临时音频）；「清理应用缓存」会整个删掉这个目录 |



**选择哪个包**

| 包 | 大小 | 适用 |
|---|---|---|
| `whisper-cublas-12.4.0-bin-x64.zip` | 643 MB | **NVIDIA 显卡（推荐）**，含 cudart / cublas 运行库，无需另装 CUDA |
| `whisper-cublas-11.8.0-bin-x64.zip` | 260 MB | NVIDIA 显卡但驱动较老 |
| `whisper-bin-x64.zip` | 8 MB | 纯 CPU（所有 Windows x64 通用） |
| `whisper-blas-bin-x64.zip` | 20 MB | 纯 CPU + OpenBLAS，比上面略快 |

> AMD / Intel 显卡：官方**没有** Vulkan 预编译包，目前只能用 CPU 包；自行编译出 Vulkan 版后按同样目录约定放入即可被识别为 `Vulkan 引擎包`。

**实测（RTX 4080，small 模型）**

| 场景 | 74 秒音频 | 311 秒音频 | 换算 1 小时 |
|---|---|---|---|
| 内置 CPU 插件（12 线程） | 约 7~8 秒 | 22.3 秒 | 约 4.3 分钟 |
| CUDA 引擎包 | 1.44 秒（含音频提取） | **3.3 秒** | **约 40 秒** |
| CUDA 引擎包（模型已常驻，单次推理） | 0.49 秒 | — | — |

> 线程数对 GPU 引擎**没有影响**：实测 311 秒音频，CUDA 引擎用 4 线程 3.28 秒、12 线程 3.36 秒，差异在噪声范围内。因此使用 GPU 引擎时设置页的「识别线程数」会**自动置灰**并说明原因。

**相关设置**

- **识别引擎**：显示当前检测到的引擎（内置 CPU / CUDA / Vulkan 引擎包）与「引擎目录」入口；
- **强制使用 CPU 识别**：显卡驱动异常或识别报错时打开，仍可用引擎包但以 `-ng` 关闭 GPU，无需删除引擎包；
- **识别线程数**：仅 CPU 识别时生效（详见上一节）；GPU 引擎生效期间该项置灰。

**几处行为细节**

- 引擎服务以独立进程运行（`whisper-server`，只监听 `127.0.0.1` 随机端口），**闲置 3 分钟后自动退出**释放显存，退出播放器时也会清理；
- 长视频按 60 秒分片识别，单个分片失败（如显存不足）只会跳过该片，不中断整段任务；
- 引擎包启动失败或文件缺失时，自动回落到内置 CPU 插件；
- 低配设备（内存 < 4GB 或 CPU 核数 < 4）直接提示"当前设备不支持此功能"，不做降级适配。

**开发者提示**

- 可用环境变量 `POLYFLIX_ENGINE_DIR` 覆盖引擎目录，便于联调；
- 引擎类型按目录下的 `ggml-cuda*.dll` / `ggml-vulkan*.dll` 自动判定；
- Android 目前不支持引擎包（官方无预编译，且需逐机型验证），仍走内置 CPU 插件。

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

## 反馈与建议

遇到问题或有新想法？欢迎通过问卷告诉我们：[软件意见建议反馈收集表](https://docs.qq.com/form/page/DRHJ3bmd6Q3RqaENT)。你的反馈会直接影响后续的更新方向。

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
| [whisper_ggml](https://pub.dev/packages/whisper_ggml) | Flutter 侧本地 Whisper 语音识别封装 | https://pub.dev/packages/whisper_ggml |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Whisper 模型的高性能 C/C++ 推理实现 | https://github.com/ggml-org/whisper.cpp |
