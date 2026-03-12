import 'nsfw_media_batch.dart';

class NsfwAssetRef {
  const NsfwAssetRef({
    required this.id,
    required this.type,
    required this.width,
    required this.height,
    required this.durationSeconds,
    required this.createDateSecond,
    required this.modifiedDateSecond,
  });

  final String id;
  final NsfwMediaType type;
  final int width;
  final int height;
  final int durationSeconds;
  final int createDateSecond;
  final int modifiedDateSecond;

  bool get isImage => type == NsfwMediaType.image;
  bool get isVideo => type == NsfwMediaType.video;
}

class NsfwLoadedAsset {
  const NsfwLoadedAsset({required this.path, required this.type, this.id});

  final String path;
  final NsfwMediaType type;
  final String? id;

  NsfwMediaInput toMediaInput() {
    return type == NsfwMediaType.video
        ? NsfwMediaInput.video(path)
        : NsfwMediaInput.image(path);
  }
}

class NsfwAssetPage {
  const NsfwAssetPage({
    required this.items,
    required this.totalAssets,
    required this.start,
    required this.end,
  });

  final List<NsfwAssetRef> items;
  final int totalAssets;
  final int start;
  final int end;

  bool get hasMore => end < totalAssets;
}
