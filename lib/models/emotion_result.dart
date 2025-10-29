class EmotionResult {
  EmotionResult({required this.label, required this.confidence, this.scores});

  final String label; // e.g., Radość, Złość, Strach, Smutek, Wstyd
  final double confidence; // 0..1
  final Map<String, double>? scores; // optional per-label scores

  factory EmotionResult.fromJson(Map<String, dynamic> json) {
    final scoresRaw = json['scores'];
    Map<String, double>? scores;
    if (scoresRaw is Map) {
      scores = scoresRaw.map((k, v) => MapEntry(k.toString(), (v is num) ? v.toDouble() : 0.0));
    }
    return EmotionResult(
      label: (json['label'] ?? '').toString(),
      confidence: (json['confidence'] is num) ? (json['confidence'] as num).toDouble() : 0.0,
      scores: scores,
    );
  }
}
