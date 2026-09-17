/// 网盘下载入口（语音模型 / 识别引擎包）。
///
/// 设计约定：应用**不内置任何直链下载**（官方源、国内镜像都不内置）。所有
/// `ggml-*.bin` 模型与 whisper.cpp 引擎包，都由用户从网盘自行下载，再用界面上的
/// 「导入模型」/「导入引擎」导入。这样既不依赖第三方站点可用性，也不产生流量成本。
///
/// 维护方式：把网盘分享链接与提取码填到下面的常量里，界面会自动展示成可复制的入口；
/// 留空时界面显示"链接待补充"，不会报错。将来若想给不同文件配不同链接，可以在
/// [WhisperModelInfo] / 引擎条目上各加一个 url 字段，这里的全局链接作为默认值。
library;

/// 模型文件（ggml-*.bin）的网盘链接；留空表示尚未提供。
const String kModelNetdiskUrl = '';

/// 模型网盘的提取码（没有就留空）。
const String kModelNetdiskCode = '';

/// 识别引擎包（whisper.cpp 官方 zip）的网盘链接；留空表示尚未提供。
const String kEngineNetdiskUrl = '';

/// 引擎包网盘的提取码（没有就留空）。
const String kEngineNetdiskCode = '';
