import 'responses/whisper_transcribe_response.dart';

class TranscribeResult {
  const TranscribeResult({required this.transcription, required this.time});
  final WhisperTranscribeResponse transcription;
  final Duration time;
}
