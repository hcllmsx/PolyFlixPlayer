import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

void main() {
  group('WhisperController.transcribeLive model arguments', () {
    test('throws when neither model nor modelPath is provided', () {
      expect(
        WhisperController().transcribeLive(
          pcm16Stream: const Stream<Uint8List>.empty(),
        ),
        throwsArgumentError,
      );
    });

    test('throws when both model and modelPath are provided', () {
      expect(
        WhisperController().transcribeLive(
          model: WhisperModel.base,
          modelPath: '/models/ggml-base.bin',
          pcm16Stream: const Stream<Uint8List>.empty(),
        ),
        throwsArgumentError,
      );
    });
  });
}
