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
