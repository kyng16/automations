import 'package:flutter/material.dart';
import 'services/openai_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'models/chat_message.dart';
import 'models/emotion_result.dart';
import 'services/voice_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final OpenAIService _openAI;
  final _controller = TextEditingController();
  final List<ChatMessage> _messages = [
    ChatMessage(role: ChatRole.system, content: 'Jesteś pomocnym asystentem. Odpowiadaj zwięźle.'),
  ];
  bool _sending = false;
  String _error = '';
  bool _prefsLoaded = false;
  String _selectedModel = 'gpt-4o-mini';
  bool _autoPrompted = false;
  final Map<int, EmotionResult> _emotions = {};
  late final VoiceService _voice;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _openAI = OpenAIService();
  _voice = VoiceService();
    _loadSavedApiBase();
  }

  @override
  void dispose() {
    _controller.dispose();
    _openAI.dispose();
    super.dispose();
  }

  Future<void> _loadSavedApiBase() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString('api_base_url');
      if (url == null || url.trim().isEmpty) {
        // Auto-apply default proxy once if nothing is set
        const def = 'https://autoemotion-server.onrender.com';
        await prefs.setString('api_base_url', def);
        OpenAIService.setRuntimeBaseUrl(def);
      } else {
        OpenAIService.setRuntimeBaseUrl(url);
      }
      final model = prefs.getString('openai_model');
      if (model != null && model.isNotEmpty) {
        _selectedModel = model;
      }
    } catch (_) {
      // ignore
    } finally {
      if (mounted) {
        setState(() => _prefsLoaded = true);
        // After first frame, if not configured, prompt to set proxy URL
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_autoPrompted && !_isConfigured) {
            _autoPrompted = true;
            _editApiBaseUrl();
          }
        });
      }
    }
  }

  bool get _isConfigured => OpenAIService.isProxy || OpenAIService.hasApiKey;

  Future<void> _setDefaultProxy() async {
    final prefs = await SharedPreferences.getInstance();
    const def = 'https://autoemotion-server.onrender.com';
    await prefs.setString('api_base_url', def);
    OpenAIService.setRuntimeBaseUrl(def);
    if (mounted) setState(() {});
  }

  Future<void> _editApiBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final textCtrl = TextEditingController(text: OpenAIService.apiBaseUrl);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Ustaw URL serwera (proxy)'),
          content: TextField(
            controller: textCtrl,
            decoration: const InputDecoration(hintText: 'https://autoemotion-server.onrender.com'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Anuluj'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('Wyczyść'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('https://autoemotion-server.onrender.com'),
              child: const Text('Domyślny'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(textCtrl.text.trim()),
              child: const Text('Zapisz'),
            ),
          ],
        );
      },
    );
    if (result == null) return; // canceled
    final newUrl = result.isEmpty ? null : result;
    await prefs.setString('api_base_url', newUrl ?? '');
    OpenAIService.setRuntimeBaseUrl(newUrl);
    if (mounted) setState(() {});
  }

  // Klucz OpenAI nie jest ustawiany po stronie aplikacji – transkrypcja wyłącznie przez serwer.

  Future<void> _checkProxy() async {
    final base = OpenAIService.apiBaseUrl;
    if (base.isEmpty) {
      // Prompt to set base URL
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Brak API_BASE_URL'),
          content: const Text('Ustaw URL serwera (proxy), aby sprawdzić połączenie.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Zamknij')),
            TextButton(onPressed: () { Navigator.of(ctx).pop(); _setDefaultProxy(); }, child: const Text('Ustaw domyślny')),
            FilledButton(onPressed: () { Navigator.of(ctx).pop(); _editApiBaseUrl(); }, child: const Text('Ustaw...')),
          ],
        ),
      );
      return;
    }

    String rInfo = '';
    String rHealth = '';
    String rTranscribe = '';
    final client = http.Client();
    try {
      // GET /
      try {
        final res = await client.get(Uri.parse('$base/')).timeout(const Duration(seconds: 8));
        rInfo = 'GET / => ${res.statusCode}${res.statusCode == 200 ? '' : ''}';
        // Try to detect presence of transcribe route in root info
        if (res.statusCode == 200) {
          final body = res.body;
          if (body.contains('transcribe') || body.contains('POST /transcribe')) {
            rInfo += ' (routes include /transcribe)';
          }
        }
      } catch (e) {
        rInfo = 'GET / => ERROR: $e';
      }

      // GET /health
      try {
        final res = await client.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 8));
        rHealth = 'GET /health => ${res.statusCode}';
      } catch (e) {
        rHealth = 'GET /health => ERROR: $e';
      }

      // GET /transcribe (should be 405 if route exists)
      try {
        final res = await client.get(Uri.parse('$base/transcribe')).timeout(const Duration(seconds: 8));
        rTranscribe = 'GET /transcribe => ${res.statusCode}${res.statusCode == 405 ? ' (OK: route present)' : res.statusCode == 404 ? ' (Not Found: brak trasy)' : ''}';
      } catch (e) {
        rTranscribe = 'GET /transcribe => ERROR: $e';
      }
    } finally {
      client.close();
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sprawdzenie proxy'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(rInfo),
            const SizedBox(height: 6),
            Text(rHealth),
            const SizedBox(height: 6),
            Text(rTranscribe),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Zamknij')),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (!_isConfigured) {
      // Prompt to configure proxy instead of throwing runtime error
      _editApiBaseUrl();
      return;
    }
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = '';
      _messages.add(ChatMessage(role: ChatRole.user, content: text));
      _controller.clear();
    });
    final userIndex = _messages.length - 1;
    try {
      final replyFuture = _openAI.chatWithHistory(
        messages: _messages,
        model: _selectedModel,
      );
      // Run emotion analysis in parallel
      final emotionFuture = _openAI.analyzeEmotion(text: text, model: _selectedModel);
      final reply = await replyFuture;
      // Update assistant reply
      setState(() {
        _messages.add(ChatMessage(role: ChatRole.assistant, content: reply));
      });
      // Update emotion (ignore failures)
      try {
        final em = await emotionFuture;
        if (mounted) setState(() => _emotions[userIndex] = em);
      } catch (_) {}
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _sending = false);
    }
  }

  Future<void> _startListening() async {
    if (!_isConfigured) {
      _editApiBaseUrl();
      return;
    }
    setState(() {
      _listening = true;
      _error = '';
    });
    await _voice.start();
  }

  Future<void> _stopListening() async {
    final rec = await _voice.stop();
    if (!mounted) return;
    setState(() => _listening = false);
    if (rec == null) return;
    try {
      final transcript = await _openAI.transcribeAudio(bytes: rec.bytes, filename: rec.filename);
      if (!mounted) return;
      _controller.text = transcript;
      _controller.selection = TextSelection.fromPosition(TextPosition(offset: _controller.text.length));
      if (transcript.trim().isNotEmpty && !_sending) {
        await _send();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Wybierz model',
            icon: const Icon(Icons.auto_awesome),
            initialValue: _selectedModel,
            onSelected: (value) async {
              setState(() => _selectedModel = value);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('openai_model', value);
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'gpt-5', child: Text('gpt-5')),
              PopupMenuItem(value: 'gpt-4o', child: Text('gpt-4o')),
              PopupMenuItem(value: 'gpt-4o-mini', child: Text('gpt-4o-mini')),
            ],
          ),
          IconButton(
            tooltip: 'Ustaw URL serwera',
            onPressed: _editApiBaseUrl,
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: 'Sprawdź proxy',
            onPressed: _checkProxy,
            icon: const Icon(Icons.plumbing),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_prefsLoaded)
            const LinearProgressIndicator(minHeight: 2)
          else if (OpenAIService.isProxy)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12, right: 12),
              child: Text(
                'Proxy: ${OpenAIService.apiBaseUrl} • Model: $_selectedModel',
                style: const TextStyle(fontSize: 12, color: Colors.green),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12, right: 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Tryb direct (brak API_BASE_URL). Ustaw URL serwera lub klucz OPENAI_API_KEY.',
                      style: TextStyle(fontSize: 12, color: Colors.redAccent),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _setDefaultProxy,
                    child: const Text('Ustaw domyślny'),
                  ),
                  TextButton(
                    onPressed: _editApiBaseUrl,
                    child: const Text('Ustaw...'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final m = _messages[index];
                if (m.role == ChatRole.system) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Center(
                      child: Text(
                        m.content,
                        style: const TextStyle(color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final isUser = m.role == ChatRole.user;
                final bubble = Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    decoration: BoxDecoration(
                      color: isUser ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(
                      m.content,
                      style: TextStyle(
                        color: isUser ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
                if (!isUser) return bubble;
                final em = _emotions[index];
                if (em == null) return bubble;
                Color chipColor = _emotionColor(em.label, Theme.of(context));
                return Column(
                  crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    bubble,
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Chip(
                        label: Text('${em.label} ${_formatPct(em.confidence)}'),
                        backgroundColor: chipColor.withOpacity(0.15),
                        side: BorderSide(color: chipColor.withOpacity(0.6)),
                        labelStyle: TextStyle(color: chipColor.computeLuminance() < 0.4 ? Colors.white : Colors.black),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: Text(_error, style: const TextStyle(color: Colors.red)),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  GestureDetector(
                    onLongPressStart: (_) => _startListening(),
                    onLongPressEnd: (_) => _stopListening(),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _listening ? Colors.redAccent : Theme.of(context).colorScheme.surfaceVariant,
                        shape: BoxShape.circle,
                        boxShadow: _listening
                            ? [BoxShadow(color: Colors.redAccent.withOpacity(0.5), blurRadius: 10, spreadRadius: 2)]
                            : null,
                      ),
                      child: Icon(
                        _listening ? Icons.mic : Icons.mic_none,
                        color: _listening ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: _isConfigured,
                      minLines: 1,
                      maxLines: 6,
                      decoration: InputDecoration(
                        hintText: _isConfigured ? 'Napisz wiadomość...' : 'Najpierw ustaw URL serwera (ikona koła zębatego)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }
}

String _formatPct(double v) => '${(v * 100).round()}%';

Color _emotionColor(String label, ThemeData theme) {
  switch (label.toLowerCase()) {
    case 'radość':
      return Colors.orangeAccent;
    case 'złość':
      return Colors.redAccent;
    case 'strach':
      return Colors.blueGrey;
    case 'smutek':
      return Colors.blueAccent;
    case 'wstyd':
      return Colors.purpleAccent;
    default:
      return theme.colorScheme.secondary;
  }
}
