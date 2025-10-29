import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

class VoiceService {
  VoiceService() : _rec = AudioRecorder();

  final AudioRecorder _rec;

  Future<bool> hasPermission() async {
    return await _rec.hasPermission();
  }

  Future<void> start() async {
    if (!await _rec.hasPermission()) return;
    final dir = Directory.systemTemp;
    final path = dir.path + Platform.pathSeparator + 'rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100), path: path);
  }

  Future<({Uint8List bytes, String filename})?> stop() async {
    final path = await _rec.stop();
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final filename = path.split(Platform.pathSeparator).last;
    return (bytes: bytes, filename: filename);
  }

  Future<void> cancel() async {
    if (await _rec.isRecording()) {
      await _rec.cancel();
    }
  }
}
