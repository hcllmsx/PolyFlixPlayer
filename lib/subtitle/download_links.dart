/// 网盘下载入口（语音模型 / 识别引擎包）。
///
/// 设计约定：应用**不内置任何直链下载**（官方源、国内镜像都不内置）。所有
/// `ggml-*.bin` 模型与 whisper.cpp 引擎包，都由用户从网盘自行下载，再用界面上的
/// 「导入模型」/「导入引擎」导入。这样既不依赖第三方站点可用性，也不产生流量成本。
///
/// 维护方式：一份资料通常同时放好几个网盘（各家限速/容量不同，用户挑顺手的用），
/// 所以模型与引擎各自挂**一组**链接，而不是单个链接。要增删就在下面的列表里改：
/// [kModelNetdiskLinks] 是模型，[kEngineNetdiskLinks] 是引擎包，
/// 界面会把它们渲染成可复制、可一键打开的卡片（[NetdiskLinksCard]）。
/// 列表为空时界面显示补充说明，不会报错也不会留白。
library;

/// 一条网盘分享。
class NetdiskLink {
  const NetdiskLink({
    required this.name,
    required this.url,
    this.extractCode = '',
  });

  /// 网盘名（如 `夸克网盘`），界面上作为标签显示。
  final String name;

  /// 分享链接。
  final String url;

  /// 提取码；目前这两份分享都免提取码，留空即可。
  final String extractCode;

  /// 复制给别人 / 贴到浏览器时用的文本：有提取码时带上，没有就只有链接。
  String get clipboardText =>
      extractCode.isEmpty ? url : '$url 提取码：$extractCode';
}

/// 语音模型（ggml-*.bin）的网盘；两个盘内容一样，挑一个下载就行。
const List<NetdiskLink> kModelNetdiskLinks = [
  NetdiskLink(
    name: '夸克网盘',
    url: 'https://pan.quark.cn/s/f140317c7abf',
  ),
  NetdiskLink(
    name: '百度网盘',
    url: 'https://pan.baidu.com/s/5S3hOE8dHoWEAih3wefTYWg',
  ),
];

/// 识别引擎包（whisper.cpp 官方预编译 zip）的网盘。
const List<NetdiskLink> kEngineNetdiskLinks = [
  NetdiskLink(
    name: '夸克网盘',
    url: 'https://pan.quark.cn/s/0f91d08f5084',
  ),
  NetdiskLink(
    name: '百度网盘',
    url: 'https://pan.baidu.com/s/5SfBHQP5hgMRtbHlkbG3vZw',
  ),
];
