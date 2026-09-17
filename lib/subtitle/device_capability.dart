/// 设备能力检测与 AI 字幕功能的硬件门槛判断。
///
/// ASR 模式需要在本地运行 Whisper 模型推理，对设备硬件有最低要求。
/// 不满足时直接提示"不支持当前设备"，不做降级。
///
/// 注意：第二阶段的"翻译已有字幕"模式不受硬件限制，因为它不需要
/// 本地模型推理。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// ASR 模式的最低硬件要求。
const int kMinRamMB = 4096; // 至少 4GB 系统内存
const int kMinCpuCores = 4; // 至少 4 核 CPU

/// 设备能力信息。
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.cpuCores,
    required this.systemRamMB,
    required this.meetsMinimumRequirements,
    this.unsupportedReason,
  });

  final int cpuCores;
  final int systemRamMB;
  final bool meetsMinimumRequirements;

  /// 如果不满足要求，描述具体原因。
  final String? unsupportedReason;
}

/// GPU 加速能力信息。
class GpuCapability {
  const GpuCapability({
    required this.available,
    required this.engineLabel,
    this.adapters = const [],
  });

  /// 当前是否可以用 GPU 做推理加速。
  final bool available;

  /// 识别引擎的展示文案（如"CPU"）。
  final String engineLabel;

  /// 检测到的显卡名称（已过滤掉虚拟显示适配器）。
  final List<String> adapters;

  bool get hasAdapters => adapters.isNotEmpty;
}

/// 虚拟显示适配器关键字。
///
/// 这类适配器不是真实显卡：安卓模拟器（MuMu / 雷电 / BlueStacks）、
/// 串流与远程控制软件（GameViewer / Parsec / ToDesk / Sunlogin 等）、
/// Windows 间接显示驱动（Idd）都会注册一个虚拟显卡。
/// 它们不能用于推理，显示出来只会让用户困惑。
const List<String> _kVirtualAdapterKeywords = [
  'virtual',
  'idd',
  'mumu',
  'gameviewer',
  'oryx', // MuMu 的显示适配器别名
  'parsec',
  'todesk',
  'sunlogin',
  'oray',
  'splashtop',
  'duet',
  'spacedesk',
];

bool _isVirtualAdapter(String name) {
  final lower = name.toLowerCase();
  return _kVirtualAdapterKeywords.any(lower.contains);
}

/// 检测 GPU 加速能力。
///
/// 重要：当前使用的上游插件 whisper_ggml 2.6.0 是**纯 CPU 构建** ——
/// 原生 main.cpp 里硬编码了 `cparams.use_gpu = false`，且 Windows/Android 的
/// CMake 都只编译 `GGML_USE_CPU` 后端（没有 CUDA / Vulkan / OpenCL）。
/// 所以无论本机显卡多好，这里都必须返回 [GpuCapability.available] = false，
/// 绝不能在设置里给出一个点了也没用的"GPU 开关"。
///
/// 后续接入 GPU 的真实步骤见 README「识别性能与硬件」一节：需要 vendor 本插件、
/// 打开 Vulkan/CUDA 后端并让原生层读取 use_gpu 参数，届时本函数改为实际探测
/// （尝试初始化 GPU 后端 + 失败回落），设置页再据此启用开关。
Future<GpuCapability> detectGpuCapability() async {
  final raw = <String>[];

  if (Platform.isWindows) {
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Get-CimInstance Win32_VideoController | '
              'ForEach-Object { \$_.Name }',
        ],
        runInShell: true,
      );
      raw.addAll(
        result.stdout
            .toString()
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty),
      );
    } catch (_) {
      // 检测失败不影响 CPU 识别，忽略
    }
  } else if (Platform.isAndroid) {
    try {
      final result = await Process.run('getprop', ['ro.hardware.egl']);
      final out = result.stdout.toString().trim();
      if (out.isNotEmpty) raw.add(out);
    } catch (_) {
      // 忽略
    }
  }

  // 过滤虚拟显示适配器（模拟器 / 串流 / 间接显示驱动），它们不能用于推理
  final real = raw.where((name) => !_isVirtualAdapter(name)).toList();

  return GpuCapability(
    available: false,
    engineLabel: 'CPU',
    // 万一全被过滤掉了（例如整机只有虚拟适配器），宁可把原始结果展示出来
    adapters: real.isNotEmpty ? real : raw,
  );
}

/// 检测当前设备是否满足运行 ASR 模型的最低要求。
Future<DeviceCapabilities> detectDeviceCapabilities() async {
  int cpuCores = Platform.numberOfProcessors;
  int systemRamMB = 0;

  if (Platform.isAndroid) {
    try {
      const channel = MethodChannel('com.polyflix.player/storage_permission');
      final result = await channel.invokeMapMethod<String, dynamic>(
        'getDeviceCapabilities',
      );
      if (result != null) {
        cpuCores = (result['cpuCores'] as int?) ?? cpuCores;
        systemRamMB = (result['systemRamMB'] as int?) ?? 0;
      }
    } catch (_) {
      // 检测失败时假设满足要求，避免误拒
      return const DeviceCapabilities(
        cpuCores: 8,
        systemRamMB: 8192,
        meetsMinimumRequirements: true,
      );
    }
  } else {
    // Windows / Desktop：Dart 的 Platform.numberOfProcessors 已能拿到核数。
    // 系统内存通过 wmic 获取（最简方式）。
    try {
      final result = await Process.run(
        'wmic',
        ['ComputerSystem', 'get', 'TotalPhysicalMemory', '/Value'],
      );
      final output = result.stdout.toString();
      final match = RegExp(r'TotalPhysicalMemory=(\d+)').firstMatch(output);
      if (match != null) {
        systemRamMB = int.parse(match.group(1)!) ~/ (1024 * 1024);
      }
    } catch (_) {
      // 获取失败时假设满足要求
      systemRamMB = 16384;
    }
  }

  final reasons = <String>[];
  if (systemRamMB > 0 && systemRamMB < kMinRamMB) {
    reasons.add('内存不足（当前 ${systemRamMB}MB，需要 ${kMinRamMB}MB）');
  }
  if (cpuCores < kMinCpuCores) {
    reasons.add('CPU 核数不够（当前 $cpuCores 核，需要 $kMinCpuCores 核）');
  }

  return DeviceCapabilities(
    cpuCores: cpuCores,
    systemRamMB: systemRamMB,
    meetsMinimumRequirements: reasons.isEmpty,
    unsupportedReason: reasons.isEmpty ? null : reasons.join('；'),
  );
}
