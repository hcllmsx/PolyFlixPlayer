/// PFLX 双视频格式 —— 播放器侧解析模块（从 PolyFlixPlayer/pflx.py 移植）。
///
/// 产物结构（一个完全合法的 MP4）：
///   [ a.mp4 原样字节（ftyp/moov/mdat...） ]
///   [ free box: size(4) + 'free'(4) [+ largesize(8)]
///       └─ PFLX 头部（22 + name_len 字节） + 载荷（b 视频的原始字节）]
///
/// PFLX 头部（全部大端）：
///   offset  size  字段
///   0       4     magic     固定 "PFLX"
///   4       1     version   格式版本，固定为 1
///   5       1     flags     标志位
///   6       2     reserved  保留，写 0
///   8       8     length    载荷长度（字节数）
///   16      4     crc32     载荷的 CRC32
///   20      2     name_len  隐藏文件原始名的字节数（UTF-8）
///   22      name_len  name  隐藏文件原始名（UTF-8 字节）
///
/// 与 PolyFlixPlayer/pflx.py 保持逻辑一致；修改须同步。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 进度回调：(已处理字节数, 总字节数)
typedef ProgressCallback = void Function(int done, int total);

/// 各解析/构建函数返回的 Map 结构（键固定，值类型混合）。
typedef PflxInfo = Map<String, dynamic>;

// ---- 格式常量（与 pflx.py 共用） ----
const List<int> kMagic = [0x50, 0x46, 0x4C, 0x58]; // "PFLX"
const int kFormatVersion = 1;

// flags 位（当前未使用，为未来加密等特性预留）
const int kFlagEncrypted = 0x01;

// 固定头部前 20 字节：magic(4) + version(1) + flags(1) + reserved(2) + length(8) + crc32(4)
const int _fixedHeaderSize = 20;
// name 字段：name_len(2 字节, 大端) + name_bytes(name_len 字节, UTF-8)
const int _nameLenField = 2;

// 头部最小字节数（无名字时）：20 + 2 = 22
const int kHeaderSize = _fixedHeaderSize + _nameLenField;

// free box 类型标记
const List<int> _boxTypeFree = [0x66, 0x72, 0x65, 0x65]; // "free"

/// 标准 CRC32（IEEE 802.3，与 Python zlib.crc32 完全一致）。
/// 采用反射（reflected/incremental）实现，支持分段续算。
/// [crc] 为上一分段的累加值（初始 0），实现流式计算。
int _crc32(Uint8List bytes, [int crc = 0]) {
  const kPoly = 0xEDB88320; // 反射多项式
  crc = crc ^ 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) {
    crc ^= bytes[i];
    for (var b = 0; b < 8; b++) {
      final mask = (crc & 1) != 0 ? kPoly : 0;
      crc = (crc >> 1) ^ mask;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// 扫描 MP4 顶层 box 链，定位 PFLX 载荷。
///
/// 返回:
///   {
///     "box_offset":      free box 在文件中的起始偏移
///     "payload_offset":  载荷（b 视频字节）的起始偏移
///     "payload_len":     载荷长度
///     "version":         PFLX 格式版本
///     "flags":           标志位
///     "encrypted":       是否加密
///     "crc32":           头部里记录的载荷 CRC32
///     "name":            隐藏文件原始名（无名字时为 null）
///     "file_size":       文件总大小
///   }
/// 不是 PFLX 产物（或损坏）返回 null。
PflxInfo? scan(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final fileSize = file.lengthSync();
  final raf = file.openSync(mode: FileMode.read);
  try {
    var offset = 0;
    while (offset < fileSize) {
      // 读 box 头 size(4) + type(4)
      final head = _readExact(raf, 8);
      if (head == null || head.length < 8) return null;

      final size32 = _byteData(head).getUint32(0, Endian.big);
      final boxType = head.sublist(4, 8);

      int boxSize;
      int boxHeader;
      if (size32 == 1) {
        // 64 位 largesize
        final large = _readExact(raf, 8);
        if (large == null || large.length < 8) return null;
        boxSize = _byteData(large).getUint64(0, Endian.big);
        boxHeader = 16;
      } else if (size32 == 0) {
        // size=0：本 box 延伸到文件末尾
        boxSize = fileSize - offset;
        boxHeader = 8;
      } else {
        boxSize = size32;
        boxHeader = 8;
      }

      if (boxSize < boxHeader || offset + boxSize > fileSize) {
        // box 链损坏（超出了文件范围）→ 非法文件，当作非产物处理
        return null;
      }

      final isFree = _listEquals(boxType, _boxTypeFree);
      if (isFree && boxSize - boxHeader >= kHeaderSize) {
        final payloadHeader = _readExact(raf, _fixedHeaderSize);
        if (payloadHeader == null || payloadHeader.length < _fixedHeaderSize) {
          return null;
        }
        final bd = _byteData(payloadHeader);
        final magic = payloadHeader.sublist(0, 4);
        final ver = payloadHeader[4];
        final flags = payloadHeader[5];
        // reserved = bd.getUint16(6, Endian.big) —— 未使用
        final plen = bd.getUint64(8, Endian.big);
        final crc = bd.getUint32(16, Endian.big);

        if (_listEquals(magic, kMagic)) {
          // 读 name_len + name 字段
          if (boxSize - boxHeader - _fixedHeaderSize < _nameLenField) {
            return null; // 空间不够 → 损坏
          }
          final nlBytes = _readExact(raf, _nameLenField);
          if (nlBytes == null || nlBytes.length < _nameLenField) return null;
          final nameLen = _byteData(nlBytes).getUint16(0, Endian.big);
          // name_len 不能超出 box 剩余空间（载荷之前）
          final maxAvail = boxSize - boxHeader - kHeaderSize;
          if (nameLen > maxAvail) return null; // 名字长度超过可用空间 → 损坏

          String? name;
          if (nameLen > 0) {
            final nb = _readExact(raf, nameLen);
            if (nb == null || nb.length < nameLen) return null;
            try {
              name = utf8.decode(nb);
            } catch (_) {
              name = null; // 名字损坏不致命，降级为 null
            }
          }
          final extra = kHeaderSize + nameLen;
          return {
            'box_offset': offset,
            'payload_offset': offset + boxHeader + extra,
            'payload_len': plen,
            'version': ver,
            'flags': flags,
            'encrypted': (flags & kFlagEncrypted) != 0,
            'crc32': crc,
            'name': name,
            'file_size': fileSize,
          };
        }
        // 普通 free box（无 PFLX 魔数）→ 跳过，继续扫
        raf.setPositionSync(offset + boxSize);
      } else {
        raf.setPositionSync(offset + boxSize);
      }
      offset += boxSize;
    }
  } on FileSystemException {
    return null;
  } finally {
    raf.closeSync();
  }
  return null;
}

/// 快速判断文件是否为 PFLX 双视频产物。
bool isPflxProduct(String path) {
  final info = scan(path);
  if (info == null) return false;
  return info['payload_offset'] + info['payload_len'] <= info['file_size'];
}

/// 流式校验载荷 CRC32。
bool verifyPayloadCrc(String path, [PflxInfo? info]) {
  info ??= scan(path);
  if (info == null) return false;
  final payloadOffset = info['payload_offset'] as int;
  var remaining = info['payload_len'] as int;
  final crcExpected = info['crc32'] as int;

  final file = File(path);
  final raf = file.openSync(mode: FileMode.read);
  try {
    raf.setPositionSync(payloadOffset);
    int crc = 0;
    const chunkSize = 8 * 1024 * 1024;
    while (remaining > 0) {
      final toRead = remaining < chunkSize ? remaining : chunkSize;
      final chunk = raf.readSync(toRead);
      if (chunk.isEmpty) return false;
      crc = _crc32(chunk, crc);
      remaining -= chunk.length;
    }
    return (crc & 0xFFFFFFFF) == crcExpected;
  } on FileSystemException {
    return false;
  } finally {
    raf.closeSync();
  }
}

/// 把 PFLX 载荷原样抽出到 destPath（流式，带 CRC 校验）。返回统计 Map。
PflxInfo extractPayload(
  String path,
  String destPath, [
  PflxInfo? info,
  ProgressCallback? progress,
]) {
  info ??= scan(path);
  if (info == null) throw ArgumentError('不是 PFLX 产物');
  if (info['payload_offset'] + info['payload_len'] > info['file_size']) {
    throw ArgumentError('载荷长度与文件大小不符，文件可能已损坏');
  }
  final payloadOffset = info['payload_offset'] as int;
  var remaining = info['payload_len'] as int;
  final crcExpected = info['crc32'] as int;

  final src = File(path).openSync(mode: FileMode.read);
  final out = File(destPath).openSync(mode: FileMode.writeOnly);
  try {
    src.setPositionSync(payloadOffset);
    int crc = 0;
    var done = 0;
    const chunkSize = 8 * 1024 * 1024;
    while (remaining > 0) {
      final toRead = remaining < chunkSize ? remaining : chunkSize;
      final chunk = src.readSync(toRead);
      if (chunk.isEmpty) {
        throw ArgumentError('读取提前结束，文件可能已损坏');
      }
      out.writeFromSync(chunk);
      crc = _crc32(chunk, crc);
      remaining -= chunk.length;
      done += chunk.length;
      progress?.call(done, info['payload_len'] as int);
    }
    if ((crc & 0xFFFFFFFF) != crcExpected) {
      throw ArgumentError(
        'CRC32 校验失败（读得 ${_hex(crc & 0xFFFFFFFF)}，应为 ${_hex(crcExpected)}），文件可能已损坏',
      );
    }
    return {'payload_len': info['payload_len'], 'crc32': crc & 0xFFFFFFFF};
  } finally {
    src.closeSync();
    out.closeSync();
  }
}

// ---- 小工具 ----

/// 从 RandomAccessFile 读取恰好 [count] 字节；不足返回 null。
Uint8List? _readExact(RandomAccessFile raf, int count) {
  final buf = raf.readSync(count);
  return buf.length == count ? buf : null;
}

ByteData _byteData(Uint8List bytes) =>
    ByteData.sublistView(bytes);

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(int v) =>
    v.toRadixString(16).padLeft(8, '0');
