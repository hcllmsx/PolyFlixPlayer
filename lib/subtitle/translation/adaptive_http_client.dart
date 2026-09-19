/// 自适应智能 HTTP 客户端：针对科学上网代理软件（v2ray / Clash / TUN 虚拟网卡）
/// 导致的 10054 (WSAECONNRESET) 与 TLS 握手重置进行自适应容错与通道回退。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../settings/app_settings.dart';

class AdaptiveHttpClient {
  AdaptiveHttpClient._();

  static final List<int> _commonProxyPorts = [10808, 7890, 10809, 7897, 10811, 2080];
  static int? _cachedProxyPort;
  static DateTime? _lastDetectTime;

  /// 快速探测本地正在监听的常见代理端口（5 分钟内缓存）。
  static Future<int?> detectLocalProxyPort({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedProxyPort != null &&
        _lastDetectTime != null &&
        DateTime.now().difference(_lastDetectTime!).inMinutes < 5) {
      return _cachedProxyPort;
    }

    for (final port in _commonProxyPorts) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 250),
        );
        socket.destroy();
        _cachedProxyPort = port;
        _lastDetectTime = DateTime.now();
        return port;
      } catch (_) {}
    }
    _cachedProxyPort = null;
    _lastDetectTime = DateTime.now();
    return null;
  }

  /// 创建单个 HttpClient 实例
  static http.Client _createClient({int? proxyPort, bool forceDirect = false}) {
    final ioClient = HttpClient();
    ioClient.connectionTimeout = const Duration(seconds: 10);
    // 忽略代理工具自签名证书或中间人重写导致的 HandshakeException
    ioClient.badCertificateCallback = (cert, host, port) => true;

    if (forceDirect) {
      ioClient.findProxy = (uri) => 'DIRECT';
    } else if (proxyPort != null) {
      ioClient.findProxy = (uri) => 'PROXY 127.0.0.1:$proxyPort; DIRECT';
    } else {
      // 默认系统代理与环境代理
      ioClient.findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);
    }

    return IOClient(ioClient);
  }

  /// 自适应双通道发送 POST 请求：在直连与本地代理之间自动容错。
  static Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
    Duration timeout = const Duration(seconds: 12),
    String? overrideProxyMode,
    String? overrideCustomProxy,
  }) async {
    final mode = overrideProxyMode ?? aiTranslationProxyMode.value;
    final custom = overrideCustomProxy ?? aiTranslationCustomProxy.value;

    int? customPort;
    if (mode == 'custom' && custom.isNotEmpty) {
      final match = RegExp(r':(\d+)$').firstMatch(custom.trim());
      if (match != null) {
        customPort = int.tryParse(match.group(1)!);
      }
    }

    // 构建有序尝试的 Client 通道列表
    final List<http.Client> clients = [];

    if (mode == 'direct') {
      clients.add(_createClient(forceDirect: true));
    } else if (mode == 'custom' && customPort != null) {
      clients.add(_createClient(proxyPort: customPort));
      clients.add(_createClient(forceDirect: true));
    } else {
      // auto 模式：先探测本地常见代理端口
      final detectedPort = await detectLocalProxyPort();
      if (detectedPort != null) {
        // 本地开启了代理（如 v2ray / clash），优先走本地代理端口以避开 TUN 驱动死锁与 10054
        clients.add(_createClient(proxyPort: detectedPort));
        clients.add(_createClient(forceDirect: true));
      } else {
        // 未检测到本地代理，优先直连，备选系统环境代理
        clients.add(_createClient(forceDirect: true));
        clients.add(_createClient());
      }
    }

    dynamic lastError;
    for (int i = 0; i < clients.length; i++) {
      final client = clients[i];
      try {
        final res = await client
            .post(uri, headers: headers, body: body, encoding: encoding)
            .timeout(timeout);
        return res;
      } catch (e) {
        lastError = e;
        // 如果遭遇网络异常且存在备选通道，自动流转到下一个客户端
      } finally {
        client.close();
      }
    }

    throw lastError ?? Exception('所有网络连接通道均尝试失败');
  }
}
