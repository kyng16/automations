import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

void main(List<String> args) async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final apiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    // We still start the server, but requests will fail with a clear message.
    stderr.writeln('Warning: OPENAI_API_KEY is not set. Requests to /chat will fail.');
  }

  final router = Router()
    ..get('/', (Request req) async {
      return Response.ok(
        jsonEncode({
          'status': 'ok',
          'message': 'AutoEmotion server is running. Use GET /health, POST /chat, POST /transcribe.',
          'version': '2025-10-29',
          'routes': {
            'GET /': 'this info',
            'GET /health': 'service health',
            'POST /chat': 'OpenAI chat completions proxy',
            'POST /transcribe': 'OpenAI Whisper transcription proxy',
          }
        }),
        headers: {'Content-Type': 'application/json'},
      );
    })
    ..post('/transcribe', (Request req) async {
      if (apiKey.isEmpty) {
        return Response(500, body: jsonEncode({'error': 'Server misconfigured: OPENAI_API_KEY is not set'}), headers: {'Content-Type': 'application/json'});
      }
      // Accept raw audio bytes; optional headers: x-filename, content-type
      final filename = req.headers['x-filename'] ?? 'audio.wav';
      final bytes = await req.read().expand((e) => e).toList();
      if (bytes.isEmpty) {
        return Response(400, body: jsonEncode({'error': 'Empty audio payload'}), headers: {'Content-Type': 'application/json'});
      }

      try {
        final request = http.MultipartRequest('POST', Uri.parse('https://api.openai.com/v1/audio/transcriptions'));
        request.headers['Authorization'] = 'Bearer $apiKey';
        request.fields['model'] = 'whisper-1';
        request.fields['response_format'] = 'json';
        // Optional: set language to Polish to improve accuracy
        request.fields['language'] = 'pl';
        request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
        final streamed = await request.send();
        final res = await http.Response.fromStream(streamed);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          String msg = 'HTTP ${res.statusCode}';
          try {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            if (data['error'] is String) msg = '${res.statusCode}: ${data['error']}';
          } catch (_) {}
          return Response(502, body: jsonEncode({'error': 'OpenAI STT error: $msg'}), headers: {'Content-Type': 'application/json'});
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final text = (data['text'] ?? '').toString();
        return Response.ok(jsonEncode({'text': text}), headers: {'Content-Type': 'application/json'});
      } catch (e) {
        return Response(500, body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
      }
    })
    ..get('/transcribe', (Request req) async {
      return Response(405,
          body: jsonEncode({'error': 'Method Not Allowed. Use POST /transcribe with raw audio bytes.'}),
          headers: {'Content-Type': 'application/json'});
    })
    ..get('/health', (Request req) async {
      return Response.ok(jsonEncode({'status': 'ok'}), headers: {'Content-Type': 'application/json'});
    })
    ..post('/emotion', (Request req) async {
      if (apiKey.isEmpty) {
        return Response(500, body: jsonEncode({'error': 'Server misconfigured: OPENAI_API_KEY is not set'}), headers: {'Content-Type': 'application/json'});
      }

      final raw = await req.readAsString();
      Map<String, dynamic> body;
      try {
        body = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return Response(400, body: jsonEncode({'error': 'Invalid JSON body'}), headers: {'Content-Type': 'application/json'});
      }

      final text = (body['text'] ?? '').toString().trim();
      if (text.isEmpty) {
        return Response(400, body: jsonEncode({'error': 'Missing "text"'}), headers: {'Content-Type': 'application/json'});
      }
      final model = (body['model'] ?? 'gpt-4o-mini').toString();
      final labels = (body['labels'] is List)
          ? (body['labels'] as List).whereType<String>().toList()
          : <String>['Radość', 'Złość', 'Strach', 'Smutek', 'Wstyd'];

      final system = 'You are an expert emotion classifier (Polish). Classify the USER text into exactly one of the labels: ${labels.join(', ')}. '
          'Return ONLY strict JSON: {"label":"<one of labels>","confidence":<0..1>,"scores":{"Radość":0..1,"Złość":0..1,"Strach":0..1,"Smutek":0..1,"Wstyd":0..1}}. '
          'No markdown, no extra text.';

      final messages = [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': text},
      ];

      try {
        final res = await http.post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': messages,
            'temperature': 0.1,
          }),
        );

        if (res.statusCode < 200 || res.statusCode >= 300) {
          String msg = 'HTTP ${res.statusCode}';
          try {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            final err = data['error'];
            if (err is Map && err['message'] is String) {
              msg = '${res.statusCode}: ${err['message']}';
            }
          } catch (_) {}
          return Response(502, body: jsonEncode({'error': 'OpenAI error: $msg'}), headers: {'Content-Type': 'application/json'});
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) {
          return Response(502, body: jsonEncode({'error': 'No choices returned from OpenAI'}), headers: {'Content-Type': 'application/json'});
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
        if (out.isEmpty) {
          return Response(502, body: jsonEncode({'error': 'Empty response content from OpenAI'}), headers: {'Content-Type': 'application/json'});
        }

        // Try to parse JSON from the model output
        Map<String, dynamic>? parsed;
        try {
          parsed = jsonDecode(out) as Map<String, dynamic>;
        } catch (_) {
          // attempt to extract JSON blob
          final start = out.indexOf('{');
          final end = out.lastIndexOf('}');
          if (start != -1 && end != -1 && end > start) {
            final snippet = out.substring(start, end + 1);
            try { parsed = jsonDecode(snippet) as Map<String, dynamic>; } catch (_) {}
          }
        }
        if (parsed == null) {
          return Response(502, body: jsonEncode({'error': 'Classifier did not return JSON', 'raw': out}), headers: {'Content-Type': 'application/json'});
        }

        return Response.ok(jsonEncode(parsed), headers: {'Content-Type': 'application/json'});
      } catch (e) {
        return Response(500, body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
      }
    })
    ..get('/chat', (Request req) async {
      return Response(405,
          body: jsonEncode({'error': 'Method Not Allowed. Use POST /chat with JSON body {prompt|messages}.'}),
          headers: {'Content-Type': 'application/json'});
    })
    ..post('/chat', (Request req) async {
      if (apiKey.isEmpty) {
        return Response(500, body: jsonEncode({'error': 'Server misconfigured: OPENAI_API_KEY is not set'}), headers: {'Content-Type': 'application/json'});
      }

      final raw = await req.readAsString();
      Map<String, dynamic> body;
      try {
        body = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return Response(400, body: jsonEncode({'error': 'Invalid JSON body'}), headers: {'Content-Type': 'application/json'});
      }

      final model = (body['model'] ?? 'gpt-4o-mini').toString();
      final temperature = (body['temperature'] is num) ? (body['temperature'] as num).toDouble() : 0.7;

      // accept either full messages array or a single prompt + optional system
      List<Map<String, String>> messages = [];
      if (body['messages'] is List) {
        final raw = body['messages'] as List;
        for (final m in raw) {
          if (m is Map && m['role'] is String && m['content'] is String) {
            messages.add({'role': m['role'] as String, 'content': m['content'] as String});
          }
        }
      } else {
        final prompt = (body['prompt'] ?? '').toString().trim();
        final system = (body['system'] ?? '').toString().trim();
        if (prompt.isEmpty) {
          return Response(400, body: jsonEncode({'error': 'Missing "prompt"'}), headers: {'Content-Type': 'application/json'});
        }
        if (system.isNotEmpty) {
          messages.add({'role': 'system', 'content': system});
        }
        messages.add({'role': 'user', 'content': prompt});
      }

      try {
        final res = await http.post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': messages,
            'temperature': temperature,
          }),
        );

        if (res.statusCode < 200 || res.statusCode >= 300) {
          String msg = 'HTTP ${res.statusCode}';
          try {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            final err = data['error'];
            if (err is Map && err['message'] is String) {
              msg = '${res.statusCode}: ${err['message']}';
            }
          } catch (_) {}
          return Response(502, body: jsonEncode({'error': 'OpenAI error: $msg'}), headers: {'Content-Type': 'application/json'});
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) {
          return Response(502, body: jsonEncode({'error': 'No choices returned from OpenAI'}), headers: {'Content-Type': 'application/json'});
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
        if (out.isEmpty) {
          return Response(502, body: jsonEncode({'error': 'Empty response content from OpenAI'}), headers: {'Content-Type': 'application/json'});
        }

        return Response.ok(jsonEncode({'content': out}), headers: {'Content-Type': 'application/json'});
      } catch (e) {
        return Response(500, body: jsonEncode({'error': e.toString()}), headers: {'Content-Type': 'application/json'});
      }
    });

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsHeaders())
      .addHandler(router);

  final server = await serve(handler, InternetAddress.anyIPv4, port);
  print('Server listening on http://${server.address.host}:${server.port}');
}
