/// 音频播放舞台视图：展示内嵌封面、动态音频频谱（无字幕时）以及滚动歌词/双语字幕。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lyric/flutter_lyric.dart' hide LrcParser;

import '../subtitle/subtitle_generator.dart';
import '../utils/native_file_helper.dart';

/// 音频按时间帧提取的多频段能量时间轴（每帧 50ms，包含低/中/高频能量）。
class AudioSpectrumTimeline {
  const AudioSpectrumTimeline({
    required this.frameDurationMs,
    required this.lowBands,
    required this.midBands,
    required this.highBands,
  });

  final int frameDurationMs;
  final Float32List lowBands;
  final Float32List midBands;
  final Float32List highBands;

  int get frameCount => lowBands.length;

  /// 读取指定毫秒位置对应的归一化三频段能量 `[low, mid, high]`（值域 `0.0 ~ 1.0`）。
  (double low, double mid, double high) sampleAt(double positionMs) {
    if (frameCount == 0) return (0.0, 0.0, 0.0);
    final exactIdx = (positionMs / frameDurationMs).clamp(
      0.0,
      (frameCount - 1).toDouble(),
    );
    final i0 = exactIdx.floor();
    final i1 = min(i0 + 1, frameCount - 1);
    final t = exactIdx - i0;

    final low = lowBands[i0] + (lowBands[i1] - lowBands[i0]) * t;
    final mid = midBands[i0] + (midBands[i1] - midBands[i0]) * t;
    final high = highBands[i0] + (highBands[i1] - highBands[i0]) * t;
    return (low, mid, high);
  }
}

/// 音频内嵌封面与动态频谱特征数据加载器（结果带内存/磁盘缓存）。
abstract final class AudioStageLoader {
  static final Set<String> _noCoverCache = <String>{};
  static final Map<String, AudioSpectrumTimeline> _spectrumCache =
      <String, AudioSpectrumTimeline>{};

  static const int _kFrameMs = 50;

  static String _pathHash(String sourcePath) =>
      md5.convert(utf8.encode(sourcePath)).toString().substring(0, 12);

  static bool _isMissingLocalFile(String path) {
    final lower = path.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('rtsp://')) {
      return false;
    }
    return !File(path).existsSync();
  }

  /// 提取音频内嵌封面至缓存目录（无封面返回 null）。
  static Future<File?> extractCover(String sourcePath) async {
    if (_noCoverCache.contains(sourcePath)) return null;
    if (_isMissingLocalFile(sourcePath)) return null;
    try {
      final audioDir = NativeFileHelper.desktopCacheAudioDir();
      if (!audioDir.existsSync()) audioDir.createSync(recursive: true);

      final hash = _pathHash(sourcePath);
      final coverPath =
          '${audioDir.path}${Platform.pathSeparator}cover_$hash.jpg';
      final coverFile = File(coverPath);
      if (await coverFile.exists() && await coverFile.length() > 0) {
        return coverFile;
      }

      final completer = Completer<bool>();
      await FFmpegKit.executeWithArgumentsAsync(
        [
          '-y',
          '-i',
          sourcePath,
          '-an',
          '-vcodec',
          'mjpeg',
          '-vframes',
          '1',
          coverPath,
        ],
        (session) async {
          final rc = await session.getReturnCode();
          if (!completer.isCompleted) {
            completer.complete(ReturnCode.isSuccess(rc));
          }
        },
      );

      final ok = await completer.future;
      if (ok && await coverFile.exists() && await coverFile.length() > 0) {
        return coverFile;
      }
      if (await coverFile.exists()) {
        try {
          await coverFile.delete();
        } catch (_) {}
      }
    } catch (_) {}

    _noCoverCache.add(sourcePath);
    return null;
  }

  /// 提取随时间变化的低/中/高频能量序列，驱动实时动态频谱。
  static Future<AudioSpectrumTimeline?> extractSpectrum(
    String sourcePath,
  ) async {
    final cached = _spectrumCache[sourcePath];
    if (cached != null) return cached;
    if (_isMissingLocalFile(sourcePath)) return null;

    try {
      final audioDir = NativeFileHelper.desktopCacheAudioDir();
      if (!audioDir.existsSync()) audioDir.createSync(recursive: true);

      final hash = _pathHash(sourcePath);

      // 若之前 ASR 已提取过 16kHz WAV，直接复用免二次解码
      final asrWav = File(
        '${audioDir.path}${Platform.pathSeparator}pflx_asr_$hash.wav',
      );
      if (await asrWav.exists() && await asrWav.length() > 44) {
        final wavBytes = await asrWav.readAsBytes();
        final pcm = Uint8List.sublistView(wavBytes, 44);
        final timeline = analyzePcmFrames(pcm, sampleRate: 16000);
        if (timeline != null) {
          _spectrumCache[sourcePath] = timeline;
          return timeline;
        }
      }

      // 降采样提取 4000Hz 单声道 s16le PCM（奈奎斯特 2000Hz 覆盖主要音乐/人声能量且极快）
      final pcmPath =
          '${audioDir.path}${Platform.pathSeparator}spec_$hash.pcm';
      final pcmFile = File(pcmPath);

      final completer = Completer<bool>();
      await FFmpegKit.executeWithArgumentsAsync(
        [
          '-y',
          '-i',
          sourcePath,
          '-map',
          '0:a:0?',
          '-vn',
          '-sn',
          '-dn',
          '-f',
          's16le',
          '-acodec',
          'pcm_s16le',
          '-ar',
          '4000',
          '-ac',
          '1',
          pcmPath,
        ],
        (session) async {
          final rc = await session.getReturnCode();
          if (!completer.isCompleted) {
            completer.complete(ReturnCode.isSuccess(rc));
          }
        },
      );

      final ok = await completer.future;
      if (ok && await pcmFile.exists() && await pcmFile.length() > 2) {
        final pcmBytes = await pcmFile.readAsBytes();
        final timeline = analyzePcmFrames(pcmBytes, sampleRate: 4000);
        try {
          await pcmFile.delete();
        } catch (_) {}
        if (timeline != null) {
          _spectrumCache[sourcePath] = timeline;
          return timeline;
        }
      } else if (await pcmFile.exists()) {
        try {
          await pcmFile.delete();
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  /// 按 50ms 窗口计算每帧的低/中/高频能量并做动态范围归一化。
  static AudioSpectrumTimeline? analyzePcmFrames(
    Uint8List pcmBytes, {
    required int sampleRate,
  }) {
    final totalSamples = pcmBytes.length ~/ 2;
    final frameSamples = max(1, (sampleRate * _kFrameMs) ~/ 1000);
    final frameCount = totalSamples ~/ frameSamples;
    if (frameCount <= 0) return null;

    final data = ByteData.sublistView(pcmBytes);
    final rawLow = Float32List(frameCount);
    final rawMid = Float32List(frameCount);
    final rawHigh = Float32List(frameCount);

    var maxLow = 1e-6;
    var maxMid = 1e-6;
    var maxHigh = 1e-6;

    // 简单一阶低通与带通分离，避免引入重型 FFT 依赖
    double lpState = 0.0;
    double prevLp = 0.0;
    double prevSample = 0.0;
    final lpAlpha = sampleRate >= 16000 ? 0.08 : 0.22;

    for (var f = 0; f < frameCount; f++) {
      final base = f * frameSamples;
      var sumLow = 0.0;
      var sumMid = 0.0;
      var sumHigh = 0.0;

      for (var i = 0; i < frameSamples; i++) {
        final s = data.getInt16((base + i) * 2, Endian.little) / 32768.0;
        lpState += lpAlpha * (s - lpState);
        final hp = s - prevSample;
        final bp = s - lpState - (hp * 0.5);

        sumLow += lpState * lpState;
        sumMid += bp * bp;
        sumHigh += (s - prevLp) * (s - prevLp) * 0.65 + hp * hp * 0.35;

        prevLp = lpState;
        prevSample = s;
      }

      final l = sqrt(sumLow / frameSamples);
      final m = sqrt(sumMid / frameSamples);
      final h = sqrt(sumHigh / frameSamples);
      rawLow[f] = l;
      rawMid[f] = m;
      rawHigh[f] = h;

      if (l > maxLow) maxLow = l;
      if (m > maxMid) maxMid = m;
      if (h > maxHigh) maxHigh = h;
    }

    final normLow = Float32List(frameCount);
    final normMid = Float32List(frameCount);
    final normHigh = Float32List(frameCount);

    for (var f = 0; f < frameCount; f++) {
      normLow[f] = pow((rawLow[f] / maxLow).clamp(0.0, 1.0), 0.72).toDouble();
      normMid[f] = pow((rawMid[f] / maxMid).clamp(0.0, 1.0), 0.72).toDouble();
      normHigh[f] = pow((rawHigh[f] / maxHigh).clamp(0.0, 1.0), 0.72).toDouble();
    }

    return AudioSpectrumTimeline(
      frameDurationMs: _kFrameMs,
      lowBands: normLow,
      midBands: normMid,
      highBands: normHigh,
    );
  }
}

/// 动态频谱展示组件：60fps 平滑渲染带峰值指示小块的实时频谱柱（纯展示不拦截进度点击）。
class AudioSpectrumView extends StatefulWidget {
  const AudioSpectrumView({
    super.key,
    required this.width,
    required this.height,
    required this.barCount,
    required this.playing,
    required this.position,
    required this.primaryColor,
    required this.secondaryColor,
    this.timeline,
  });

  final double width;
  final double height;
  final int barCount;
  final bool playing;
  final Duration position;
  final Color primaryColor;
  final Color secondaryColor;
  final AudioSpectrumTimeline? timeline;

  @override
  State<AudioSpectrumView> createState() => _AudioSpectrumViewState();
}

class _AudioSpectrumViewState extends State<AudioSpectrumView>
    with SingleTickerProviderStateMixin {
  static const double _kIdleLevel = 0.06;

  late final Ticker _ticker;
  final ValueNotifier<int> _repaintSignal = ValueNotifier<int>(0);
  late List<double> _bars;
  late List<double> _peaks;
  late List<double> _peakVelocities;

  Duration _lastTickElapsed = Duration.zero;
  double _smoothPositionMs = 0.0;
  double _animClockSec = 0.0;

  @override
  void initState() {
    super.initState();
    _initArrays(widget.barCount);
    _smoothPositionMs = widget.position.inMilliseconds.toDouble();
    _ticker = createTicker(_onTick);
    if (widget.playing) {
      _ticker.start();
    }
  }

  void _initArrays(int count) {
    _bars = List<double>.filled(count, _kIdleLevel);
    _peaks = List<double>.filled(count, _kIdleLevel);
    _peakVelocities = List<double>.filled(count, 0.0);
  }

  @override
  void didUpdateWidget(covariant AudioSpectrumView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.barCount != widget.barCount) {
      _initArrays(widget.barCount);
    }
    final incomingMs = widget.position.inMilliseconds.toDouble();
    if ((incomingMs - _smoothPositionMs).abs() > 350) {
      _smoothPositionMs = incomingMs;
    }
    if (widget.playing && !_ticker.isActive) {
      _lastTickElapsed = Duration.zero;
      _ticker.start();
    } else if (!widget.playing && oldWidget.playing && !_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaintSignal.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dtSec = _lastTickElapsed == Duration.zero
        ? (1.0 / 60.0)
        : ((elapsed - _lastTickElapsed).inMicroseconds / 1e6).clamp(
            0.001,
            0.05,
          );
    _lastTickElapsed = elapsed;
    _animClockSec += dtSec;

    if (widget.playing) {
      _smoothPositionMs += dtSec * 1000.0;
      final realMs = widget.position.inMilliseconds.toDouble();
      // 轻度向播放器真实进度收敛，既保留 60fps 顺滑度又不脱拍
      _smoothPositionMs += (realMs - _smoothPositionMs) * 0.18;
    }

    final count = _bars.length;
    final timeline = widget.timeline;
    final bands = widget.playing && timeline != null
        ? timeline.sampleAt(_smoothPositionMs)
        : null;

    var allAtIdle = !widget.playing;

    for (var i = 0; i < count; i++) {
      final double target;
      if (!widget.playing) {
        target = _kIdleLevel;
      } else {
        final normX = count <= 1 ? 0.5 : i / (count - 1);
        if (bands != null) {
          final (low, mid, high) = bands;
          // 从低频到高频平滑分布并叠加以各频段为基准的谐波律动，营造自然频谱柱群感
          final double baseEnergy;
          if (normX < 0.4) {
            final t = normX / 0.4;
            baseEnergy = low * (1 - t) + mid * t;
          } else {
            final t = (normX - 0.4) / 0.6;
            baseEnergy = mid * (1 - t) + high * t;
          }
          final ripple =
              0.78 +
              0.22 *
                  sin(_animClockSec * (5.5 + normX * 4.2) + i * 0.85) *
                  cos(_animClockSec * 2.7 + i * 0.4);
          target = (_kIdleLevel + baseEnergy * ripple * 0.92).clamp(
            _kIdleLevel,
            1.0,
          );
        } else {
          // PCM 特征提取尚未完成时的平滑谐波律动过渡
          final w1 = sin(_animClockSec * 4.2 + i * 0.45).abs();
          final w2 = cos(_animClockSec * 2.9 - i * 0.28).abs();
          final envelope = 1.0 - (normX - 0.38).abs() * 0.45;
          target = (_kIdleLevel + (w1 * 0.48 + w2 * 0.36) * envelope * 0.72)
              .clamp(_kIdleLevel, 0.92);
        }
      }

      // 攻击快、回落顺滑
      final current = _bars[i];
      final lerpFactor = target > current
          ? (1.0 - exp(-dtSec * 24.0))
          : (1.0 - exp(-dtSec * 9.5));
      var nextBar = current + (target - current) * lerpFactor;
      if (!widget.playing && (nextBar - _kIdleLevel).abs() < 0.002) {
        nextBar = _kIdleLevel;
      } else if (!widget.playing) {
        allAtIdle = false;
      }
      _bars[i] = nextBar;

      // 峰值块：立刻随柱体抬升，受重力加速下落
      if (nextBar >= _peaks[i]) {
        _peaks[i] = nextBar;
        _peakVelocities[i] = 0.0;
      } else {
        _peakVelocities[i] += dtSec * 1.45;
        var nextPeak = _peaks[i] - _peakVelocities[i] * dtSec;
        if (nextPeak <= nextBar) {
          nextPeak = nextBar;
          _peakVelocities[i] = 0.0;
        }
        if (!widget.playing && (nextPeak - _kIdleLevel).abs() < 0.002) {
          nextPeak = _kIdleLevel;
        } else if (!widget.playing) {
          allAtIdle = false;
        }
        _peaks[i] = nextPeak;
      }
    }

    _repaintSignal.value++;

    if (allAtIdle) {
      _ticker.stop();
      _lastTickElapsed = Duration.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(
        painter: _SpectrumPainter(
          bars: _bars,
          peaks: _peaks,
          primaryColor: widget.primaryColor,
          secondaryColor: widget.secondaryColor,
          repaint: _repaintSignal,
        ),
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.bars,
    required this.peaks,
    required this.primaryColor,
    required this.secondaryColor,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<double> bars;
  final List<double> peaks;
  final Color primaryColor;
  final Color secondaryColor;

  @override
  void paint(Canvas canvas, Size size) {
    final count = bars.length;
    if (count == 0 || size.width <= 0 || size.height <= 0) return;

    final slotWidth = size.width / count;
    final barWidth = (slotWidth * 0.56).clamp(3.0, 12.0);
    final radius = Radius.circular(barWidth * 0.5);
    final capHeight = (barWidth * 0.42).clamp(2.5, 4.0);
    final maxBarAreaHeight = max(8.0, size.height - capHeight - 4.0);

    final barPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [secondaryColor, primaryColor],
      ).createShader(Offset.zero & size);

    final capPaint = Paint()
      ..color = Colors.white.withValues(alpha: .72);

    for (var i = 0; i < count; i++) {
      final centerX = slotWidth * (i + 0.5);
      final left = centerX - barWidth * 0.5;
      final level = bars[i].clamp(0.03, 1.0);
      final barHeight = max(3.0, maxBarAreaHeight * level);
      final top = size.height - barHeight;

      final barRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        radius,
      );
      canvas.drawRRect(barRect, barPaint);

      final peakLevel = peaks[i].clamp(level, 1.0);
      final peakY = (size.height - maxBarAreaHeight * peakLevel - capHeight - 2.0)
          .clamp(0.0, size.height - capHeight);
      final capRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, peakY, barWidth, capHeight),
        Radius.circular(capHeight * 0.5),
      );
      canvas.drawRRect(capRect, capPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) {
    return oldDelegate.primaryColor != primaryColor ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.bars.length != bars.length;
  }
}

/// 音频舞台组件：在纯深色背景上按是否有激活字幕自动切换动态频谱视图与滚动歌词视图。
class AudioStageView extends StatefulWidget {
  const AudioStageView({
    super.key,
    required this.sourcePath,
    required this.title,
    required this.position,
    required this.duration,
    required this.playing,
    required this.onSeek,
    this.primaryEntries,
    this.secondaryEntries,
    this.forceWaveform = false,
  });

  final String sourcePath;
  final String title;
  final Duration position;
  final Duration duration;
  final bool playing;
  final ValueChanged<Duration> onSeek;
  final List<SubtitleEntry>? primaryEntries;
  final List<SubtitleEntry>? secondaryEntries;
  final bool forceWaveform;

  @override
  State<AudioStageView> createState() => _AudioStageViewState();
}

class _AudioStageViewState extends State<AudioStageView> {
  late final LyricController _lyricController;
  File? _coverFile;
  AudioSpectrumTimeline? _spectrumTimeline;
  List<SubtitleEntry>? _lastPrimary;
  List<SubtitleEntry>? _lastSecondary;

  bool get _hasLyrics =>
      widget.primaryEntries != null && widget.primaryEntries!.isNotEmpty;

  bool get _showLyrics => _hasLyrics && !widget.forceWaveform;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController(initialPosition: widget.position);
    _syncLyricDocument(force: true);
    _loadMediaAssets();
  }

  @override
  void didUpdateWidget(covariant AudioStageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourcePath != widget.sourcePath) {
      _coverFile = null;
      _spectrumTimeline = null;
      _loadMediaAssets();
    }
    if (!_entriesEquivalent(_lastPrimary, widget.primaryEntries) ||
        !_entriesEquivalent(_lastSecondary, widget.secondaryEntries)) {
      _syncLyricDocument(force: true);
    }
    if (oldWidget.position != widget.position) {
      _lyricController.setPosition(widget.position);
    }
  }

  @override
  void dispose() {
    _lyricController.dispose();
    super.dispose();
  }

  Future<void> _loadMediaAssets() async {
    final targetPath = widget.sourcePath;

    final coverFuture = AudioStageLoader.extractCover(targetPath);
    final spectrumFuture = AudioStageLoader.extractSpectrum(targetPath);

    final cover = await coverFuture;
    if (mounted && widget.sourcePath == targetPath) {
      setState(() => _coverFile = cover);
    }

    final timeline = await spectrumFuture;
    if (mounted && widget.sourcePath == targetPath) {
      setState(() => _spectrumTimeline = timeline);
    }
  }

  void _syncLyricDocument({bool force = false}) {
    final primary = widget.primaryEntries;
    final secondary = widget.secondaryEntries;
    if (!force &&
        _entriesEquivalent(_lastPrimary, primary) &&
        _entriesEquivalent(_lastSecondary, secondary)) {
      return;
    }
    _lastPrimary = primary;
    _lastSecondary = secondary;

    if (primary == null || primary.isEmpty) {
      _lyricController.clear();
      return;
    }

    final hasSecondary = secondary != null && secondary.isNotEmpty;
    final lines = <LyricLine>[];

    for (final entry in primary) {
      final text = _cleanLyricText(entry.text);
      if (text.isEmpty) continue;

      String? translation;
      if (hasSecondary) {
        final matched = _findMatchingEntry(entry, secondary);
        if (matched != null) {
          final cleaned = _cleanLyricText(matched.text);
          if (cleaned.isNotEmpty && cleaned != text) {
            translation = cleaned;
          }
        }
      } else if (entry.translatedText != null &&
          entry.translatedText!.trim().isNotEmpty) {
        final cleaned = _cleanLyricText(entry.translatedText!);
        if (cleaned.isNotEmpty && cleaned != text) {
          translation = cleaned;
        }
      }

      lines.add(LyricLine(
        start: entry.start,
        end: entry.end > entry.start ? entry.end : null,
        text: text,
        translation: translation,
      ));
    }

    if (lines.isEmpty) {
      _lyricController.clear();
      return;
    }

    _lyricController.loadDocument(LyricDocument(lines: lines));
    _lyricController.setPosition(widget.position);
  }

  static String _cleanLyricText(String raw) {
    return raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(' ')
        .trim();
  }

  static SubtitleEntry? _findMatchingEntry(
    SubtitleEntry target,
    List<SubtitleEntry> candidates,
  ) {
    SubtitleEntry? bestOverlap;
    var maxOverlapMs = 0;
    for (final c in candidates) {
      final overlapStart = target.start > c.start ? target.start : c.start;
      final overlapEnd = target.end < c.end ? target.end : c.end;
      final overlapMs = (overlapEnd - overlapStart).inMilliseconds;
      if (overlapMs > maxOverlapMs) {
        maxOverlapMs = overlapMs;
        bestOverlap = c;
      }
    }
    if (bestOverlap != null) return bestOverlap;

    SubtitleEntry? nearest;
    var minDiffMs = 801;
    for (final c in candidates) {
      final diffMs = (target.start - c.start).inMilliseconds.abs();
      if (diffMs < minDiffMs) {
        minDiffMs = diffMs;
        nearest = c;
      }
    }
    return nearest;
  }

  static bool _entriesEquivalent(
    List<SubtitleEntry>? a,
    List<SubtitleEntry>? b,
  ) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    if (a.isEmpty) return true;
    bool sameItem(SubtitleEntry x, SubtitleEntry y) =>
        x.start == y.start &&
        x.end == y.end &&
        x.text == y.text &&
        x.translatedText == y.translatedText;
    if (a.length <= 1000) {
      for (var i = 0; i < a.length; i++) {
        if (!sameItem(a[i], b[i])) return false;
      }
      return true;
    }
    final mid = a.length >> 1;
    return sameItem(a.first, b.first) &&
        sameItem(a[mid], b[mid]) &&
        sameItem(a.last, b.last);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF121218),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 64, 20, 108),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (_showLyrics) {
                return _buildLyricsStage(context, constraints);
              }
              return _buildSpectrumStage(context, constraints);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSpectrumStage(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isWide = constraints.maxWidth >= 600;
    final coverSize = isWide ? 184.0 : 144.0;
    final spectrumWidth = min(constraints.maxWidth - 24, 640.0).clamp(180.0, 640.0);
    final barCount = isWide ? 36 : 26;
    final primaryAccent = Color.lerp(scheme.primary, Colors.white, 0.25)!;
    final secondaryAccent = scheme.primary.withValues(alpha: .72);

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AudioCoverCard(coverFile: _coverFile, size: coverSize),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: spectrumWidth),
              child: Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: isWide ? 19 : 16,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 28),
            AudioSpectrumView(
              width: spectrumWidth,
              height: isWide ? 116 : 96,
              barCount: barCount,
              playing: widget.playing,
              position: widget.position,
              timeline: _spectrumTimeline,
              primaryColor: primaryAccent,
              secondaryColor: secondaryAccent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLyricsStage(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isWide = constraints.maxWidth >= 720;
    final preset = _buildLyricPreset(scheme, isWide: isWide);

    final lyricWidget = LyricView(
      controller: _lyricController,
      preset: preset,
      onLineTap: (details) {
        widget.onSeek(details.seekPosition);
      },
    );

    if (isWide) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Row(
            children: [
              SizedBox(
                width: 260,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _AudioCoverCard(coverFile: _coverFile, size: 208),
                    const SizedBox(height: 18),
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 48),
              Expanded(child: lyricWidget),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              _AudioCoverCard(coverFile: _coverFile, size: 52, radius: 10),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: lyricWidget),
      ],
    );
  }

  LyricPreset _buildLyricPreset(ColorScheme scheme, {required bool isWide}) {
    final accent = Color.lerp(scheme.primary, Colors.white, 0.35)!;
    return LyricPresets.aurora.copyWith(
      textStyle: TextStyle(
        fontSize: isWide ? 21 : 17.5,
        color: const Color(0x66FFFFFF),
        height: 1.35,
      ),
      activeTextStyle: TextStyle(
        fontSize: isWide ? 26 : 21.5,
        color: const Color(0x99FFFFFF),
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
      translationTextStyle: TextStyle(
        fontSize: isWide ? 14 : 13,
        color: const Color(0x66FFFFFF),
        height: 1.45,
      ),
      activeTranslationTextStyle: TextStyle(
        fontSize: isWide ? 15.5 : 14,
        color: const Color(0xE6FFFFFF),
        fontWeight: FontWeight.w500,
        height: 1.45,
      ),
      textAlign: TextAlign.center,
      contentAlignment: LyricContentAlignment.center,
      padding: EdgeInsets.symmetric(horizontal: isWide ? 16 : 12),
      lineSpacing: isWide ? 26 : 20,
      translationSpacing: 7,
      activeAnchor: LyricAnchor.fraction(
        isWide ? 0.42 : 0.45,
        target: LyricAnchorTarget.mainText,
      ),
      highlight: LyricHighlight.gradient(
        LinearGradient(colors: [accent, Colors.white]),
        tailFadeWidth: 32,
      ),
      countdown: LyricPresets.aurora.countdown.copyWith(color: accent),
    );
  }
}

/// 纯净圆角音频封面卡片（无高斯模糊底图）。
class _AudioCoverCard extends StatelessWidget {
  const _AudioCoverCard({
    required this.coverFile,
    required this.size,
    this.radius = 18,
  });

  final File? coverFile;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final hasFile = coverFile != null && coverFile!.existsSync();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: hasFile
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF332D66), Color(0xFF1D223B)],
              ),
        border: Border.all(color: Colors.white.withValues(alpha: .12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .42),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: hasFile
          ? Image.file(
              coverFile!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _defaultIcon(),
            )
          : _defaultIcon(),
    );
  }

  Widget _defaultIcon() {
    return Center(
      child: Icon(
        Icons.music_note_rounded,
        size: size * 0.44,
        color: Colors.white.withValues(alpha: .82),
      ),
    );
  }
}
