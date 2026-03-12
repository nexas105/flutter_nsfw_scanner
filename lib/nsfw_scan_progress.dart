class NsfwScanProgress {
  const NsfwScanProgress({
    required this.scanId,
    required this.processed,
    required this.total,
    required this.percent,
    required this.status,
    this.imagePath,
    this.error,
    this.mediaType,
  });

  final String scanId;
  final int processed;
  final int total;
  final double percent;
  final String status;
  final String? imagePath;
  final String? error;
  final String? mediaType;

  bool get isCompleted => status == 'completed';

  factory NsfwScanProgress.fromMap(Map<String, dynamic> map) {
    return NsfwScanProgress(
      scanId: '${map['scanId'] ?? ''}',
      processed: _toInt(map['processed']),
      total: _toInt(map['total']),
      percent: _toDouble(map['percent']),
      status: '${map['status'] ?? 'running'}',
      imagePath: _toNullableString(map['imagePath']),
      error: _toNullableString(map['error']),
      mediaType: _toNullableString(map['mediaType']),
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

  static String? _toNullableString(dynamic value) {
    if (value == null) {
      return null;
    }
    final asString = value.toString();
    if (asString.isEmpty || asString == 'null') {
      return null;
    }
    return asString;
  }
}
