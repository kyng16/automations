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
    ..get('/health', (Request req) async {
      return Response.ok(jsonEncode({'status': 'ok'}), headers: {'Content-Type': 'application/json'});
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

      final prompt = (body['prompt'] ?? '').toString().trim();
      final model = (body['model'] ?? 'gpt-4o-mini').toString();
      final system = (body['system'] ?? '').toString().trim();
      if (prompt.isEmpty) {
        return Response(400, body: jsonEncode({'error': 'Missing "prompt"'}), headers: {'Content-Type': 'application/json'});
      }

      final messages = <Map<String, String>>[];
      if (system.isNotEmpty) {
        messages.add({'role': 'system', 'content': system});
      }
      messages.add({'role': 'user', 'content': prompt});

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
            'temperature': 0.7,
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
