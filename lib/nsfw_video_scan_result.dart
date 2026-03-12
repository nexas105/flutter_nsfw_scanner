class NsfwVideoFrameResult {
  const NsfwVideoFrameResult({
    required this.timestampMs,
    required this.nsfwScore,
    required this.safeScore,
    required this.isNsfw,
    required this.topLabel,
    required this.topScore,
    required this.scores,
    this.error,
  });

  final double timestampMs;
  final double nsfwScore;
  final double safeScore;
  final bool isNsfw;
  final String topLabel;
  final double topScore;
  final Map<String, double> scores;
  final String? error;

  bool get hasError => error != null;

  factory NsfwVideoFrameResult.fromMap(Map<String, dynamic> map) {
    final rawScores = map['scores'];
    final parsedScores = <String, double>{};

    if (rawScores is Map) {
      for (final entry in rawScores.entries) {
        parsedScores['${entry.key}'] = _toDouble(entry.value);
      }
    }

    return NsfwVideoFrameResult(
      timestampMs: _toDouble(map['timestampMs']),
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

class NsfwVideoScanResult {
  const NsfwVideoScanResult({
    required this.videoPath,
    required this.sampleRateFps,
    required this.sampledFrames,
    required this.flaggedFrames,
    required this.flaggedRatio,
    required this.maxNsfwScore,
    required this.isNsfw,
    required this.frames,
  });

  final String videoPath;
  final double sampleRateFps;
  final int sampledFrames;
  final int flaggedFrames;
  final double flaggedRatio;
  final double maxNsfwScore;
  final bool isNsfw;
  final List<NsfwVideoFrameResult> frames;

  factory NsfwVideoScanResult.fromMap(Map<String, dynamic> map) {
    final rawFrames = map['frames'];
    final frames = <NsfwVideoFrameResult>[];

    if (rawFrames is List) {
      for (final item in rawFrames) {
        if (item is Map) {
          final frameMap = <String, dynamic>{};
          for (final entry in item.entries) {
            frameMap['${entry.key}'] = entry.value;
          }
          frames.add(NsfwVideoFrameResult.fromMap(frameMap));
        }
      }
    }

    return NsfwVideoScanResult(
      videoPath: '${map['videoPath'] ?? ''}',
      sampleRateFps: _toDouble(map['sampleRateFps']),
      sampledFrames: _toInt(map['sampledFrames']),
      flaggedFrames: _toInt(map['flaggedFrames']),
      flaggedRatio: _toDouble(map['flaggedRatio']),
      maxNsfwScore: _toDouble(map['maxNsfwScore']),
      isNsfw: map['isNsfw'] == true,
      frames: frames,
    );
  }

  static int _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is double) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
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
