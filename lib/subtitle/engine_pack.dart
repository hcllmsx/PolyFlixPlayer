/// 本地识别引擎包（whisper.cpp 官方预编译二进制）的定位、识别与选择。
///
/// 背景：
///  - 内置的 `whisper_ggml` 插件是**纯 CPU 构建**（原生层硬编码 use_gpu=false），
///    所以默认情况下识别只能跑 CPU；
///  - whisper.cpp 官方发布了预编译的 Windows 二进制（CPU 包 / CUDA 包），
///    里面是 `whisper-server.exe` + `whisper.dll` + `ggml-*.dll`，
///    CUDA 包还会带 `ggml-cuda.dll` 与 cudart/cublas 运行库。
///
/// 因此我们采用"引擎包"模式：
///  - 引擎包存在 → 用包里的 whisper-server.exe 做识别（模型常驻、可 GPU 加速）；
///  - 引擎包不存在 → 回落到内置插件（FFI / CPU），保证开箱即用。
///
/// 目录约定（Windows）：`%LOCALAPPDATA%\PolyFlixPlayer\engine\`
///  - 直接解压官方 zip 到该目录即可（包内自带 `Release\` 子目录，会被自动识别）；
///  - 也支持多个引擎包共存于子目录（如 `engine\cuda124\`、`engine\cpu\`），
///    由 [EnginePackManager.resolvePreferred] 按能力与设置挑选。
///
/// 开发期可用环境变量 `POLYFLIX_ENGINE_DIR` 覆盖引擎目录，便于联调。
library;

import 'dart:async';
import 'dart:io';

/// 引擎包类型。
enum EngineKind {
  /// 纯 CPU 引擎包（官方 `whisper-bin-x64.zip`）。
  cpu,

  /// NVIDIA 显卡加速（官方 `whisper-cublas-*-bin-x64.zip`）。
  cuda,

  /// 多品牌显卡加速（官方未提供，需自行编译后按同样约定放入）。
  vulkan,
}

/// 一个可用的引擎包。
class EnginePack {
  const EnginePack({
    required this.dirPath,
    required this.rootDirPath,
    required this.serverExePath,
    required this.kind,
  });

  /// 可执行文件所在目录（官方包解压后通常是 `<包根>\Release\`）。
  final String dirPath;

  /// 引擎目录下的第一层子目录，即"这个包自己的根目录"。
  ///
  /// 替换引擎包时删除的是这个目录（而不是 [dirPath]）——否则解压出来的
  /// `Release\` 会被再套一层，变成 `Release\Release\`。
  final String rootDirPath;

  /// `whisper-server.exe` 的完整路径。
  final String serverExePath;

  /// 引擎类型。
  final EngineKind kind;

  /// 展示名称。
  String get displayName => switch (kind) {
        EngineKind.cpu => 'CPU 引擎包',
        EngineKind.cuda => 'CUDA 引擎包',
        EngineKind.vulkan => 'Vulkan 引擎包',
      };

  /// 是否具备 GPU 加速能力。
  bool get supportsGpu => kind != EngineKind.cpu;

  /// 引擎包所在一级目录名（同类型多个包靠它区分，如 cuda / cuda-2）。
  String get dirName =>
      rootDirPath.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;

  /// 展示用的完整描述：类型 + 目录名。
  String get qualifiedName => '$displayName（$dirName）';

  /// 包根目录是否就是引擎根目录本身。
  ///
  /// 用户把 zip 内容直接平铺到引擎根目录时会这样；此时**不能**用"替换"策略，
  /// 否则会把整个引擎目录连同其它包一起删掉，所以调用方要拒绝这种替换。
  bool isAtEngineRoot(String engineRootPath) =>
      rootDirPath.toLowerCase() == engineRootPath.toLowerCase();
}

/// 导入同类型引擎包时的处理方式。
enum EngineDuplicateAction {
  /// 替换已有的同类型引擎包。
  replace,

  /// 保留两个（新包用带序号的目录名）。
  keepBoth,

  /// 放弃导入。
  cancel,
}

/// 同类型引擎包已存在时的决策回调。
typedef EngineDuplicateHandler = Future<EngineDuplicateAction> Function(
  EngineKind kind,
  EnginePack existing,
);

/// 从本地 zip 导入引擎包的结果。
class EngineImportResult {
  const EngineImportResult({
    required this.success,
    required this.message,
    this.pack,
  });

  final bool success;
  final String message;
  final EnginePack? pack;
}

/// 引擎包管理器。
class EnginePackManager {
  EnginePackManager._();
  static final EnginePackManager instance = EnginePackManager._();

  /// 递归扫描的最大深度（防止在异常目录下深度遍历）。
  static const int _maxScanDepth = 3;

  /// resolvePreferred 的短期缓存：(结果, allowGpu, 缓存时间)。
  (EnginePack?, bool, DateTime)? _preferredCache;

  /// 引擎包根目录。
  ///
  /// Windows 放 `%LOCALAPPDATA%\PolyFlixPlayer\engine`，刻意不用 %TEMP%：
  /// 引擎包动辄 1GB，被系统清理工具删掉后重下代价太高。
  Directory engineRootDir() {
    final override = Platform.environment['POLYFLIX_ENGINE_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      return Directory(override.trim());
    }
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return Directory(
          '$localAppData${Platform.pathSeparator}PolyFlixPlayer'
          '${Platform.pathSeparator}engine',
        );
      }
    }
    // 其它平台 / 取不到 LOCALAPPDATA 时的兜底
    final base = Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$base${sep}PolyFlixPlayer${sep}engine');
  }

  /// 扫描当前已安装的全部引擎包（按目录去重）。
  Future<List<EnginePack>> resolveAll() async {
    final root = engineRootDir();
    if (!root.existsSync()) return const [];

    final packs = <EnginePack>[];
    final seen = <String>{};

    for (final exe in _findExecutables(root, 'whisper-server.exe')) {
      final dir = File(exe).parent;
      final packRoot = _packRootOf(dir.path, root.path);
      final key = packRoot.toLowerCase();
      if (!seen.add(key)) continue;
      packs.add(EnginePack(
        dirPath: dir.path,
        rootDirPath: packRoot,
        serverExePath: exe,
        kind: _detectKind(dir),
      ));
    }
    return packs;
  }

  /// 求某个可执行文件所属的"包根目录"。
  ///
  /// 即从引擎根目录往下数的第一层子目录：
  ///   `engine\Release\whisper-server.exe`              → `engine\Release`
  ///   `engine\cpu\Release\whisper-server.exe`          → `engine\cpu`
  ///   `engine\whisper-server.exe`（内容直接平铺）      → `engine`
  String _packRootOf(String exeDirPath, String engineRootPath) {
    var current = Directory(exeDirPath);
    final root = Directory(engineRootPath);
    while (true) {
      final parent = current.parent;
      if (parent.path.toLowerCase() == root.path.toLowerCase()) {
        return current.path;
      }
      if (parent.path.toLowerCase() == current.path.toLowerCase()) {
        // 已经到了盘符根，说明不在引擎目录树下，按自身处理
        return current.path;
      }
      if (parent.path.toLowerCase() == root.parent.path.toLowerCase()) {
        // 越过了引擎目录（理论上不会发生）
        return current.path;
      }
      current = parent;
    }
  }

  /// 按能力与设置挑选要使用的引擎包。
  ///
  /// [allowGpu] 为 false（用户勾了"强制 CPU"）时，只考虑 CPU 包；
  /// 否则优先级为 CUDA > Vulkan > CPU。找不到任何引擎包时返回 null，
  /// 调用方回落到内置的 CPU 插件。
  Future<EnginePack?> resolvePreferred({bool allowGpu = true}) async {
    // 长视频会按分片反复调用本方法，这里做 5 秒短期缓存避免重复扫盘
    final now = DateTime.now();
    final cached = _preferredCache;
    if (cached != null &&
        cached.$2 == allowGpu &&
        now.difference(cached.$3) < const Duration(seconds: 5)) {
      return cached.$1;
    }

    final packs = await resolveAll();
    final resolved = _pick(packs, allowGpu);
    _preferredCache = (resolved, allowGpu, now);
    return resolved;
  }

  EnginePack? _pick(List<EnginePack> packs, bool allowGpu) {
    if (packs.isEmpty) return null;

    if (allowGpu) {
      for (final kind in [EngineKind.cuda, EngineKind.vulkan]) {
        final hit = packs.where((p) => p.kind == kind).toList();
        if (hit.isNotEmpty) return _newest(hit);
      }
    }
    final cpu = packs.where((p) => p.kind == EngineKind.cpu).toList();
    if (cpu.isNotEmpty) return _newest(cpu);

    // 只装了 GPU 包但用户要求强制 CPU：仍然用这个包（启动时加 -ng 关掉 GPU），
    // 比回落内置插件更快（官方构建的多线程 CPU 路径更优）。
    return _newest(packs);
  }

  /// 同类型存在多个引擎包时，取最近导入的那个（目录修改时间最新）。
  ///
  /// 这样"刚导入的包立刻生效"符合直觉；时间相同则按目录名排序，保证结果确定，
  /// 不会出现"两个同类型包谁生效看系统枚举顺序"的随机行为。
  EnginePack _newest(List<EnginePack> packs) {
    final sorted = [...packs];
    sorted.sort((a, b) {
      final ta = _lastModified(a.dirPath);
      final tb = _lastModified(b.dirPath);
      final cmp = tb.compareTo(ta);
      return cmp != 0 ? cmp : a.dirName.compareTo(b.dirName);
    });
    return sorted.first;
  }

  DateTime _lastModified(String dirPath) {
    try {
      return Directory(dirPath).statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// 从本地 zip 文件导入引擎包。
  ///
  /// 流程：解压到引擎目录下的暂存目录 → 校验里面确实有 `whisper-server.exe`
  /// 并按 `ggml-*.dll` 判断类型 → 校验通过才改成正式目录名，否则删掉暂存目录。
  /// 校验先行的好处是：用户选错压缩包时不会在引擎目录里留下一堆无用文件。
  ///
  /// [onProgress] 回报已写入字节数（解压过程没有进度回调，靠轮询暂存目录大小估算）。
  Future<EngineImportResult> importFromZip(
    String zipPath, {
    void Function(int writtenBytes)? onProgress,
    EngineDuplicateHandler? onDuplicateKind,
  }) async {
    final root = engineRootDir();
    final sep = Platform.pathSeparator;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final staging = Directory('${root.path}$sep.importing-$stamp');

    try {
      final zip = File(zipPath);
      if (!zip.existsSync()) {
        return const EngineImportResult(success: false, message: '文件不存在或无法读取');
      }
      if (!zipPath.toLowerCase().endsWith('.zip')) {
        return const EngineImportResult(
          success: false,
          message: '请选择 zip 压缩包（whisper.cpp 官方发布的就是 zip）',
        );
      }

      root.createSync(recursive: true);

      // 0) 预检：先只读压缩包索引列出内容（秒级完成）。
      //    这样"选错包"能立刻拒绝、同类型冲突也能在解压前问清楚，
      //    不必等 1~2 分钟解压完才发现问题。
      final entries = await _listZipEntries(zipPath);
      EngineDuplicateAction? duplicateAction;
      EnginePack? existingSameKind;

      if (entries != null) {
        if (!entries.any((e) => e.toLowerCase().endsWith('whisper-server.exe'))) {
          return const EngineImportResult(
            success: false,
            message: '压缩包内没有 whisper-server.exe，不像是 whisper.cpp 的 Windows 引擎包',
          );
        }
        final probedKind = _detectKindFromEntries(entries);
        final sameKind = (await resolveAll())
            .where((p) => p.kind == probedKind)
            .toList();
        if (sameKind.isNotEmpty) {
          existingSameKind = _newest(sameKind);
          duplicateAction = onDuplicateKind != null
              ? await onDuplicateKind(probedKind, existingSameKind)
              : EngineDuplicateAction.keepBoth;
          if (duplicateAction == EngineDuplicateAction.cancel) {
            return const EngineImportResult(
              success: false,
              message: '已取消导入：引擎目录中已有同类型的引擎包',
            );
          }
        }
      }

      staging.createSync(recursive: true);
      final extractError = await _extractZip(zipPath, staging.path, onProgress);
      if (extractError != null) {
        _deleteQuietly(staging);
        return EngineImportResult(success: false, message: '解压失败：$extractError');
      }

      // 1) 再校验一次（预检列不出内容时的兜底）：解压结果里必须有 whisper-server.exe
      final exeList = _findExecutables(staging, 'whisper-server.exe');
      if (exeList.isEmpty) {
        _deleteQuietly(staging);
        return const EngineImportResult(
          success: false,
          message: '压缩包内没有 whisper-server.exe，不像是 whisper.cpp 的 Windows 引擎包',
        );
      }

      final kind = _detectKind(File(exeList.first).parent);

      // 2) 决定落地目录：替换则复用旧包的根目录（先整体删掉旧包），
      //    否则按类型分配新目录。注意删的是"包根目录"而不是 exe 所在目录，
      //    否则解压出来的 Release\ 会被再套一层。
      Directory targetDir;
      if (duplicateAction == EngineDuplicateAction.replace &&
          existingSameKind != null) {
        if (existingSameKind.isAtEngineRoot(root.path)) {
          _deleteQuietly(staging);
          return const EngineImportResult(
            success: false,
            message: '该引擎包直接平铺在引擎目录根下，自动替换有风险，'
                '请先在引擎目录里手动清理后再导入',
          );
        }
        final existingDir = Directory(existingSameKind.rootDirPath);
        try {
          if (existingDir.existsSync()) existingDir.deleteSync(recursive: true);
        } catch (e) {
          _deleteQuietly(staging);
          return EngineImportResult(
            success: false,
            message: '替换失败：旧引擎包正在被占用（可能正在识别），'
                '请等识别结束后重试。\n$e',
          );
        }
        targetDir = existingDir;
      } else {
        targetDir = _allocateTargetDir(root, kind);
      }

      try {
        staging.renameSync(targetDir.path);
      } catch (_) {
        // 跨盘等异常：退化为复制
        _copyDirectorySync(staging, targetDir);
        _deleteQuietly(staging);
      }

      _preferredCache = null;

      // 用实际扫描结果返回，保证返回的路径与后续识别时用到的完全一致
      final resolved = await resolveAll();
      final matched = resolved.where(
        (p) => p.rootDirPath.toLowerCase() == targetDir.path.toLowerCase(),
      );
      final kindLabel = switch (kind) {
        EngineKind.cuda => 'CUDA',
        EngineKind.vulkan => 'Vulkan',
        EngineKind.cpu => 'CPU',
      };
      return EngineImportResult(
        success: true,
        message: '已导入 $kindLabel 引擎包',
        pack: matched.isNotEmpty ? matched.first : null,
      );
    } catch (e) {
      _deleteQuietly(staging);
      return EngineImportResult(success: false, message: '导入失败：$e');
    }
  }

  /// 只读列出 zip 内的条目路径（不解压）。
  ///
  /// 优先用 Windows 自带的 `tar -tf`；不可用时退回 PowerShell + .NET 的
  /// `ZipFile.OpenRead`。两者都失败返回 null，调用方退化为"解压后再校验"。
  Future<List<String>?> _listZipEntries(String zipPath) async {
    try {
      final tar = await Process.run(
        'tar',
        ['-tf', zipPath],
        runInShell: false,
      );
      if (tar.exitCode == 0) {
        final lines = (tar.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        if (lines.isNotEmpty) return lines;
      }
    } catch (_) {
      // tar 不存在或执行失败，继续尝试 PowerShell
    }

    try {
      final escaped = zipPath.replaceAll("'", "''");
      final ps = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          "Add-Type -AssemblyName System.IO.Compression.FileSystem; "
              "[IO.Compression.ZipFile]::OpenRead('$escaped').Entries | "
              'ForEach-Object { \$_.FullName }',
        ],
        runInShell: false,
      );
      if (ps.exitCode == 0) {
        final lines = (ps.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        if (lines.isNotEmpty) return lines;
      }
    } catch (_) {}
    return null;
  }

  /// 按 zip 条目名判断引擎类型（用于解压前预检）。
  EngineKind _detectKindFromEntries(List<String> entries) {
    var hasVulkan = false;
    for (final entry in entries) {
      final name = entry.toLowerCase();
      if (!name.contains('ggml-')) continue;
      if (name.contains('cuda')) return EngineKind.cuda;
      if (name.contains('vulkan')) hasVulkan = true;
    }
    return hasVulkan ? EngineKind.vulkan : EngineKind.cpu;
  }

  /// 规划落地目录：同类型已存在时追加序号，避免覆盖已有引擎包。
  Directory _allocateTargetDir(Directory root, EngineKind kind) {
    final sep = Platform.pathSeparator;
    final base = switch (kind) {
      EngineKind.cuda => 'cuda',
      EngineKind.vulkan => 'vulkan',
      EngineKind.cpu => 'cpu',
    };
    var candidate = Directory('${root.path}$sep$base');
    var index = 2;
    while (candidate.existsSync()) {
      candidate = Directory('${root.path}$sep$base-$index');
      index++;
    }
    return candidate;
  }

  /// 解压 zip：优先 Windows 自带的 tar（bsdtar 支持 zip，速度快），
  /// 失败时回退 PowerShell 的 Expand-Archive。返回错误信息，成功返回 null。
  Future<String?> _extractZip(
    String zipPath,
    String destDir,
    void Function(int writtenBytes)? onProgress,
  ) async {
    Future<Process> launch() async {
      try {
        return await Process.start(
          'tar',
          ['-xf', zipPath, '-C', destDir],
          runInShell: false,
        );
      } catch (_) {
        final escapedZip = zipPath.replaceAll("'", "''");
        final escapedDest = destDir.replaceAll("'", "''");
        return Process.start(
          'powershell',
          [
            '-NoProfile',
            '-Command',
            "Expand-Archive -LiteralPath '$escapedZip' "
                "-DestinationPath '$escapedDest' -Force",
          ],
          runInShell: false,
        );
      }
    }

    final process = await launch();
    // tar 没有进度回调，这里轮询暂存目录大小用于界面提示
    final stagingDir = Directory(destDir);
    Timer? poller;
    if (onProgress != null) {
      poller = Timer.periodic(const Duration(milliseconds: 700), (_) {
        onProgress(_directorySizeSync(stagingDir));
      });
    }

    final stderrLines = <String>[];
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((chunk) => stderrLines.add(chunk));
    process.stdout.listen((_) {});

    final exitCode = await process.exitCode;
    poller?.cancel();
    if (onProgress != null) onProgress(_directorySizeSync(stagingDir));

    if (exitCode != 0) {
      return stderrLines.isEmpty
          ? '解压进程返回码 $exitCode'
          : stderrLines.join(' ').trim();
    }
    return null;
  }

  int _directorySizeSync(Directory dir) {
    var total = 0;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += entity.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  void _copyDirectorySync(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final entity in from.listSync(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(from.path.length + 1);
      final target = '${to.path}${Platform.pathSeparator}$relative';
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        Directory(File(target).parent.path).createSync(recursive: true);
        entity.copySync(target);
      }
    }
  }

  void _deleteQuietly(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// 递归查找指定可执行文件（限制深度，优先浅层）。
  List<String> _findExecutables(Directory root, String fileName) {
    final result = <String>[];
    final queue = <(Directory, int)>[(root, 0)];
    while (queue.isNotEmpty) {
      final (dir, depth) = queue.removeAt(0);
      final direct = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (direct.existsSync()) result.add(direct.path);
      if (depth >= _maxScanDepth) continue;
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is Directory) queue.add((entity, depth + 1));
        }
      } catch (_) {
        // 无权限等异常直接跳过
      }
    }
    return result;
  }

  /// 依据同目录下的 ggml 后端 DLL 判断引擎类型。
  EngineKind _detectKind(Directory dir) {
    var hasVulkan = false;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.toLowerCase();
        if (!name.contains('ggml-')) continue;
        if (name.contains('cuda')) return EngineKind.cuda;
        if (name.contains('vulkan')) hasVulkan = true;
      }
    } catch (_) {
      // 读取失败按 CPU 处理
    }
    return hasVulkan ? EngineKind.vulkan : EngineKind.cpu;
  }
}
