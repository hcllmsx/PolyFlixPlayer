/// 本地回环 HTTP 服务器：把 PFLX 产物中的隐藏视频以**流式**方式提供给播放器。
///
/// 为什么这么做：
///   media_kit(libmpv) 在安卓/iOS 上不暴露"从文件中间某偏移读"的自定义数据源，
///   但 libmpv 原生支持通过 HTTP Range 流式拉取。于是我们在本地 127.0.0.1 起一个
///   一次性 HTTP 服务，把请求映射到原文件 [payloadOffset, payloadOffset+payloadLen)
///   区间。播放器用 `http://127.0.0.1:<port>/pflx` 播放即可——**不落盘、不拷临时文件**。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'pflx.dart';

/// 单个 PFLX 隐藏视频的流式 HTTP 服务。
class PflxStreamServer {
  PflxStreamServer._(this._info, this._file, this._server, this._port);

  final PflxInfo _info;
  final File _file;
  final HttpServer _server;
  final int _port;

  int get payloadOffset => _info['payload_offset'] as int;
  int get payloadLen => _info['payload_len'] as int;
  String? get name => _info['name'] as String?;

  /// 返回播放器可直接播放的本地 URL。
  String get url => 'http://127.0.0.1:$_port/pflx';

  /// 在原文件中隐藏视频占用的区间 [payloadOffset, payloadOffset+payloadLen)。
  int get _end => payloadOffset + payloadLen;

  /// 启动一个服务，映射 [info] 指向的隐藏视频。
  ///
  /// [path] 为 PFLX 产物文件路径。返回已就绪的服务器实例（其 [url] 可立即用于播放）。
  static Future<PflxStreamServer> start(String path, [PflxInfo? info]) async {
    info ??= scan(path);
    if (info == null) throw ArgumentError('不是 PFLX 产物');
    if (info['payload_offset'] + info['payload_len'] >
        info['file_size']) {
      throw ArgumentError('载荷长度与文件大小不符，文件可能已损坏');
    }
    final file = File(path);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final instance = PflxStreamServer._(info, file, server, port);

    server.listen(
      (request) => instance._handle(request),
      onError: (e) {
        // 忽略偶发连接错误，保持服务可用
      },
    );
    return instance;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final requestedStart = payloadOffset;
      final requestedEnd = _end - 1; // 含端点（HTTP Range 语义）

      // 解析 Range 头（libmpv 必带，用于 seek/流式分段拉取）
      int start = requestedStart;
      int end = requestedEnd;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.toLowerCase().startsWith('bytes=')) {
        final spec = range.substring(6).split(',').first.trim();
        if (spec.endsWith('-')) {
          final s = int.parse(spec.substring(0, spec.length - 1));
          start = requestedStart + s;
          end = requestedEnd;
        } else if (spec.startsWith('-')) {
          final fromEnd = int.parse(spec.substring(1));
          start = _end - fromEnd;
          end = requestedEnd;
        } else {
          final parts = spec.split('-');
          final s = int.parse(parts[0]);
          final e = int.parse(parts[1]);
          start = requestedStart + s;
          end = requestedStart + e;
        }
      }
      // 限制在载荷区间内
      start = start.clamp(payloadOffset, _end - 1);
      end = end.clamp(payloadOffset, _end - 1);
      final length = end - start + 1;

      // 探测内容类型（取前 12 字节做简单判断，否则交给 libmpv 自行探测）
      final ctype = await _probeContentType(start);

      request.response
        ..statusCode = (range != null) ? HttpStatus.partialContent : HttpStatus.ok
        ..headers.contentLength = length
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.contentType = ContentType.parse(ctype);
      if (range != null) {
        // 返回相对载荷起始的偏移，便于播放器 seek 计算
        final contentStart = start - payloadOffset;
        final contentEnd = end - payloadOffset;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $contentStart-$contentEnd/$payloadLen',
        );
      }

      // 流式写出，每块 256KB，避免大文件一次性占内存
      const chunkSize = 256 * 1024;
      final raf = _file.openSync(mode: FileMode.read);
      try {
        raf.setPositionSync(start);
        var remaining = length;
        while (remaining > 0) {
          final toRead = remaining < chunkSize ? remaining : chunkSize;
          final chunk = raf.readSync(toRead);
          if (chunk.isEmpty) break;
          request.response.add(chunk);
          remaining -= chunk.length;
          // 让出事件循环，保证多段请求可并行处理
          if (remaining > 0) await Future<void>.delayed(Duration.zero);
        }
      } finally {
        raf.closeSync();
      }
      await request.response.close();
    } catch (e) {
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      } catch (_) {}
    }
  }

  /// 简单内容类型探测：读前若干字节判 ftyp/ID3/FLV/WebM 等。
  Future<String> _probeContentType(int atOffset) async {
    final raf = _file.openSync(mode: FileMode.read);
    try {
      raf.setPositionSync(atOffset);
      final head = raf.readSync(16);
      if (head.length < 12) return 'application/octet-stream';
      final bd = ByteData.sublistView(head);
      final t = bd.getUint32(4, Endian.big);
      // 'ftyp' = 0x66747970
      if (t == 0x66747970) {
        final major = String.fromCharCodes(head.sublist(8, 12));
        switch (major) {
          case 'isom':
          case 'mp42':
          case 'avc1':
          case 'dash':
            return 'video/mp4';
          case 'qt  ':
          case 'm4v ':
            return 'video/mp4';
        }
        return 'video/mp4';
      }
      // 'FLV' = 0x464C56
      if (head[0] == 0x46 && head[1] == 0x4C && head[2] == 0x56) {
        return 'video/x-flv';
      }
      // 'ID3' = 0x494433
      if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        return 'audio/mpeg';
      }
      // WebM/EBML: 0x1A45DFA3
      if (head[0] == 0x1A && head[1] == 0x45 &&
          head[2] == 0xDF && head[3] == 0xA3) {
        return 'video/webm';
      }
      // Matroska: EBML doc type 之后含 'matroska'
      if (head[0] == 0x1A && head[1] == 0x45) {
        return 'video/x-matroska';
      }
      return 'application/octet-stream';
    } finally {
      raf.closeSync();
    }
  }

  /// 停止服务并释放端口。
  Future<void> stop() async {
    await _server.close(force: true);
  }
}
