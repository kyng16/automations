import 'package:speech_to_text/speech_to_text.dart' as stt;

/// VoiceService based on native speech recognition (speech_to_text).
/// No OpenAI key required; results are recognized on-device/OS service.
class VoiceService {
  VoiceService() : _stt = stt.SpeechToText();

  final stt.SpeechToText _stt;
  String _lastText = '';
  bool _available = false;

  Future<bool> _ensureInit() async {
    if (_available) return true;
    _available = await _stt.initialize(
      onError: (e) {
        // Optionally log
      },
      onStatus: (s) {
        // Optionally log
      },
    );
    return _available;
  }

  Future<bool> hasPermission() async {
    return await _ensureInit();
  }

  Future<void> start({String localeId = 'pl_PL'}) async {
    _lastText = '';
    if (!await _ensureInit()) return;
    await _stt.listen(
      localeId: localeId,
      onResult: (result) {
        _lastText = result.recognizedWords;
      },
      listenMode: stt.ListenMode.confirmation,
      partialResults: true,
    );
  }

  /// Stops listening and returns the final recognized text (or null if none).
  Future<String?> stop() async {
    if (_stt.isListening) {
      await _stt.stop();
    }
    final text = _lastText.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> cancel() async {
    if (_stt.isListening) {
      await _stt.cancel();
    }
    _lastText = '';
  }
}
