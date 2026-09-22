import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_ggml/src/models/requests/release_model_request.dart';

void main() {
  group('ReleaseModelRequest serialization', () {
    test('serializes to the releaseModel native request', () {
      const request = ReleaseModelRequest();

      expect(request.specialType, 'releaseModel');

      final body =
          json.decode(request.toRequestString()) as Map<String, dynamic>;
      expect(body, {'@type': 'releaseModel'});
    });
  });
}
