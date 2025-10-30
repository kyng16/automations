import 'dart:convert';

import 'package:http/http.dart' as http;
import '../models/chat_message.dart';
import '../models/emotion_result.dart';

class OpenAIService {
  OpenAIService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // Read API key securely via --dart-define=OPENAI_API_KEY=... at run/build time
  static const String _apiKey = String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
  static String? _apiKeyRuntime;
  // Optional: If provided, client will call your backend proxy instead of OpenAI directly
  static const String _apiBaseUrlConst = String.fromEnvironment('API_BASE_URL', defaultValue: '');
  static String? _apiBaseUrlRuntime;

  // Set at runtime from settings UI; pass null to clear and fall back to compile-time value
  static void setRuntimeBaseUrl(String? url) {
    _apiBaseUrlRuntime = (url ?? '').trim();
  }

  static String get apiBaseUrl {
    final src = (_apiBaseUrlRuntime?.isNotEmpty ?? false) ? _apiBaseUrlRuntime! : _apiBaseUrlConst;
    if (src.isEmpty) return '';
    return src.endsWith('/') ? src.substring(0, src.length - 1) : src;
  }

  static bool get isProxy => apiBaseUrl.isNotEmpty;
  static bool get hasApiKey => apiKey.isNotEmpty;
  static String get apiKey => (_apiKeyRuntime != null && _apiKeyRuntime!.isNotEmpty) ? _apiKeyRuntime! : _apiKey;
  static void setRuntimeApiKey(String? key) {
    _apiKeyRuntime = (key ?? '').trim();
  }

  static const String _chatCompletionsUrl = 'https://api.openai.com/v1/chat/completions';
  // Note: direct audio transcription URL intentionally unused to enforce server-only transcription
  // static const String _audioTranscriptionsUrl = 'https://api.openai.com/v1/audio/transcriptions';

  /// Sends a prompt to OpenAI and returns the assistant response text.
  ///
  /// Parameters:
  /// - [prompt]: user input text
  /// - [model]: model id available to your OpenAI account (e.g., "gpt-4o-mini", "gpt-4o").
  /// - [system]: optional system instruction to steer the assistant behavior.
  Future<String> chat({
    required String prompt,
    String model = 'gpt-4o-mini',
    String? system,
  }) async {
    if (_apiKey.isEmpty) {
      throw StateError('OPENAI_API_KEY is not set. Start the app with --dart-define=OPENAI_API_KEY=your_key');
    }

    final messages = <Map<String, String>>[];
    if (system != null && system.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content': system,
      });
    }
    messages.add({
      'role': 'user',
      'content': prompt,
    });

    http.Response res;
    if (isProxy) {
      // Call your backend proxy
      final uri = Uri.parse('${apiBaseUrl}/chat');
      res = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'prompt': prompt,
          'model': model,
          'system': system ?? '',
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final content = data['content'];
        if (content is String && content.isNotEmpty) return content;
        throw StateError('Empty response content from proxy');
      }
      // If proxy fails, try to parse error for clarity
      String msg = 'HTTP ${res.statusCode}';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['error'] is String) msg = '${res.statusCode}: ${data['error']}';
      } catch (_) {}
      throw HttpException('Proxy API error: $msg');
    } else {
      // Direct call to OpenAI
      final uri = Uri.parse(_chatCompletionsUrl);
      res = await _client.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'temperature': 0.7,
        }),
      );
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        throw StateError('No choices returned from OpenAI');
      }
      final message = choices.first['message'] as Map<String, dynamic>?;
      final content = message?['content'];
      if (content is String && content.isNotEmpty) return content;
      // Some responses may return as a list of content parts; handle robustly.
      if (content is List) {
        final sb = StringBuffer();
        for (final part in content) {
          final text = part is Map<String, dynamic> ? part['text'] : part?.toString();
          if (text != null) sb.writeln(text);
        }
        final out = sb.toString().trim();
        if (out.isNotEmpty) return out;
      }
      throw StateError('Empty response content from OpenAI');
    } else {
      // Try to extract error message from body
      String msg = 'HTTP ${res.statusCode}';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final err = data['error'];
        if (err is Map && err['message'] is String) {
          msg = '${res.statusCode}: ${err['message']}';
        }
      } catch (_) {
        // ignore
      }
      throw HttpException('OpenAI API error: $msg');
    }
  }

  /// Sends full chat history and returns the assistant's reply
  Future<String> chatWithHistory({
    required List<ChatMessage> messages,
    String model = 'gpt-4o-mini',
    double temperature = 0.7,
  }) async {
    if (isProxy) {
      final uri = Uri.parse('${apiBaseUrl}/chat');
      final res = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'temperature': temperature,
          'messages': messages.map((m) => m.toJson()).toList(),
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final content = data['content'];
        if (content is String && content.isNotEmpty) return content;
        throw StateError('Empty response content from proxy');
      }
      String msg = 'HTTP ${res.statusCode}';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['error'] is String) msg = '${res.statusCode}: ${data['error']}';
      } catch (_) {}
      throw HttpException('Proxy API error: $msg');
    } else {
      if (apiKey.isEmpty) {
        throw StateError('OPENAI_API_KEY is not set. Start with --dart-define=OPENAI_API_KEY=... or set API_BASE_URL');
      }
      final uri = Uri.parse(_chatCompletionsUrl);
      final res = await _client.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'temperature': temperature,
          'messages': messages.map((m) => m.toJson()).toList(),
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) {
          throw StateError('No choices returned from OpenAI');
        }
        final message = choices.first['message'] as Map<String, dynamic>?;
        final content = message?['content'];
        if (content is String && content.isNotEmpty) return content;
        if (content is List) {
          final sb = StringBuffer();
          for (final part in content) {
            final text = part is Map<String, dynamic> ? part['text'] : part?.toString();
            if (text != null) sb.writeln(text);
          }
          final out = sb.toString().trim();
          if (out.isNotEmpty) return out;
        }
        throw StateError('Empty response content from OpenAI');
      }
      String msg = 'HTTP ${res.statusCode}';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final err = data['error'];
        if (err is Map && err['message'] is String) msg = '${res.statusCode}: ${err['message']}';
      } catch (_) {}
      throw HttpException('OpenAI API error: $msg');
    }
  }

  void dispose() {
    _client.close();
  }

  /// Classify text into one of the given Polish emotion labels.
  Future<EmotionResult> analyzeEmotion({
    required String text,
    String model = 'gpt-4o-mini',
    List<String>? labels,
  }) async {
    final usedLabels = labels ?? const ['Radość', 'Złość', 'Strach', 'Smutek', 'Wstyd'];
    if (isProxy) {
      // Prefer dedicated /emotion endpoint if available
      final uri = Uri.parse('${apiBaseUrl}/emotion');
      final res = await _client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': text,
          'model': model,
          'labels': usedLabels,
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return EmotionResult.fromJson(data);
      }
      // Fallback: older servers may not have /emotion; use /chat with classifier prompt
      final system = 'You are an expert emotion classifier (Polish). Classify the USER text into exactly one of the labels: ${usedLabels.join(', ')}. '
          'Return ONLY strict JSON: {"label":"<one of labels>","confidence":<0..1>,"scores":{"Radość":0..1,"Złość":0..1,"Strach":0..1,"Smutek":0..1,"Wstyd":0..1}}. No extra text.';
      final chatRes = await _client.post(
        Uri.parse('${apiBaseUrl}/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'prompt': text,
          'model': model,
          'system': system,
          'temperature': 0.1,
        }),
      );
      if (chatRes.statusCode >= 200 && chatRes.statusCode < 300) {
        try {
          final data = jsonDecode(chatRes.body) as Map<String, dynamic>;
          final content = data['content']?.toString() ?? '';
          if (content.isEmpty) throw StateError('Empty content from proxy');
          try {
            final obj = jsonDecode(content) as Map<String, dynamic>;
            return EmotionResult.fromJson(obj);
          } catch (_) {
            final start = content.indexOf('{');
            final end = content.lastIndexOf('}');
            if (start != -1 && end != -1 && end > start) {
              final snippet = content.substring(start, end + 1);
              final obj = jsonDecode(snippet) as Map<String, dynamic>;
              return EmotionResult.fromJson(obj);
            }
            throw StateError('Classifier did not return JSON');
          }
        } catch (e) {
          throw HttpException('Proxy /chat parse error: $e');
        }
      }
      String msg = 'HTTP ${chatRes.statusCode}';
      try {
        final data = jsonDecode(chatRes.body) as Map<String, dynamic>;
        if (data['error'] is String) msg = '${chatRes.statusCode}: ${data['error']}';
      } catch (_) {}
      throw HttpException('Proxy API error: $msg');
    } else {
      if (_apiKey.isEmpty) {
        throw StateError('OPENAI_API_KEY is not set. Start with --dart-define=OPENAI_API_KEY=... or set API_BASE_URL');
      }
      final system = 'You are an expert emotion classifier (Polish). Classify the USER text into exactly one of the labels: ${usedLabels.join(', ')}. '
          'Return ONLY strict JSON: {"label":"<one of labels>","confidence":<0..1>,"scores":{"Radość":0..1,"Złość":0..1,"Strach":0..1,"Smutek":0..1,"Wstyd":0..1}}. No extra text.';
      final res = await _client.post(
        Uri.parse(_chatCompletionsUrl),
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'temperature': 0.1,
          'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': text},
          ],
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) {
          throw StateError('No choices returned from OpenAI');
        }
        final message = choices.first['message'] as Map<String, dynamic>?;
        final content = message?['content'];
        String out = '';
        if (content is String) out = content;
        if (out.isEmpty && content is List) {
          final sb = StringBuffer();
          for (final part in content) {
            final text = part is Map<String, dynamic> ? part['text'] : part?.toString();
            if (text != null) sb.writeln(text);
          }
          out = sb.toString().trim();
        }
        // parse JSON
        try {
          final jsonObj = jsonDecode(out) as Map<String, dynamic>;
          return EmotionResult.fromJson(jsonObj);
        } catch (_) {
          final start = out.indexOf('{');
          final end = out.lastIndexOf('}');
          if (start != -1 && end != -1 && end > start) {
            final snippet = out.substring(start, end + 1);
            final jsonObj = jsonDecode(snippet) as Map<String, dynamic>;
            return EmotionResult.fromJson(jsonObj);
          }
          throw StateError('Classifier did not return JSON');
        }
      }
      String msg = 'HTTP ${res.statusCode}';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final err = data['error'];
        if (err is Map && err['message'] is String) msg = '${res.statusCode}: ${err['message']}';
      } catch (_) {}
      throw HttpException('OpenAI API error: $msg');
    }
  }

  /// Transcribe audio bytes using OpenAI (proxy preferred, direct fallback).
  /// Returns the recognized text.
  Future<String> transcribeAudio({
    required List<int> bytes,
    String filename = 'audio.wav',
    String model = 'whisper-1',
    String language = 'pl',
  }) async {
    if (isProxy) {
      final uri = Uri.parse('${apiBaseUrl}/transcribe');
      final res = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/octet-stream',
              'Accept': 'application/json',
              'x-filename': filename,
            },
            body: bytes,
          )
          // Cold starts + upload can take a while
          .timeout(const Duration(seconds: 120));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return (data['text'] ?? '').toString();
      }
      String msg = 'HTTP ${res.statusCode}';
      try {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['error'] is String) msg = '${res.statusCode}: ${data['error']}';
      } catch (_) {}
      if (res.statusCode == 404 || res.statusCode == 405) {
        throw HttpException('Proxy STT error: $msg. Serwer nie ma jeszcze /transcribe – zaktualizuj/deploynij serwer. (Brak fallbacku bezpośredniego – klucz OpenAI nie jest używany w aplikacji)');
      }
      throw HttpException('Proxy STT error: $msg');
    } else {
      // Bez API_BASE_URL nie wykonujemy transkrypcji (wymagany serwer pośredniczący)
      throw HttpException('Brak API_BASE_URL. Skonfiguruj URL serwera (proxy), aby używać transkrypcji mowy.');
    }
  }

  // Bezpośrednia transkrypcja (Whisper) została wyłączona w aplikacji, aby klucz OpenAI nie był przechowywany po stronie klienta.
}

class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}
