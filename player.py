"""影现播放器 PolyFlixPlayer —— 主窗口

一个"会识别自己人"的万能视频播放器：
- 打开普通视频文件 → 直接播放（libmpv/ffmpeg 全格式解码）
- 打开影藏 PolyFlix 的双视频产物（PFLX）→ 自动抽取 free box 里的隐藏视频播放

技术栈：PySide6（界面）+ python-mpv（内嵌 libmpv-2.dll 解码内核）
"""

from __future__ import annotations

import os
import sys
import hashlib
import shutil
import tempfile
import threading
import urllib.request

from PySide6.QtCore import Qt, QTimer, QEvent, QPoint
from PySide6.QtGui import QIcon, QPixmap
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QSlider, QPushButton,
    QLabel, QFileDialog, QMessageBox, QStyle, QApplication, QMenu, QFrame,
    QStyleOptionSlider, QDialog,
)

import pflx

# python-mpv 通过 %PATH% 搜索 libmpv-2.dll：把脚本所在目录注入 PATH，
# 实现" dll 与脚本同目录即可用"（官方文档推荐做法）。
# 注意：不能判断 "目录是否已在 PATH 里" 再决定是否注入——PySide6 导入后会把
# .venv\...\PySide6 插入 PATH，它是项目目录的子串，会误判"已存在"导致注入被跳过。
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
os.environ["PATH"] = _SCRIPT_DIR + os.pathsep + os.environ.get("PATH", "")

try:
    from mpv import MPV  # python-mpv（依赖同目录 libmpv-2.dll）
except (ImportError, OSError):
    MPV = None

APP_NAME = "影现播放器"

# 音量范围：mpv.volume 属性上限为 100（libmpv 拒绝 >100 的值）。
# 100% = 原始音量；无软件增益，需要更大音量应靠系统/功放调节。
VOLUME_MIN = 0
VOLUME_MAX = 100
VOLUME_NORMAL = 100  # 原始音量基准（=上限）
VOLUME_STEP = 5      # 方向键/滚轮步进

# 倍速可选档位（0.5x ~ 4.0x）
SPEED_PRESETS = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0]
SPEED_MIN, SPEED_MAX = 0.5, 4.0


def _read_version() -> str:
    """读取 VERSION 文件（单一真相源，dev 和打包后都从这里取）。

    尝试多个可能的位置：
      1. _SCRIPT_DIR/VERSION          （dev 模式 / --add-data "VERSION;."）
      2. _SCRIPT_DIR/VERSION/VERSION   （--add-data "VERSION;VERSION" 的旧行为）
    """
    for candidate in (
        os.path.join(_SCRIPT_DIR, "VERSION"),
        os.path.join(_SCRIPT_DIR, "VERSION", "VERSION"),
    ):
        try:
            if os.path.isfile(candidate):
                with open(candidate, "r", encoding="utf-8") as f:
                    return f.read().strip() or "Unknown"
        except Exception:
            continue
    return "Unknown"


APP_VERSION = _read_version()

# 版本更新检测：读取仓库根目录 VERSION 文件（raw URL）。仓库暂未建立，
# 按能连通写好；连不通时静默失败，不影响使用。
UPDATE_URL = "https://raw.githubusercontent.com/hcllmsx/PolyFlixPlayer/main/VERSION"
UPDATE_RELEASES_URL = "https://github.com/hcllmsx/PolyFlixPlayer/releases"


def _compare_versions(a: str, b: str) -> int:
    """比较 YY.M.D 格式版本号。a>b 返回 1，a<b 返回 -1，相等返回 0。"""
    pa = [int(x) for x in (a or "").split(".") if x.isdigit()] or [0]
    pb = [int(x) for x in (b or "").split(".") if x.isdigit()] or [0]
    for i in range(max(len(pa), len(pb))):
        da = pa[i] if i < len(pa) else 0
        db = pb[i] if i < len(pb) else 0
        if da != db:
            return 1 if da > db else -1
    return 0


# 资源文件路径（与脚本同目录分发）
ICON_PATH = os.path.join(_SCRIPT_DIR, "app.ico")
LOGO_PNG_PATH = os.path.join(_SCRIPT_DIR, "app.png")          # 横版 banner（启动画面）
LOGO_SQ_PNG_PATH = os.path.join(_SCRIPT_DIR, "logo_sq.png")  # 方形 logo（关于框）

# 统一临时目录：播放产物时抽出的载荷放这里，退出时整体清理
PLAYER_TEMP_DIR = os.path.join(tempfile.gettempdir(), "YingXian")

VIDEO_EXTS = " ".join("*." + e for e in (
    "mp4", "mkv", "flv", "webm", "avi", "mov", "ts", "m4v",
    "wmv", "mpg", "mpeg", "3gp", "rmvb", "vob", "m2ts",
))


def extract_hidden(path: str) -> tuple[str, pflx.__dict__] | tuple[None, dict | None]:
    """若是影藏产物，抽取隐藏视频到临时目录，返回 (临时文件路径, scan信息)。
    不是产物返回 (None, None)。"""
    info = pflx.scan(path)
    if info is None:
        return None, None
    if info["encrypted"]:
        raise RuntimeError("该产物启用了加密，当前版本暂不支持解密播放。")
    if info["payload_offset"] + info["payload_len"] > info["file_size"]:
        raise RuntimeError("产物数据不完整，可能已损坏。")
    os.makedirs(PLAYER_TEMP_DIR, exist_ok=True)
    # 用源路径哈希做临时名：同一产物反复打开复用同一份缓存，不膨胀
    tag = hashlib.sha1(os.path.abspath(path).encode("utf-8")).hexdigest()[:12]
    # 隐藏视频格式未知，先不带扩展名交给 mpv（mpv 按内容探测）；带 .bin 避免被当普通文本
    tmp = os.path.join(PLAYER_TEMP_DIR, f"pflx_{tag}.bin")
    pflx.extract_payload(path, tmp, info)
    return tmp, info


class SeekSlider(QSlider):
    """进度条：点击任意位置直接跳转到该位置（而非 Qt 默认的"移动一格"）。

    重写 mousePressEvent：点击落在 handle 上时交给 Qt 原生处理（支持拖动
    滑块），否则把点击 x 换算成 value 并 setValue + 触发 seek。这样既能
    "点击任意处跳转"，又能"按住 handle 拖动"。
    """

    def mousePressEvent(self, e):
        if e.button() == Qt.LeftButton:
            # 先判断点击是否落在 handle（滑块旋钮）上：若是，交给 Qt 原生
            # 处理，进入拖动模式（sliderPressed + 后续 mouseMove 拖动）。
            # 否则覆盖 Qt 默认的"移动一格"行为，直接跳到点击位置。
            so = QStyleOptionSlider()
            self.initStyleOption(so)
            handle_rect = self.style().subControlRect(
                QStyle.ComplexControl.CC_Slider, so,
                QStyle.SubControl.SC_SliderHandle, self)
            if handle_rect.contains(e.position().toPoint()):
                # 点在 handle 上 → 走原生拖动流程
                super().mousePressEvent(e)
                return
            # 点在轨道上 → 跳转到点击位置
            if self.maximum() > self.minimum():
                ratio = e.position().x() / self.width()
                ratio = max(0.0, min(1.0, ratio))
                val = self.minimum() + int(ratio * (self.maximum() - self.minimum()))
                self.setValue(val)
                # sliderMoved 信号会让上层做 seek（与拖动一致）
                self.sliderMoved.emit(val)
            e.accept()
            return
        super().mousePressEvent(e)


class PlayerWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"{APP_NAME} v{APP_VERSION}")
        self.resize(960, 600)
        self.setAcceptDrops(True)
        # 窗口图标（同时作用于任务栏 / Alt+Tab）
        if os.path.isfile(ICON_PATH):
            self.setWindowIcon(QIcon(ICON_PATH))

        self.mpv = None
        self.playing_source = ""      # 当前播放的文件（产物 → 临时文件）
        self.product_source = ""      # 打开的原始产物路径（用于导出/提示）
        self.product_info: dict | None = None
        self._has_media = False        # 是否已载入可播放的媒体（空格/Enter/双击只在载入后响应）
        self._fullscreen_controls_hidden = False  # 全屏时控制条是否已藏起
        self._track_lists: dict = {}  # 缓存轨道信息（audio/sub），按需刷新
        self._volume_popup: QFrame | None = None  # 音量弹出面板
        # 更新检测状态：None=未检测/idle, "checking", "new"(新版本), "latest", "error"
        self._update_state: str | None = None
        self._update_remote: str = ""  # 检测到的远程版本号
        self._about_box: QDialog | None = None  # 已打开的关于框（用于刷新）

        self._build_ui()
        self._init_mpv()

        # 音量 OSD 淡出定时器
        self._osd_timer = QTimer(self)
        self._osd_timer.setSingleShot(True)
        self._osd_timer.timeout.connect(self._hide_volume_osd)

        # 预览图定时器（拖动进度条时抓帧，做防抖）
        self._preview_timer = QTimer(self)
        self._preview_timer.setSingleShot(True)
        self._preview_timer.timeout.connect(self._grab_preview)
        self._seeking = False

        # 给所有按钮装事件过滤器：按钮有焦点时空格会被 Qt 当作"点击按钮"
        # （典型表现：焦点在"打开"按钮上 → 空格弹文件对话框）。装上过滤器后，
        # 空格统一交给主窗口处理成暂停/播放，不再被按钮吃掉。
        for btn in (self.btn_open, self.btn_play, self.btn_export, self.btn_mute):
            btn.installEventFilter(self)
        # 控制条所有控件设为不获焦：避免焦点落在 slider/按钮上时方向键被
        # 控件吃掉（QSlider 用方向键调进度、按钮用空格触发），导致
        # keyPressEvent 收不到 → 上下键调不了音量、左右键 seek 失效。
        # 全部 NoFocus 后键盘事件统一交给主窗口 keyPressEvent 处理。
        for w in (self.btn_open, self.btn_play, self.btn_export, self.btn_mute,
                  self.btn_speed, self.btn_audio, self.btn_sub, self.slider):
            w.setFocusPolicy(Qt.NoFocus)
        # video_frame 装事件过滤器：mpv 通过 wid 直接渲染进它的原生窗口，
        # 会吃掉鼠标事件 → 这里拦下双击事件做全屏切换、滚轮调音量。
        self.video_frame.installEventFilter(self)

        # 启动后自动检测更新（后台线程，静默；结果通过 QTimer 回主线程刷新标题栏）
        self._check_for_update(manual=False)

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        lay = QVBoxLayout(central)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)

        # 视频画面区（mpv 渲染进这个 widget 的原生窗口 ID）
        self.video_frame = QFrame()
        self.video_frame.setObjectName("videoFrame")
        self.video_frame.setStyleSheet("background: #000;")
        self.video_frame.setMinimumSize(400, 240)
        lay.addWidget(self.video_frame, 1)

        # 开屏 logo：黑屏状态下显示在画面区正中央，开始播放后隐藏。
        # 关键：logo_label 铺满整个 video_frame，靠 QLabel 自身的 AlignCenter
        # 把 pixmap 居中绘制——不手动 setGeometry（避免构造阶段尺寸为 0 导致偏左）。
        # 不用 setScaledContents，防止 QLabel 对 pixmap 二次拉伸导致发糊。
        self.logo_label = QLabel(self.video_frame)
        self.logo_label.setAlignment(Qt.AlignCenter)
        self.logo_label.setStyleSheet("background: transparent;")
        self.logo_label.setGeometry(0, 0, 0, 0)  # 先占位，show 时再撑满
        if os.path.isfile(LOGO_PNG_PATH):
            self._logo_pix = QPixmap(LOGO_PNG_PATH)
        else:
            self._logo_pix = None
            self.logo_label.setText("影现播放器")
            self.logo_label.setStyleSheet(
                "color: #555; background: transparent; font-size: 22px;")

        # 方形 logo（关于框用；与启动 banner 是不同资源）
        if os.path.isfile(LOGO_SQ_PNG_PATH):
            self._logo_sq_pix = QPixmap(LOGO_SQ_PNG_PATH)
        else:
            self._logo_sq_pix = None

        # OSD 浮层：音量/倍速/轨道切换等瞬时反馈，显示在画面右上角，2 秒淡出。
        # 关键：必须用独立顶层窗口（Qt.ToolTip | FramelessWindowHint），不能做
        # video_frame 的子控件——mpv 通过 wid 直接把画面渲染进 video_frame 的
        # 原生窗口，每帧 GPU 重绘会覆盖掉同窗口的所有子控件（QLabel 画上去立刻
        # 被抹掉，导致 OSD 根本看不到）。独立顶层窗口属于另一个原生窗口，
        # mpv 画不到它，OSD 才能稳定浮在画面之上。
        self.osd_label = QLabel("", None,
                                Qt.ToolTip | Qt.FramelessWindowHint)
        self.osd_label.setAttribute(Qt.WA_ShowWithoutActivating, True)
        self.osd_label.setAttribute(Qt.WA_TransparentForMouseEvents, True)
        self.osd_label.setAlignment(Qt.AlignCenter)
        self.osd_label.setStyleSheet(
            "color: #fff; background: rgba(0,0,0,180);"
            "padding: 6px 16px; border-radius: 6px; font-size: 16px;")
        self.osd_label.setVisible(False)

        # 预览缩略图浮层：拖动进度条时显示在画面右上角。
        self.preview_label = QLabel(self.video_frame)
        self.preview_label.setAlignment(Qt.AlignCenter)
        self.preview_label.setStyleSheet(
            "background: #000; border: 1px solid #444;")
        self.preview_label.setVisible(False)

        # 状态栏提示条：仅在播放 PFLX 产物时显示一行轻提示（隐藏视频名 + CRC 校验）。
        # 初始空界面、播放普通视频时都不显示——播放器无需自报家门。
        self.status_label = QLabel("")
        self.status_label.setStyleSheet(
            "color: #aaa; background: #111; padding: 3px 10px; font-size: 12px;")
        self.status_label.setVisible(False)
        lay.addWidget(self.status_label)

        # 控制条
        ctrl = QHBoxLayout()
        ctrl.setContentsMargins(8, 4, 8, 6)

        # “打开”/“音轨”/“字幕” 不在底部占位，改为右键画面菜单（见 _show_context_menu）
        self.btn_play = QPushButton()
        self.btn_play.clicked.connect(self.toggle_pause)
        ctrl.addWidget(self.btn_play)

        self.slider = SeekSlider(Qt.Horizontal)
        self.slider.setRange(0, 1000)
        self.slider.sliderPressed.connect(self._on_slider_pressed)
        self.slider.sliderReleased.connect(self._on_slider_released)
        self.slider.sliderMoved.connect(self._on_slider_moved)
        ctrl.addWidget(self.slider, 1)

        self.label_time = QLabel("00:00 / 00:00")
        ctrl.addWidget(self.label_time)

        self.btn_export = QPushButton("导出隐藏视频")
        self.btn_export.setToolTip("把产物里隐藏的视频另存为独立文件")
        self.btn_export.clicked.connect(self.export_hidden)
        self.btn_export.setVisible(False)
        ctrl.addWidget(self.btn_export)

        # 音量按钮：点击弹出音量面板（平时只显示图标）。
        # 用项目内 style 的标准图标，避免外部资源依赖。
        style = QApplication.style()
        self.btn_mute = QPushButton()
        self.btn_mute.setIcon(style.standardIcon(QStyle.StandardPixmap.SP_MediaVolume))
        self.btn_mute.setToolTip("音量（点击调节，M 静音）")
        self.btn_mute.setFixedWidth(34)
        self.btn_mute.clicked.connect(self._toggle_volume_popup)
        ctrl.addWidget(self.btn_mute)

        # 倍速按钮：放在音量键右侧（最右端）。点击弹出档位菜单。
        self.btn_speed = QPushButton("1.0x")
        self.btn_speed.setToolTip("倍速（点击选择档位，[/] 微调）")
        self.btn_speed.setFixedWidth(52)
        self.btn_speed.clicked.connect(lambda _=False: self._show_speed_menu())
        ctrl.addWidget(self.btn_speed)

        # btn_open/btn_audio/btn_sub 不再创建为可见按钮，但保留属性引用
        # （某些旧代码可能引用，避免 AttributeError）。这里创建为隐形按钮。
        self.btn_open = QPushButton(self)
        self.btn_open.setVisible(False)
        self.btn_open.clicked.connect(self.open_dialog)
        self.btn_audio = QPushButton(self)
        self.btn_audio.setVisible(False)
        self.btn_sub = QPushButton(self)
        self.btn_sub.setVisible(False)

        wrap = QWidget()
        wrap.setObjectName("ctrlBar")  # 全屏时按 objectName 定位整体隐藏
        wrap.setLayout(ctrl)
        lay.addWidget(wrap)

        self._update_timer = QTimer(self)
        self._update_timer.timeout.connect(self._on_tick)
        self._update_timer.start(200)

    def _relayout_logo(self):
        """让 logo_label 铺满 video_frame，并生成一张适配当前尺寸的 pixmap。

        必须在 video_frame 已有真实尺寸后调用（showEvent / resizeEvent）。
        QLabel 设为铺满父区域 + AlignCenter，由 Qt 自己居中绘制 pixmap，
        无需手动计算居中坐标——这才是 Qt 里做浮层居中的正确姿势。
        """
        vw = max(1, self.video_frame.width())
        vh = max(1, self.video_frame.height())
        # logo_label 铺满整个画面区（坐标 0,0 起点）
        self.logo_label.setGeometry(0, 0, vw, vh)
        self.logo_label.raise_()
        self.logo_label.show()
        # 每次都按当前画面尺寸重新缩放 pixmap（画面变大 logo 跟着变大）
        if self._logo_pix is not None:
            # 横版 logo：宽度取画面宽 55% 且不超过 420px，高度不超过画面高 45%
            target_w = min(vw * 0.55, 420)
            max_h = vh * 0.45
            scaled = self._logo_pix.scaledToWidth(
                int(target_w), Qt.SmoothTransformation)
            if scaled.height() > max_h:
                scaled = scaled.scaledToHeight(
                    int(max_h), Qt.SmoothTransformation)
            self.logo_label.setPixmap(scaled)

    def _relayout_overlays(self):
        """重新定位画面上的浮层（音量 OSD、预览图）。

        在 showEvent / resizeEvent 调用。音量 OSD 在右上角，预览缩略图在
        右下角——两者分置避免重叠。
        """
        vw = max(1, self.video_frame.width())
        vh = max(1, self.video_frame.height())
        margin = 16
        # OSD 是独立顶层窗口，用全局坐标定位到 video_frame 右上角
        osd_w = self.osd_label.sizeHint().width()
        osd_h = self.osd_label.sizeHint().height()
        gp = self.video_frame.mapToGlobal(QPoint(vw - osd_w - margin, margin))
        self.osd_label.move(gp)
        self.osd_label.resize(osd_w, osd_h)
        self.osd_label.raise_()
        # 预览图：右下角，距底边 56px（避开全屏时隐藏的控制条位置）
        if self.preview_label.isVisible():
            pw = self.preview_label.width()
            ph = self.preview_label.height()
            self.preview_label.setGeometry(
                vw - pw - margin, vh - ph - 56 - margin, pw, ph)
            self.preview_label.raise_()

    def showEvent(self, e):
        super().showEvent(e)
        # 首次 show：此时 video_frame 才有真实尺寸，定位 logo
        self._relayout_logo()
        self._relayout_overlays()

    def resizeEvent(self, e):
        super().resizeEvent(e)
        # 窗口尺寸变化时重新铺满 + 重新缩放 pixmap
        if self.logo_label.isVisible():
            self._relayout_logo()
        self._relayout_overlays()

    def moveEvent(self, e):
        super().moveEvent(e)
        # 窗口移动时 OSD/预览图等独立顶层浮层不会自动跟随（它们用全局坐标定位），
        # 这里重新定位。不调 _relayout_logo：logo 是 video_frame 的子控件，会自动跟。
        self._relayout_overlays()

    # ----------------------------------------------------------------- mpv
    def _init_mpv(self):
        if MPV is None:
            QMessageBox.warning(
                self, APP_NAME,
                "未找到 python-mpv / libmpv。\n"
                "请先安装依赖：pip install python-mpv PySide6\n"
                "并把 mpv 的 libmpv-2.dll 放到本程序目录（详见 README）。")
            return
        # vo='gpu'：通过 wid 把画面渲染进 video_frame 的原生窗口（嵌入式播放标准做法）。
        # 不能用 vo='libmpv'——它需要显式创建 render context（mpv_render_context_create），
        # 仅设置 wid 而不创建 context 会导致 "No render context set" 致命错误，
        # mpv 随后 deselect 视频轨 → 黑屏只有声音。
        # hwdec='auto-safe'：优先用安全的硬件解码（失败自动回退软解），降低 CPU 占用。
        # 隐藏视频文件无扩展名，必须让 mpv 按内容探测格式（analyzeduration/probesize 调大）。
        self.mpv = MPV(
            vo="gpu",
            hwdec="auto-safe",
            demuxer_lavf_o="analyzeduration=10M,probesize=10M",
            keep_open="always",
            input_default_bindings=False,
            input_vo_keyboard=False,
        )
        wid = int(self.video_frame.winId())
        self.mpv.wid = wid

    # ------------------------------------------------------------ 播放控制
    def _hide_loading_osd(self):
        """关闭载入 OSD（extract_hidden 完成、即将开始播放时调用）。"""
        self._osd_timer.stop()
        self.osd_label.setVisible(False)

    def load_file(self, path: str):
        """打开任意文件：影藏产物 → 播隐藏视频；普通 → 直接播。"""
        if not os.path.isfile(path):
            return
        if self.mpv is None:
            QMessageBox.warning(self, APP_NAME, "mpv 未初始化，无法播放。")
            return

        # 一点开按钮、文件框一关，立刻显示载入 OSD。耗时部分（抽载荷 + play）
        # 用 singleShot(0) 推到下一轮事件循环：让 open_dialog 先返回、文件框先
        # 关闭、OSD 先上屏，再开始抽载荷。这样 OSD 不会被耗时操作阻塞住。
        self._show_osd("正在载入视频文件…", duration=8000)
        QApplication.processEvents()
        QTimer.singleShot(0, lambda: self._load_file_async(path))

    def _load_file_async(self, path: str):
        """load_file 的耗时部分：抽载荷 + play。由 singleShot(0) 触发，此时载入
        OSD 已上屏。抽载荷完成后（状态条/标题栏已设置，意味着载入完成、马上
        开始播），立刻关掉载入 OSD——比靠 mpv 事件更即时、更可靠。"""
        # 记录产物上下文（先重置）
        self.product_source = ""
        self.product_info = None
        self.btn_export.setVisible(False)

        try:
            hidden_path, info = extract_hidden(path)
        except Exception as e:
            self._hide_loading_osd()
            QMessageBox.critical(self, APP_NAME, f"产物解析失败：\n{e}")
            return

        if hidden_path is not None:
            self.product_source = path
            self.product_info = info
            self.btn_export.setVisible(True)
            # 状态条：显示隐藏视频的原始名（头部带出；旧产物回退用产物文件名）。
            hidden_name = info.get("name") or os.path.basename(path)
            self.status_label.setText(
                f"✓ 隐藏视频：{hidden_name}"
                f"  （{info['payload_len']:,} 字节，完整性校验通过）")
            self.status_label.setVisible(True)
            # 标题栏：和普通视频一样直接显示文件名，不加“隐藏视频：”前缀
            self._refresh_title(os.path.basename(path))
            play_path = hidden_path
        else:
            # 普通视频：不显示状态条，标题栏只显示文件名
            self.status_label.setVisible(False)
            self._refresh_title(os.path.basename(path))
            play_path = path

        # 载入已完成（状态条/标题栏已上），立刻关掉载入 OSD，紧接着开始 play。
        # 这样 OSD 在“载入完成”那一瞬间消失，几乎是视频开描的前一刻。
        self._hide_loading_osd()

        self.mpv.play(play_path)
        self.playing_source = path
        self.mpv.pause = False
        self._has_media = True
        # 重置倍速/轨道缓存
        self.mpv.speed = 1.0
        self.btn_speed.setText("1.0x")
        self._track_lists = {}
        # 开始播放 → 隐藏开屏 logo
        self.logo_label.hide()

    def toggle_pause(self):
        if self.mpv is None or not self._has_media:
            return
        new_pause = not bool(self.mpv.pause)
        self.mpv.pause = new_pause
        self._show_osd("已暂停" if new_pause else "播放")

    def toggle_fullscreen(self):
        """进入/退出全屏。仅在已载入媒体时响应（空界面不应全屏）。"""
        if not self._has_media:
            return
        if self.isFullScreen():
            self.showNormal()
            self._set_controls_visible(True)
            self._show_osd("退出全屏")
        else:
            self.showFullScreen()
            self._set_controls_visible(False)
            self._show_osd("全屏")

    def _set_controls_visible(self, visible: bool):
        """全屏时隐藏控制条与状态栏，让画面真正占满。"""
        # 按 objectName 找控制条容器，避免逐个隐藏子控件
        ctrl_bar = self.findChild(QWidget, "ctrlBar")
        if ctrl_bar is not None:
            ctrl_bar.setVisible(visible)
        self.status_label.setVisible(visible and self.product_info is not None)
        self._fullscreen_controls_hidden = not visible

    # -------------------------------------------------- 倍速
    def _show_speed_menu(self, global_pos=None):
        """点击倍速按钮弹出档位菜单。

        global_pos 为 None 时定位到倍速按钮下方（从底部按钮调用）；
        不为 None 时定位到该全局坐标（从右键菜单调用）。
        """
        if self.mpv is None or not self._has_media:
            return
        menu = QMenu(self)
        cur = float(self.mpv.speed or 1.0)
        for s in SPEED_PRESETS:
            act = menu.addAction(f"{s:g}x")
            act.setCheckable(True)
            act.setChecked(abs(s - cur) < 0.01)
            act.triggered.connect(lambda _=False, sp=s: self._set_speed(sp))
        if global_pos is None:
            global_pos = self.btn_speed.mapToGlobal(QPoint(0, self.btn_speed.height()))
        menu.exec(global_pos)

    def _set_speed(self, speed: float):
        speed = max(SPEED_MIN, min(SPEED_MAX, speed))
        if self.mpv is None:
            return
        self.mpv.speed = speed
        self.btn_speed.setText(f"{speed:g}x")
        self._show_osd(f"倍速 {speed:g}x")

    def _bump_speed(self, delta: float):
        """微调倍速（[/] 键）。"""
        if self.mpv is None or not self._has_media:
            return
        cur = float(self.mpv.speed or 1.0)
        self._set_speed(round(cur + delta, 2))

    # -------------------------------------------------- 轨道切换
    def _get_tracks(self, kind: str) -> list:
        """获取音轨/字幕轨列表。kind: 'audio' / 'sub'。

        python-mpv 的 track-list 是一个 list[dict]，每项含 id/type/...
        返回 [(id, 描述)] 列表；无轨返回 []。
        """
        if self.mpv is None:
            return []
        raw = []
        try:
            raw = list(self.mpv.track_list or [])
        except Exception:
            raw = []
        out = []
        for t in raw:
            if t.get("type") != kind:
                continue
            tid = t.get("id")
            if tid is None:
                continue
            desc = t.get("title") or t.get("lang") or ""
            if t.get("codec"):
                desc = f"{desc} ({t['codec']})" if desc else t['codec']
            out.append((tid, desc or f"轨 {tid}"))
        return out

    def _show_audio_menu(self, global_pos=None):
        """弹出音轨选择菜单。global_pos 为 None 时默认定位到画面中心。"""
        if self.mpv is None or not self._has_media:
            return
        tracks = self._get_tracks("audio")
        if not tracks:
            QMessageBox.information(self, APP_NAME, "该视频没有可选音轨。")
            return
        cur = int(getattr(self.mpv, "aid", 0) or 0)
        menu = QMenu(self)
        for tid, desc in tracks:
            act = menu.addAction(f"#{tid}  {desc}")
            act.setCheckable(True)
            act.setChecked(tid == cur)
            act.triggered.connect(lambda _=False, i=tid: self._set_audio_track(i))
        if global_pos is None:
            global_pos = self.video_frame.mapToGlobal(QPoint(
                self.video_frame.width() // 2, self.video_frame.height() // 2))
        menu.exec(global_pos)

    def _set_audio_track(self, tid: int):
        if self.mpv is None:
            return
        self.mpv.audio = tid
        # 切换后查描述用于 OSD 提示
        desc = f"音轨 #{tid}"
        for i, d in self._get_tracks("audio"):
            if i == tid:
                desc = f"音轨 #{tid}  {d}" if d else desc
                break
        self._show_osd(desc)

    def _show_sub_menu(self, global_pos=None):
        """弹出字幕轨选择菜单。global_pos 为 None 时默认定位到画面中心。"""
        if self.mpv is None or not self._has_media:
            return
        tracks = self._get_tracks("sub")
        menu = QMenu(self)
        cur = int(getattr(self.mpv, "sid", 0) or 0)
        # "关闭字幕"选项
        off = menu.addAction("关闭字幕")
        off.setCheckable(True)
        off.setChecked(cur == 0)
        off.triggered.connect(lambda: self._set_sub_track(0))
        if tracks:
            menu.addSeparator()
        for tid, desc in tracks:
            act = menu.addAction(f"#{tid}  {desc}")
            act.setCheckable(True)
            act.setChecked(tid == cur)
            act.triggered.connect(lambda _=False, i=tid: self._set_sub_track(i))
        if global_pos is None:
            global_pos = self.video_frame.mapToGlobal(QPoint(
                self.video_frame.width() // 2, self.video_frame.height() // 2))
        menu.exec(global_pos)

    def _set_sub_track(self, tid: int):
        if self.mpv is None:
            return
        # tid=0 表示关闭字幕：设为 False
        if tid == 0:
            self.mpv.sub = False
            self._show_osd("字幕已关闭")
        else:
            self.mpv.sub = tid
            desc = f"字幕 #{tid}"
            for i, d in self._get_tracks("sub"):
                if i == tid:
                    desc = f"字幕 #{tid}  {d}" if d else desc
                    break
            self._show_osd(desc)

    # -------------------------------------------------- 右键上下文菜单
    def _show_context_menu(self, global_pos):
        """右键画面弹出的上下文菜单：打开文件 / 音轨 / 字幕 / 倍速。

        把原本占底部空间的"打开""音轨""字幕"按钮收进这里，画面更干净。
        倍速底部仍有按钮，这里也放一份方便全屏时操作。
        """
        menu = QMenu(self)
        # 打开文件（任何状态都能用）
        act_open = menu.addAction("打开文件…")
        act_open.triggered.connect(self.open_dialog)
        menu.addSeparator()

        # 以下项需要载入媒体后才有意义
        has_media = self._has_media and self.mpv is not None
        act_audio = menu.addAction("音轨…")
        act_audio.setEnabled(has_media)
        act_audio.triggered.connect(lambda: self._show_audio_menu(global_pos))
        act_sub = menu.addAction("字幕…")
        act_sub.setEnabled(has_media)
        act_sub.triggered.connect(lambda: self._show_sub_menu(global_pos))
        menu.addSeparator()
        act_speed = menu.addAction("倍速…")
        act_speed.setEnabled(has_media)
        act_speed.triggered.connect(lambda: self._show_speed_menu(global_pos))
        menu.addSeparator()
        act_about = menu.addAction("关于")
        act_about.triggered.connect(self._show_about)
        menu.exec(global_pos)

    # -------------------------------------------------- 更新检测
    def _update_title_suffix(self) -> str:
        """根据更新状态返回标题栏后缀。有新版本时加" (有新版本 vX)"。"""
        if self._update_state == "new" and self._update_remote:
            return f"  (有新版本 v{self._update_remote})"
        return ""

    def _refresh_title(self, filename: str = ""):
        """刷新标题栏。filename 为空 → 初始标题；非空 → 打开文件标题。
        自动追加更新提示后缀。"""
        suffix = self._update_title_suffix()
        if filename:
            self.setWindowTitle(f"{APP_NAME} —— {filename}{suffix}")
        else:
            self.setWindowTitle(f"{APP_NAME} v{APP_VERSION}{suffix}")

    def _check_for_update(self, manual: bool = False):
        """后台线程检查更新。manual=True 时在结果出来时弹 OSD 反馈。"""
        if self._update_state == "checking":
            return
        self._update_state = "checking"
        # 立即刷新关于框提示（若已打开）——这里仅更新标题后缀，关于框靠重开刷新
        self._refresh_title(self._current_filename())

        def worker():
            state = "error"
            remote = ""
            try:
                req = urllib.request.Request(
                    f"{UPDATE_URL}?t={int(__import__('time').time() * 1000)}",
                    headers={"User-Agent": f"{APP_NAME}/{APP_VERSION}"})
                with urllib.request.urlopen(req, timeout=8) as resp:
                    remote = resp.read().decode("utf-8", "ignore").strip()
                if remote and _compare_versions(remote, APP_VERSION) > 0:
                    state = "new"
                else:
                    state = "latest"
            except Exception:
                state = "error"
            # 回主线程更新 UI（PySide6 控件不能在子线程改）
            QTimer.singleShot(0, lambda: self._apply_update_result(state, remote, manual))

        threading.Thread(target=worker, daemon=True).start()

    def _apply_update_result(self, state: str, remote: str, manual: bool):
        """主线程回调：应用检测结果，刷新标题栏与已打开的关于框。"""
        self._update_state = state
        self._update_remote = remote
        self._refresh_title(self._current_filename())
        # 若关于框还开着，刷新其文本（显示"有新版本/已是最新/检查失败"）
        dlg = getattr(self, "_about_box", None)
        if dlg is not None and dlg.isVisible():
            lbl = getattr(dlg, "_label", None)
            if lbl is not None:
                lbl.setText(self._about_html())
        if manual:
            if state == "new":
                self._show_osd(f"发现新版本 v{remote}，详见关于")
            elif state == "latest":
                self._show_osd("已是最新版本")
            else:
                self._show_osd("检查更新失败")

    def _current_filename(self) -> str:
        """从当前标题栏提取已打开文件名（用于刷新标题时保留）。
        标题格式：APP_NAME —— filename[后缀] 或 APP_NAME v版本[后缀]。"""
        title = self.windowTitle()
        for sep in (" —— ", " v"):
            if sep in title:
                base = title.split(sep, 1)[1]
                # 去掉可能存在的旧后缀
                for suf in ("  (有新版本",):
                    idx = base.find(suf)
                    if idx != -1:
                        base = base[:idx]
                # 初始标题（v版本）不该当文件名返回
                if sep == " v" and base.startswith(APP_VERSION):
                    return ""
                return base.strip()
        return ""

    def _about_html(self) -> str:
        """构造关于框 HTML 文本（版本号可点击触发更新检测）。"""
        # 版本号做成链接，href="check" 表示点击检查更新
        ver_link = (f"<a href='check'>v{APP_VERSION}</a>"
                    f"{self._about_update_suffix()}")
        return (
            f"<h3>{APP_NAME} {ver_link}</h3>"
            f"<p>一个会识别自己人的万能视频播放器——既能播放普通视频，"
            f"也能识别影藏 PolyFlix 产物里的隐藏视频，"
            f"零改名、零解压。</p>"
            f"<p><b>作者：</b> hcllmsx</p>"
            f"<p><b>Bilibili：</b> 火车啦啦 "
            f"<a href='https://space.bilibili.com/255947051'>"
            f"https://space.bilibili.com/255947051</a></p>"
            f"<p><b>本项目仓库：</b><br>"
            f"<a href='https://github.com/hcllmsx/PolyFlixPlayer'>"
            f"https://github.com/hcllmsx/PolyFlixPlayer</a></p>"
            f"<p><b>姊妹项目 · 影藏 PolyFlix</b>"
            f"（把文件藏进能正常播放的 MP4）：<br>"
            f"<a href='https://github.com/hcllmsx/PolyFlix'>"
            f"https://github.com/hcllmsx/PolyFlix</a></p>"
        )

    def _about_update_suffix(self) -> str:
        """关于框版本号后的更新提示（HTML）。"""
        if self._update_state == "checking":
            return "  <span style='color:#888'>检查中…</span>"
        if self._update_state == "new" and self._update_remote:
            return (f"  <a href='{UPDATE_RELEASES_URL}' style='color:#fbbf24'>"
                    f"有新版本 v{self._update_remote}，点击下载</a>")
        if self._update_state == "latest":
            return "  <span style='color:#34d399'>已是最新</span>"
        if self._update_state == "error":
            return "  <span style='color:#f87171'>检查失败，点击版本号重试</span>"
        return ""

    def _show_about(self):
        """关于对话框：软件信息、作者、社交平台、姊妹项目。
        版本号可点击触发更新检测。用 QDialog + QLabel 实现（QMessageBox
        不转发 linkActivated 信号，无法拦截版本号点击）。"""
        from PySide6.QtGui import QDesktopServices
        from PySide6.QtCore import QUrl

        dlg = QDialog(self)
        self._about_box = dlg
        dlg.setWindowTitle(f"关于 {APP_NAME}")
        dlg.setModal(True)
        lay = QVBoxLayout(dlg)
        lay.setContentsMargins(24, 18, 24, 18)
        lay.setSpacing(12)

        # 左 logo + 右文字 水平布局
        body = QHBoxLayout()
        body.setSpacing(16)

        if getattr(self, "_logo_sq_pix", None) is not None and not self._logo_sq_pix.isNull():
            logo = QLabel(dlg)
            # 方形 logo，关于框左侧展示，等比缩放到 96×96
            pix = self._logo_sq_pix.scaled(
                96, 96, Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation)
            logo.setPixmap(pix)
            logo.setFixedSize(96, 96)
            logo.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignHCenter)
            body.addWidget(logo, 0, Qt.AlignmentFlag.AlignTop)

        label = QLabel(dlg)
        label.setTextFormat(Qt.TextFormat.RichText)
        label.setText(self._about_html())
        label.setWordWrap(True)
        label.setOpenExternalLinks(False)  # 全部自己处理：check 拦截，http 外开
        label.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextBrowserInteraction
            | Qt.TextInteractionFlag.LinksAccessibleByMouse)
        body.addWidget(label, 1)
        lay.addLayout(body)

        btn_ok = QPushButton("确定", dlg)
        btn_ok.setDefault(True)
        btn_ok.clicked.connect(dlg.accept)
        lay.addWidget(btn_ok, 0, Qt.AlignmentFlag.AlignRight)

        # 保存 label 引用，供 _apply_update_result 刷新文本（QLabel 才有 setText）
        dlg._label = label

        def on_link(link: str):
            if link == "check":
                # 点击版本号 → 手动检测；检测后由 _apply_update_result 刷新文本
                self._check_for_update(manual=False)
                label.setText(self._about_html())
            elif link.startswith("http"):
                QDesktopServices.openUrl(QUrl(link))

        label.linkActivated.connect(on_link)

        dlg.resize(480, dlg.sizeHint().height())
        dlg.exec()
        self._about_box = None

    # -------------------------------------------------- 音量
    def _toggle_volume_popup(self):
        """点击音量图标弹出/关闭音量面板。"""
        if self._volume_popup is not None:
            self._close_volume_popup()
            return
        self._open_volume_popup()

    def _open_volume_popup(self):
        """弹出音量面板：含滑块（0-100）+ 百分比 label。

        用 Qt.Popup 窗口标志：Qt 会自动在点击面板外时关闭它（无需手写
        全局鼠标过滤器）。代价是它变成独立顶层窗口，但仍以主窗口为父，
        任务栏不会多出项。
        """
        popup = QFrame(self, Qt.Popup)
        popup.setObjectName("volPopup")
        popup.setStyleSheet(
            "QFrame#volPopup { background: #1e1e1e; border: 1px solid #444;"
            "border-radius: 4px; }")
        lay = QVBoxLayout(popup)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(4)

        # 竖向滑块：0-100（mpv.volume 上限即 100）
        vol_slider = QSlider(Qt.Vertical)
        vol_slider.setRange(VOLUME_MIN, VOLUME_NORMAL)  # 0-100
        cur_vol = self._get_volume()
        vol_slider.setValue(cur_vol)
        vol_slider.setFixedHeight(140)

        vol_label = QLabel(f"{cur_vol}%")
        vol_label.setStyleSheet("color: #ddd; font-size: 12px;")
        vol_label.setAlignment(Qt.AlignCenter)

        lay.addWidget(vol_label)
        lay.addWidget(vol_slider, 1)

        def on_change(v):
            # 拖动时直接应用，label 显示当前值
            self._apply_volume(v)
            vol_label.setText(f"{v}%")

        vol_slider.valueChanged.connect(on_change)
        popup.resize(48, 190)

        # 定位到音量按钮正上方
        gp = self.btn_mute.mapToGlobal(QPoint(0, 0))
        popup.move(gp.x() + self.btn_mute.width() // 2 - popup.width() // 2,
                   gp.y() - popup.height() - 4)
        popup.show()
        popup.raise_()
        # 装事件过滤器：点面板外关闭
        popup.installEventFilter(self)
        self._volume_popup = popup
        self._volume_popup._vol_slider = vol_slider
        self._volume_popup._vol_label = vol_label

    def _close_volume_popup(self):
        if self._volume_popup is not None:
            self._volume_popup.deleteLater()
            self._volume_popup = None
            # popup 关闭后补一次 OSD：拖动期间 popup 会遮挡主画面 OSD，
            # 关闭后此时无遮挡，让用户看到最终音量（含 100% 增益提示）。
            if self.mpv is not None:
                self._show_volume_osd(self._get_volume())

    def _get_volume(self) -> int:
        """安全读取当前音量（0-100）。

        注意不能用 `mpv.volume or VOLUME_NORMAL`——音量为 0 时 0 是 falsy，
        会被误判成 None 进而取默认值 100，导致"调到 0 后按向下键跳回 95%"
        的循环。这里显式区分 None 与 0。
        """
        if self.mpv is None:
            return VOLUME_NORMAL
        try:
            v = self.mpv.volume
        except Exception:
            return VOLUME_NORMAL
        if v is None:
            return VOLUME_NORMAL
        return max(VOLUME_MIN, min(VOLUME_MAX, int(v)))

    def _apply_volume(self, value: int):
        """统一应用音量（滑块/方向键/滚轮都走这里）。"""
        if self.mpv is None:
            return
        value = max(VOLUME_MIN, min(VOLUME_MAX, value))
        # 传 float：python-mpv 对数值属性走 string 通道，float 与 int
        # 均可，但保持 float 语义更贴合 mpv 的 double 属性。
        self.mpv.volume = float(value)
        # 取消静音（当音量>0时）
        if value > 0 and getattr(self.mpv, "mute", False):
            self.mpv.mute = False
        self._refresh_mute_icon()
        self._show_volume_osd(value)

    def _toggle_mute(self):
        if self.mpv is None:
            return
        self.mpv.mute = not bool(self.mpv.mute)
        self._refresh_mute_icon()
        # 静音也显示 OSD
        if getattr(self.mpv, "mute", False):
            self._show_volume_osd(0)
        else:
            self._show_volume_osd(self._get_volume())

    def _refresh_mute_icon(self):
        """根据当前 mute 状态切换静音按钮图标。"""
        style = QApplication.style()
        muted = bool(getattr(self.mpv, "mute", False)) if self.mpv else False
        # 音量为0或静音时显示静音图标
        vol = self._get_volume()
        show_muted = muted or vol == 0
        icon = (QStyle.StandardPixmap.SP_MediaVolumeMuted if show_muted
                else QStyle.StandardPixmap.SP_MediaVolume)
        self.btn_mute.setIcon(style.standardIcon(icon))
        self.btn_mute.setChecked(muted)

    def _bump_volume(self, delta: int):
        """上下方向键/滚轮调节音量（步进 VOLUME_STEP，范围 0-100）。"""
        if self.mpv is None:
            return
        cur = self._get_volume()
        self._apply_volume(cur + delta)
        # 同步弹出面板的滑块（如果面板开着），用 clamp 后的值避免显示 105%/-5%
        if self._volume_popup is not None:
            shown = max(VOLUME_MIN, min(VOLUME_MAX, cur + delta))
            self._volume_popup._vol_slider.blockSignals(True)
            self._volume_popup._vol_slider.setValue(shown)
            self._volume_popup._vol_label.setText(f"{shown}%")
            self._volume_popup._vol_slider.blockSignals(False)

    # -------------------------------------------------- OSD
    def _show_osd(self, text: str, duration: int = 2000):
        """在画面右上角显示任意提示文本，duration 毫秒后淡出。

        统一承载音量/倍速/轨道切换等瞬时反馈，避免多套浮层。
        支持多行（用 \\n 分隔）。
        """
        self.osd_label.setText(text)
        self.osd_label.adjustSize()
        self._relayout_overlays()
        self.osd_label.show()
        self.osd_label.raise_()
        self._osd_timer.start(duration)

    def _show_volume_osd(self, value: int):
        """音量专用 OSD：百分比提示。"""
        self._show_osd(f"音量 {value}%")

    def _hide_volume_osd(self):
        self.osd_label.setVisible(False)

    # -------------------------------------------------- 进度条 / 预览
    def _on_slider_pressed(self):
        self._seeking = True

    def _on_slider_released(self):
        self._do_seek()
        self._seeking = False
        # 松开后延迟隐藏预览图
        QTimer.singleShot(800, self._hide_preview)

    def _on_slider_moved(self, value: int):
        """拖动进度条：实时 seek + 防抖抓预览图。"""
        if self.mpv is None:
            return
        dur = self.mpv.duration or 0
        if dur > 0:
            # 用 hr-seek 精确 seek（absolute），reference=absolute
            self.mpv.seek(value / 1000 * dur, reference="absolute")
        # 防抖：拖动中每 150ms 抓一张预览
        self._preview_timer.start(150)
        # 显示预览浮层
        if not self.preview_label.isVisible():
            self._show_preview_placeholder()

    def _show_preview_placeholder(self):
        """预览图加载中先显示占位。"""
        self.preview_label.setText("抓帧中…")
        self.preview_label.setStyleSheet(
            "color: #aaa; background: #000; border: 1px solid #444;"
            "padding: 20px;")
        self.preview_label.adjustSize()
        self._relayout_overlays()
        self.preview_label.show()
        self.preview_label.raise_()

    def _grab_preview(self):
        """抓取当前帧作为预览缩略图显示。

        用 mpv 的 screenshot 到临时文件（PNG），再加载进 QLabel。
        抓帧期间暂停播放会更快更稳，但会打断播放体验，这里不暂停。
        """
        if self.mpv is None or not self._has_media:
            return
        if not self._seeking:
            return
        try:
            # screenshot 模式：single（当前帧），带字幕
            # 输出到临时文件
            tmp_png = os.path.join(PLAYER_TEMP_DIR, f"preview_{os.getpid()}.png")
            # python-mpv 的 screenshot_to_file(filename, includes='subtitles')
            # 在 vo=gpu 嵌入模式下也能抓到画面（从 mpv 内部帧缓冲取）。
            self.mpv.screenshot_to_file(tmp_png, includes="video")
            # 等待文件写完（mpv 异步截图，这里轮询）
            for _ in range(30):
                if os.path.isfile(tmp_png) and os.path.getsize(tmp_png) > 0:
                    break
                QApplication.processEvents()
            pix = QPixmap(tmp_png)
            if pix.isNull():
                return
            # 缩放到合理大小（画面宽 30%）
            vw = max(1, self.video_frame.width())
            target_w = min(int(vw * 0.30), 320)
            scaled = pix.scaledToWidth(target_w, Qt.SmoothTransformation)
            self.preview_label.setPixmap(scaled)
            self.preview_label.setStyleSheet(
                "background: #000; border: 1px solid #444;")
            self.preview_label.resize(scaled.size())
            self._relayout_overlays()
            self.preview_label.show()
            self.preview_label.raise_()
        except Exception:
            # 抓帧失败不影响播放
            pass

    def _hide_preview(self):
        self.preview_label.setVisible(False)
        self.preview_label.clear()

    def _do_seek(self):
        """松开进度条后的精确 seek（保留兼容性，实际 moved 已实时 seek）。"""
        if self.mpv is None:
            return
        dur = self.mpv.duration or 0
        if dur > 0:
            self.mpv.seek(self.slider.value() / 1000 * dur, reference="absolute")

    def _seek_relative(self, delta: int):
        """左右方向键相对 seek ±delta 秒。

        用直接设置 mpv.time_pos 属性（绝对跳转）而非 seek 命令：seek 命令默认
        keyframes 精度会跳到最近关键帧，+5s 可能落在同一 GOP 区间导致位置
        不变，表现为"快进没反应"。time_pos 属性赋值是无条件绝对跳转，可靠。
        seek 后设 _seeking 锁定窗口（500ms），期间 _on_tick 不回写 slider，
        避免 mpv 跳转完成前读到旧 playback_time 把 slider 拉回。
        """
        if self.mpv is None or not self._has_media:
            return
        dur = self.mpv.duration or 0
        if dur <= 0:
            return
        pos = self.mpv.playback_time or 0
        target = max(0, min(dur, pos + delta))
        # 直接设 time_pos 属性：绝对跳转，不受 keyframe 精度限制
        try:
            self.mpv.time_pos = target
        except Exception:
            # 回退到 seek 命令（absolute + exact 精度）
            self.mpv.seek(target, reference="absolute", precision="exact")
        # 立即同步 slider + 时间标签，并锁定 _on_tick 回写 500ms 等 mpv 跳转
        self._seeking = True
        self.slider.setValue(int(target / dur * 1000))
        self.label_time.setText(f"{fmt_time(target)} / {fmt_time(dur)}")
        QTimer.singleShot(500, self._release_seek_lock)

    def _release_seek_lock(self):
        """键盘 seek 锁定到期：恢复 _on_tick 对 slider 的回写。"""
        self._seeking = False

    def _on_tick(self):
        if self.mpv is None:
            return
        # mpv core 被 terminate 后（如退出程序）定时器可能还跑最后一轮，
        # 此时读任何属性都会抛 ShutdownError。兜住静默返回，避免 traceback。
        try:
            dur = self.mpv.duration or 0
            pos = self.mpv.playback_time or 0
            paused = bool(self.mpv.pause)
        except Exception:
            return
        style = QApplication.style()
        self.btn_play.setIcon(style.standardIcon(
            QStyle.StandardPixmap.SP_MediaPause if not paused
            else QStyle.StandardPixmap.SP_MediaPlay))
        self.btn_play.setText("")
        # 锁定期间（键盘 seek 后 400ms 内）不回写 slider/时间，避免与刚设置的
        # 目标位置冲突导致回弹；解除后由 mpv 真实 playback_time 接管。
        if self._seeking:
            return
        if dur > 0:
            self.slider.setValue(int(pos / dur * 1000))
        self.label_time.setText(f"{fmt_time(pos)} / {fmt_time(dur)}")

    def export_hidden(self):
        """把隐藏视频另存出来。"""
        if not self.product_source:
            return
        # 导出默认名优先用头部记录的原始名（v2），回退用产物文件名派生
        if self.product_info and self.product_info.get("name"):
            default = self.product_info["name"]
        else:
            default = os.path.basename(self.product_source)
        # 若原名已经是视频扩展名就直接用，否则补 .mp4
        lower = default.lower()
        if not any(lower.endswith("." + e) for e in (
                "mp4", "mkv", "flv", "webm", "avi", "mov", "ts", "m4v",
                "wmv", "mpg", "mpeg", "3gp", "rmvb", "vob", "m2ts")):
            default = default + ".mp4"
        dest, _ = QFileDialog.getSaveFileName(
            self, "导出隐藏视频", default, f"视频文件 ({VIDEO_EXTS})")
        if not dest:
            return
        try:
            # 直接重新抽取（保证完整性再验一次），避免临时缓存被清理的边界情况
            pflx.extract_payload(self.product_source, dest, self.product_info)
            QMessageBox.information(
                self, APP_NAME, f"已导出隐藏视频：\n{dest}\n"
                f"（{os.path.getsize(dest):,} 字节，完整性校验通过）")
        except Exception as e:
            QMessageBox.critical(self, APP_NAME, f"导出失败：\n{e}")

    def open_dialog(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "打开视频", "", f"视频文件 ({VIDEO_EXTS});;所有文件 (*.*)")
        if path:
            self.load_file(path)

    # ------------------------------------------------------------- 拖放
    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        urls = e.mimeData().urls()
        if urls:
            self.load_file(urls[0].toLocalFile())

    def eventFilter(self, obj, event):
        # 1) 拦截按钮上的空格键：避免焦点在按钮时按空格触发按钮 clicked
        #    （如焦点在"打开"按钮时空格会弹文件对话框），统一交给主窗口做暂停。
        #    回车仍允许触发按钮（无歧义、符合可访问性预期）。
        if event.type() == QEvent.KeyPress and event.key() == Qt.Key.Key_Space:
            if obj in (self.btn_open, self.btn_play, self.btn_export,
                       self.btn_mute, self.btn_speed, self.btn_audio,
                       self.btn_sub):
                # 已载入媒体 → 暂停/播放；未载入 → 相当于 Ctrl+O 打开文件
                if self._has_media:
                    self.toggle_pause()
                else:
                    self.open_dialog()
                return True  # 事件已处理，不再向按钮传递
        # 2) 拦截 video_frame 上的双击 → 全屏切换（mpv 吞鼠标事件，必须过滤）
        #    滚轮 → 调音量；不做"点击画面暂停"（用户明确要求不要）
        if obj is self.video_frame:
            if event.type() == QEvent.MouseButtonDblClick \
                    and event.button() == Qt.LeftButton:
                self.toggle_fullscreen()
                return True
            # 右键：弹上下文菜单（打开文件/音轨/字幕/倍速）
            if event.type() == QEvent.MouseButtonPress \
                    and event.button() == Qt.RightButton:
                # 把点击位置转成全局坐标传给菜单
                gp = event.globalPosition().toPoint()
                self._show_context_menu(gp)
                return True
            if event.type() == QEvent.Wheel:
                # 滚轮向上 +VOLUME_STEP，向下 -VOLUME_STEP
                delta = event.angleDelta().y()
                if delta > 0:
                    self._bump_volume(+VOLUME_STEP)
                elif delta < 0:
                    self._bump_volume(-VOLUME_STEP)
                return True
        # 3) 音量弹出面板：在 application 层装过滤器，点面板外（任意控件）即关闭。
        #    事件过滤器只接收已安装对象的事件，所以这里装在 QApplication 上无效——
        #    实际靠 _open_volume_popup 里给 qApp 装过滤器处理（见下文）。
        #    这里只处理面板自身：Esc 关闭。
        if (self._volume_popup is not None and obj is self._volume_popup
                and event.type() == QEvent.KeyPress
                and event.key() == Qt.Key.Key_Escape):
            self._close_volume_popup()
            return True
        return super().eventFilter(obj, event)

    def keyPressEvent(self, e):
        if self.mpv is None:
            return
        # Ctrl+O 打开文件（主流播放器通用快捷键）
        if e.key() == Qt.Key.Key_O and e.modifiers() & Qt.ControlModifier:
            self.open_dialog()
            return
        # Enter / Return：全屏切换（仅载入后）
        if e.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self.toggle_fullscreen()
            return
        # Escape：全屏时退出全屏
        if e.key() == Qt.Key.Key_Escape and self.isFullScreen():
            self.toggle_fullscreen()
            return
        # 媒体相关快捷键：只在载入媒体后响应
        if self._has_media:
            if e.key() == Qt.Key.Key_Space:
                self.toggle_pause()
            elif e.key() == Qt.Key.Key_F:
                self.toggle_fullscreen()
            elif e.key() == Qt.Key.Key_Left:
                self._seek_relative(-5)
            elif e.key() == Qt.Key.Key_Right:
                self._seek_relative(5)
            elif e.key() == Qt.Key.Key_Up:
                self._bump_volume(+VOLUME_STEP)
            elif e.key() == Qt.Key.Key_Down:
                self._bump_volume(-VOLUME_STEP)
            elif e.key() == Qt.Key.Key_M:
                self._toggle_mute()
            elif e.key() == Qt.Key.Key_BracketLeft:
                self._bump_speed(-0.25)  # [ 减速
            elif e.key() == Qt.Key.Key_BracketRight:
                self._bump_speed(+0.25)  # ] 加速
            elif e.key() == Qt.Key.Key_Backslash:
                self._set_speed(1.0)     # \ 恢复 1.0x
            else:
                super().keyPressEvent(e)
        else:
            # 未载入媒体：空格 = 打开文件（相当于 Ctrl+O）
            if e.key() == Qt.Key.Key_Space:
                self.open_dialog()
            else:
                super().keyPressEvent(e)

    def closeEvent(self, e):
        # 先隐藏 OSD 顶层窗口，避免主窗口关闭后它短暂残留
        self.osd_label.close()
        if self.mpv is not None:
            try:
                self.mpv.terminate()
            except Exception:
                pass
        # 清理本播放器的临时载荷目录
        try:
            if os.path.isdir(PLAYER_TEMP_DIR):
                shutil.rmtree(PLAYER_TEMP_DIR, ignore_errors=True)
        except Exception:
            pass
        super().closeEvent(e)


def fmt_time(sec: float) -> str:
    sec = max(0, int(sec))
    h, m, s = sec // 3600, sec % 3600 // 60, sec % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    # 全局应用图标（任务栏分组 / 缺省窗口图标）
    if os.path.isfile(ICON_PATH):
        app.setWindowIcon(QIcon(ICON_PATH))
    win = PlayerWindow()
    win.show()
    # 命令行直接传文件：python player.py xxx.mp4
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        QTimer.singleShot(100, lambda: win.load_file(sys.argv[1]))
    sys.exit(app.exec())


if __name__ == "__main__":
    main()