class NsfwScanResult {
  const NsfwScanResult({
    required this.imagePath,
    required this.nsfwScore,
    required this.safeScore,
    required this.isNsfw,
    required this.topLabel,
    required this.topScore,
    required this.scores,
    this.error,
  });

  final String imagePath;
  final double nsfwScore;
  final double safeScore;
  final bool isNsfw;
  final String topLabel;
  final double topScore;
  final Map<String, double> scores;
  final String? error;

  bool get hasError => error != null;

  factory NsfwScanResult.fromMap(Map<String, dynamic> map) {
    final dynamic rawScores = map['scores'];
    final parsedScores = <String, double>{};

    if (rawScores is Map) {
      for (final entry in rawScores.entries) {
        parsedScores['${entry.key}'] = _toDouble(entry.value);
      }
    }

    return NsfwScanResult(
      imagePath: '${map['imagePath'] ?? ''}',
      nsfwScore: _toDouble(map['nsfwScore']),
      safeScore: _toDouble(map['safeScore']),
      isNsfw: map['isNsfw'] == true,
      topLabel: '${map['topLabel'] ?? ''}',
      topScore: _toDouble(map['topScore']),
      scores: parsedScores,
      error: map['error']?.toString(),
    );
  }

  static double _toDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? 0;
    }
    return 0;
  }
}
