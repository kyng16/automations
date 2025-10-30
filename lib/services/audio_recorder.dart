import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

class AudioRecorderService {
  AudioRecorderService() : _rec = AudioRecorder();

  final AudioRecorder _rec;

  Future<bool> hasPermission() async {
    return await _rec.hasPermission();
  }

  Future<void> start() async {
    // Do not early-return on permission; starting the recorder triggers a permission prompt.
    final dir = Directory.systemTemp;
    final path = dir.path + Platform.pathSeparator + 'rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
        path: path,
      );
    } catch (_) {
      // If permission denied or start fails, ignore here; stop() will return null.
    }
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
