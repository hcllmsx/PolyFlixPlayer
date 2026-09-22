import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:whisper_ggml/src/models/whisper_dto.dart';

part 'release_model_request.freezed.dart';

/// Free the model parked in native memory by a transcription with
/// `keepModelLoaded: true`
@freezed
class ReleaseModelRequest
    with _$ReleaseModelRequest
    implements WhisperRequestDto {
  ///
  const factory ReleaseModelRequest() = _ReleaseModelRequest;
  const ReleaseModelRequest._();

  @override
  String get specialType => 'releaseModel';

  @override
  String toRequestString() {
    return json.encode({'@type': specialType});
  }
}
