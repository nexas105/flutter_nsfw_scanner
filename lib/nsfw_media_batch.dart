import 'nsfw_scan_result.dart';
import 'nsfw_video_scan_result.dart';

enum NsfwMediaType { image, video }

class NsfwMediaInput {
  const NsfwMediaInput.image(this.path) : type = NsfwMediaType.image;

  const NsfwMediaInput.video(this.path) : type = NsfwMediaType.video;

  final String path;
  final NsfwMediaType type;
}

class NsfwMediaBatchSettings {
  const NsfwMediaBatchSettings({
    this.imageThreshold = 0.45,
    this.videoThreshold = 0.45,
    this.videoSampleRateFps = 0.3,
    this.videoMaxFrames = 300,
    this.dynamicVideoSampleRate = true,
    this.shortVideoMinSampleRateFps = 0.5,
    this.shortVideoMaxSampleRateFps = 0.8,
    this.mediumVideoMinutesThreshold = 10,
    this.longVideoMinutesThreshold = 15,
    this.mediumVideoSampleRateFps = 0.3,
    this.longVideoSampleRateFps = 0.2,
    this.videoEarlyStopEnabled = true,
    this.videoEarlyStopBaseNsfwFrames = 3,
    this.videoEarlyStopMediumBonusFrames = 1,
    this.videoEarlyStopLongBonusFrames = 2,
    this.videoEarlyStopVeryLongMinutesThreshold = 30,
    this.videoEarlyStopVeryLongBonusFrames = 3,
    this.maxConcurrency = 2,
    this.continueOnError = true,
  });

  final double imageThreshold;
  final double videoThreshold;
  final double videoSampleRateFps;
  final int videoMaxFrames;
  final bool dynamicVideoSampleRate;
  final double shortVideoMinSampleRateFps;
  final double shortVideoMaxSampleRateFps;
  final int mediumVideoMinutesThreshold;
  final int longVideoMinutesThreshold;
  final double mediumVideoSampleRateFps;
  final double longVideoSampleRateFps;
  final bool videoEarlyStopEnabled;
  final int videoEarlyStopBaseNsfwFrames;
  final int videoEarlyStopMediumBonusFrames;
  final int videoEarlyStopLongBonusFrames;
  final int videoEarlyStopVeryLongMinutesThreshold;
  final int videoEarlyStopVeryLongBonusFrames;
  final int maxConcurrency;
  final bool continueOnError;
}

class NsfwMediaBatchProgress {
  const NsfwMediaBatchProgress({
    required this.processed,
    required this.total,
    required this.percent,
    required this.currentPath,
    required this.currentType,
    this.error,
  });

  final int processed;
  final int total;
  final double percent;
  final String currentPath;
  final NsfwMediaType currentType;
  final String? error;
}

class NsfwMediaBatchItemResult {
  const NsfwMediaBatchItemResult({
    required this.path,
    required this.type,
    this.assetId,
    this.uri,
    this.imageResult,
    this.videoResult,
    this.error,
  });

  final String path;
  final NsfwMediaType type;
  final String? assetId;
  final String? uri;
  final NsfwScanResult? imageResult;
  final NsfwVideoScanResult? videoResult;
  final String? error;

  bool get hasError => error != null;

  bool get isNsfw {
    if (imageResult != null) {
      return imageResult!.isNsfw;
    }
    if (videoResult != null) {
      return videoResult!.isNsfw;
    }
    return false;
  }
}

class NsfwMediaBatchResult {
  const NsfwMediaBatchResult({
    required this.items,
    required this.processed,
    required this.successCount,
    required this.errorCount,
    required this.flaggedCount,
  });

  final List<NsfwMediaBatchItemResult> items;
  final int processed;
  final int successCount;
  final int errorCount;
  final int flaggedCount;
}
