/// 通过引擎包里的 `whisper-server.exe` 做语音识别。
///
/// 相比 FFI 直调插件的优势：
///  1. 模型常驻内存，长视频切片识别时不必反复加载模型；
///  2. 官方预编译包自带 CUDA 后端，**不需要自己编译**就能用上 GPU；
///  3. 识别结果与 FFI 路径同为 whisper.cpp 产物，可无缝对接现有后处理。
///
/// 生命周期：进程按"引擎包 + 模型 + 线程数 + 是否强制 CPU"复用；闲置一段时间后
/// 自动关闭，避免长期占用显存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'engine_pack.dart';

/// 服务端返回的一段识别结果。
class ServerSegment {
  const ServerSegment({required this.startMs, required this.endMs, required this.text});

  final int startMs;
  final int endMs;
  final String text;
}

/// 一个常驻的 whisper-server 会话。
class WhisperServerSession {
  WhisperServerSession._(
    this._process, {
    required this.pack,
    required this.modelPath,
    required this.threads,
    required this.forceCpu,
    required this.port,
  }) : _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);

  /// 当前活动会话（同配置复用）。
  static WhisperServerSession? _current;
  static Future<WhisperServerSession?>? _starting;

  /// 闲置多久后自动关闭服务进程。
  static const Duration idleTimeout = Duration(minutes: 3);

  final EnginePack pack;
  final String modelPath;
  final int threads;

  /// 用户勾选了"强制使用 CPU"（引擎包仍用官方构建，只是加 `-ng` 禁用 GPU）。
  final bool forceCpu;

  final int port;
  final Process _process;
  final HttpClient _client;

  Timer? _idleTimer;
  bool _exited = false;
  final List<String> _logTail = [];

  /// 是否已退出（退出后需要重新启动）。
  bool get isAlive => !_exited;

  /// 启动（或复用）一个服务会话。
  ///
  /// 返回 null 表示引擎包不可用（进程起不来 / 就绪超时），调用方应回落到
  /// 内置的 FFI 插件路径。
  static Future<WhisperServerSession?> acquire({
    required EnginePack pack,
    required String modelPath,
    required int threads,
    bool forceCpu = false,
  }) {
    final current = _current;
    if (current != null &&
        current.isAlive &&
        current.modelPath == modelPath &&
        current.threads == threads &&
        current.forceCpu == forceCpu &&
        current.pack.serverExePath == pack.serverExePath) {
      current.keepAlive();
      return Future.value(current);
    }

    // 配置变了：先关掉旧会话，再重新启动（并发调用共享同一个启动过程）
    final starting = _starting;
    if (starting != null) return starting;

    final future = _start(pack, modelPath, threads, forceCpu);
    _starting = future;
    return future.whenComplete(() => _starting = null);
  }

  static Future<WhisperServerSession?> _start(
    EnginePack pack,
    String modelPath,
    int threads,
    bool forceCpu,
  ) async {
    await _shutdownCurrent();

    Process? process;
    try {
      final port = await _pickFreePort();
      final args = <String>[
        '-m', modelPath,
        '-t', '$threads',
        '--host', '127.0.0.1',
        '--port', '$port',
        if (forceCpu) '-ng',
      ];
      process = await Process.start(
        pack.serverExePath,
        args,
        workingDirectory: pack.dirPath,
        runInShell: false,
      );

      final session = WhisperServerSession._(
        process,
        pack: pack,
        modelPath: modelPath,
        threads: threads,
        forceCpu: forceCpu,
        port: port,
      );

      // 收集日志尾部：既用于诊断，也用于提取设备名
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => session._onLogLine(line));
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => session._onLogLine(line));

      process.exitCode.then((_) {
        session._exited = true;
      });

      final ready = await session._waitReady(const Duration(seconds: 60));
      if (!ready) {
        await session.shutdown();
        return null;
      }
      session.keepAlive();
      _current = session;
      return session;
    } catch (_) {
      try {
        process?.kill();
      } catch (_) {}
      return null;
    }
  }

  /// 关闭当前会话（模型切换、退出、闲置超时等场景）。
  static Future<void> _shutdownCurrent() async {
    final current = _current;
    _current = null;
    if (current != null) {
      await current.shutdown();
    }
  }

  /// 结束当前会话（供外部在取消任务 / 退出时调用）。
  static Future<void> shutdownAny() => _shutdownCurrent();

  /// 用一个空闲端口启动服务。
  static Future<int> _pickFreePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  void _onLogLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _logTail.add(trimmed);
    if (_logTail.length > 200) _logTail.removeAt(0);
  }

  /// 从日志里找出 GPU 设备名，用于界面上展示"实际用的是哪块卡"。
  String? _extractDeviceName() {
    for (final line in _logTail) {
      final match = RegExp(r'Device \d+:\s*([^,]+),').firstMatch(line);
      if (match != null) return match.group(1)?.trim();
    }
    return null;
  }

  /// 轮询端口直到服务就绪。
  Future<bool> _waitReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_exited) return false;
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        socket.destroy();
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    return false;
  }

  /// 重置闲置计时器。
  void keepAlive() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      // 闲置关闭：释放进程与显存占用，下次识别时再按需启动
      if (identical(_current, this)) {
        _current = null;
      }
      shutdown();
    });
  }

  /// 识别一个 WAV 文件，返回原始分段（未做任何后处理）。
  Future<List<ServerSegment>> transcribeWavFile(
    String wavPath, {
    String language = 'auto',
  }) async {
    keepAlive();
    final bytes = await File(wavPath).readAsBytes();
    final body = _buildMultipart(
      fileField: 'file',
      fileName: 'chunk.wav',
      fileBytes: bytes,
      fields: {
        'response_format': 'verbose_json',
        'language': language.isEmpty ? 'auto' : language,
        // 与内置插件保持一致：抑制 [BLANK_AUDIO] 之类的非语音标注
        'suppress_nst': 'true',
      },
    );

    final uri = Uri.parse('http://127.0.0.1:$port/inference');
    final request = await _client.postUrl(uri);
    request.headers.set(
      'Content-Type',
      'multipart/form-data; boundary=$_boundary',
    );
    request.headers.set('Content-Length', '${body.length}');
    request.add(body);

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException('识别服务返回 ${response.statusCode}: $text');
    }

    final map = jsonDecode(text) as Map<String, dynamic>;
    return _parseSegments(map);
  }

  List<ServerSegment> _parseSegments(Map<String, dynamic> map) {
    final raw = map['segments'] as List<dynamic>?;
    if (raw == null) return const [];

    final result = <ServerSegment>[];
    for (final item in raw) {
      final seg = item as Map<String, dynamic>;
      final text = (seg['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) continue;

      int startMs;
      int endMs;
      if (seg['start'] != null && seg['end'] != null) {
        // verbose_json：秒（浮点）
        startMs = ((seg['start'] as num).toDouble() * 1000).round();
        endMs = ((seg['end'] as num).toDouble() * 1000).round();
      } else if (seg['offsets'] is Map) {
        final offsets = seg['offsets'] as Map<String, dynamic>;
        startMs = (offsets['from'] as num?)?.toInt() ?? 0;
        endMs = (offsets['to'] as num?)?.toInt() ?? 0;
      } else {
        continue;
      }
      result.add(ServerSegment(startMs: startMs, endMs: endMs, text: text));
    }
    return result;
  }

  /// 设备信息：优先用日志里解析出的 GPU 名称，否则退回引擎包类型。
  String get resolvedDeviceName => _extractDeviceName() ?? pack.displayName;

  /// 关闭服务进程。
  Future<void> shutdown() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _client.close(force: true);
    if (_exited) return;
    _exited = true;
    try {
      _process.kill();
      // 给进程一点退出时间，避免留下僵尸进程
      await _process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          try {
            _process.kill(ProcessSignal.sigkill);
          } catch (_) {}
          return -1;
        },
      );
    } catch (_) {}
  }

  static const String _boundary = '----polyflixasrboundary';

  /// 手工拼 multipart/form-data 请求体（避免引入额外依赖）。
  static Uint8List _buildMultipart({
    required String fileField,
    required String fileName,
    required Uint8List fileBytes,
    required Map<String, String> fields,
  }) {
    final builder = BytesBuilder();
    void write(String s) => builder.add(utf8.encode(s));

    for (final entry in fields.entries) {
      write('--$_boundary\r\n');
      write('Content-Disposition: form-data; name="${entry.key}"\r\n\r\n');
      write('${entry.value}\r\n');
    }
    write('--$_boundary\r\n');
    write('Content-Disposition: form-data; name="$fileField"; filename="$fileName"\r\n');
    write('Content-Type: application/octet-stream\r\n\r\n');
    builder.add(fileBytes);
    write('\r\n--$_boundary--\r\n');
    return builder.takeBytes();
  }
}
