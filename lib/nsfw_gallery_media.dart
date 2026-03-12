import 'nsfw_media_batch.dart';

enum NsfwPickerMode { single, multiple }

class NsfwPickedMedia {
  const NsfwPickedMedia({
    required this.imagePaths,
    required this.videoPaths,
    this.scannedAssets = 0,
  });

  final List<String> imagePaths;
  final List<String> videoPaths;
  final int scannedAssets;

  bool get isEmpty => imagePaths.isEmpty && videoPaths.isEmpty;

  int get totalCount => imagePaths.length + videoPaths.length;

  List<NsfwMediaInput> toMediaInputs() {
    return <NsfwMediaInput>[
      ...imagePaths.map(NsfwMediaInput.image),
      ...videoPaths.map(NsfwMediaInput.video),
    ];
  }
}

class NsfwGalleryLoadProgress {
  const NsfwGalleryLoadProgress({
    required this.page,
    required this.scannedAssets,
    required this.imageCount,
    required this.videoCount,
    this.targetCount,
    this.isCompleted = false,
  });

  final int page;
  final int scannedAssets;
  final int imageCount;
  final int videoCount;
  final int? targetCount;
  final bool isCompleted;

  int get selectedCount => imageCount + videoCount;

  double? get percent {
    final target = targetCount;
    if (target == null || target <= 0) {
      return null;
    }
    return (selectedCount / target).clamp(0.0, 1.0);
  }
}
