# 影现播放器 PolyFlixPlayer

影藏 [PolyFlix](https://github.com/hcllmsx/PolyFlix) 的姊妹项目 —— 一个"会识别自己人"的万能视频播放器。

## 它做什么

- **普通视频**：直接播放。libmpv（ffmpeg）内核，MKV / FLV / WebM / AVI / MOV / HEVC / 10bit……全格式。
- **影藏产物**（双视频模式生成的 `.mp4`）：拖进来自动识别并播放**藏在里面的那个视频**——无需改名、无需解压、无需密码。别人双击这个文件，用普通播放器看到的只是一段正常视频。

## 快速开始

```powershell
# 1. 安装依赖（建议 Python 3.10+）
pip install -r requirements.txt

# 2. 放置 mpv-2.dll
#    从 https://sourceforge.net/projects/mpv-player-windows/files/libmpv/
#    下载 libmpv x86_64 包，把 mpv-2.dll 放到本目录或系统 PATH

# 3. 运行
python player.py
# 或直接播放：python player.py 某视频.mp4
```

## 操作

| 操作 | 方式 |
|------|------|
| 打开文件 | 拖入窗口 / 右键画面→“打开文件…” / `Ctrl+O` / 命令行参数 |
| 播放/暂停 | 空格（载入后） / 播放按钮 |
| 快退快进 5s | ← / → |
| 进度跳转 | 点击进度条任意位置直接跳转 / 拖动进度条（拖动时右下显示预览缩略图） |
| 全屏切换 | 双击画面 / `Enter` / `F`（载入后）；`Esc` 退出全屏 |
| 音量增减 | ↑ / ↓（步进 5）/ 鼠标滚轮 / 点音量图标弹出滑块（0-100） |
| 音量增益 | 100% 后继续↑/滚轮可放大到 300%（软件增益，仅快捷键/滚轮可超 100） |
| 静音/取消 | `M` |
| 倍速 | 底部"1.0x"按钮 / 右键画面→“倍速…” / `[` 减速 / `]` 加速 / `\` 恢复 1.0x（0.5x~4.0x） |
| 音轨切换 | 右键画面→“音轨…” |
| 字幕轨切换 | 右键画面→“字幕…”（含"关闭字幕"选项） |
| 导出隐藏视频 | 打开产物后点"导出隐藏视频"另存 |

底部控制条只保留：播放按钮、进度条、时间、导出隐藏视频、音量、倍速。其他功能（打开/音轨/字幕）在画面右键菜单里，全屏时也能用。操作音量时右上角会弹出音量百分比提示。

## 注意

- 隐藏视频播放时会在 `%TEMP%\YingXian` 留一份临时缓存（完整性校验通过后交给播放器），退出程序自动清理。
- 产物体积会比原视频大一些，请注意别让文件大小暴露自己。

## 开源协议

本项目基于 [GNU General Public License v3.0](LICENSE)（GPL-3.0）开源。

这意味着你可以自由使用、学习、修改和再分发本项目的源代码，但任何基于本项目或其衍生部分的发行版本，也必须以 GPL-3.0 协议继续开源，并附带本协议全文。详细条款见项目根目录的 `LICENSE` 文件。

## 致谢

本项目站在以下成熟开源方案的肩膀上，在此致以谢意：

| 项目 | 用途 | 主页 |
|------|------|------|
| [Python](https://www.python.org/) | 运行时与开发语言 | https://www.python.org/ |
| [PySide6](https://www.qt.io/qt-for-python) / Qt6 | 跨平台 GUI 框架（主窗口与控件） | https://www.qt.io/qt-for-python |
| [mpv](https://mpv.io/) | 播放器内核（灵活可控、高性能） | https://mpv.io/ |
| [libmpv](https://github.com/mpv-player/mpv/tree/master/libmpv) | mpv 的 C API 绑定（嵌入渲染、指令控制） | https://github.com/mpv-player/mpv |
| [python-mpv](https://github.com/jaseg/python-mpv) | libmpv 的 Python 封装 | https://github.com/jaseg/python-mpv |
| [FFmpeg](https://ffmpeg.org/) | libmpv 的底层解码引擎（全格式通吃） | https://ffmpeg.org/ |
| [PyInstaller](https://pyinstaller.org/) | 打包成单文件可执行程序 | https://pyinstaller.org/ |

