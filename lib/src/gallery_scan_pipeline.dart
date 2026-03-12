import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:photo_manager/photo_manager.dart';

import '../nsfw_gallery_media.dart';
import '../nsfw_media_batch.dart';
import '../nsfw_scan_result.dart';
import '../nsfw_video_scan_result.dart';

typedef ScanMediaChunkCallback =
    Future<NsfwMediaBatchResult> Function({
      required List<NsfwMediaInput> media,
      required NsfwMediaBatchSettings settings,
      void Function(NsfwMediaBatchProgress progress)? onProgress,
    });

class NsfwGalleryScanPipelineConfig {
  const NsfwGalleryScanPipelineConfig({
    this.includeImages = true,
    this.includeVideos = true,
    this.pageSize = 200,
    this.startPage = 0,
    this.maxPages,
    this.maxItems,
    this.scanChunkSize = 80,
    this.preferThumbnailForImages = false,
    this.thumbnailWidth = 320,
    this.thumbnailHeight = 320,
    this.thumbnailQuality = 65,
    this.includeCleanResults = false,
    this.resolveConcurrency = 6,
    this.includeOriginFileFallback = false,
    this.loadProgressEvery = 24,
  });

  final bool includeImages;
  final bool includeVideos;
  final int pageSize;
  final int startPage;
  final int? maxPages;
  final int? maxItems;
  final int scanChunkSize;
  final bool preferThumbnailForImages;
  final int thumbnailWidth;
  final int thumbnailHeight;
  final int thumbnailQuality;
  final bool includeCleanResults;
  final int resolveConcurrency;
  final bool includeOriginFileFallback;
  final int loadProgressEvery;
}

class NsfwGalleryScanPipeline {
  const NsfwGalleryScanPipeline({
    required this.scanMediaChunk,
    required this.config,
  });

  final ScanMediaChunkCallback scanMediaChunk;
  final NsfwGalleryScanPipelineConfig config;

  Future<NsfwMediaBatchResult> scan({
    required NsfwMediaBatchSettings settings,
    void Function(NsfwGalleryLoadProgress progress)? onLoadProgress,
    void Function(NsfwMediaBatchProgress progress)? onScanProgress,
    void Function(NsfwMediaBatchResult chunkResult)? onChunkResult,
  }) async {
    if (!config.includeImages && !config.includeVideos) {
      return const NsfwMediaBatchResult(
        items: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0,
      );
    }

    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      throw const FormatException('Gallery permission not granted.');
    }

    final allAlbums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );
    if (allAlbums.isEmpty) {
      return const NsfwMediaBatchResult(
        items: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0,
      );
    }

    final album = allAlbums.first;
    final totalAssets = await album.assetCountAsync;
    final safePageSize = config.pageSize.clamp(20, 1000);
    final safeChunkSize = config.scanChunkSize.clamp(8, 500);
    final safeResolveConcurrency = config.resolveConcurrency.clamp(1, 24);
    final safeLoadProgressEvery = config.loadProgressEvery.clamp(1, 500);
    final maxItems = config.maxItems;

    final startPage = config.startPage < 0 ? 0 : config.startPage;
    final startIndex = startPage * safePageSize;
    if (startIndex >= totalAssets) {
      return const NsfwMediaBatchResult(
        items: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0,
      );
    }

    final maxPages = config.maxPages;
    final endPageExclusive = maxPages == null || maxPages <= 0
        ? null
        : startPage + maxPages;

    var selectedImageCount = 0;
    var selectedVideoCount = 0;
    var scannedAssets = 0;
    var processedItems = 0;
    var successCount = 0;
    var errorCount = 0;
    var flaggedCount = 0;
    final selectedResults = <NsfwMediaBatchItemResult>[];

    final pendingChunk = <_ResolvedMediaInput>[];
    var page = startPage;
    var start = startIndex;

    void emitLoadProgress({required bool isCompleted}) {
      onLoadProgress?.call(
        NsfwGalleryLoadProgress(
          page: page,
          scannedAssets: scannedAssets,
          imageCount: selectedImageCount,
          videoCount: selectedVideoCount,
          targetCount: maxItems ?? _resolveTargetCount(totalAssets, startIndex),
          isCompleted: isCompleted,
        ),
      );
    }

    Future<void> flushChunk() async {
      if (pendingChunk.isEmpty) {
        return;
      }
      final chunk = List<_ResolvedMediaInput>.from(pendingChunk);
      pendingChunk.clear();

      final aliasMap = <String, String>{
        for (final item in chunk) item.scanPath: item.displayPath,
      };
      final chunkBase = processedItems;

      final chunkResult = await scanMediaChunk(
        media: chunk
            .map(
              (item) => item.type == NsfwMediaType.video
                  ? NsfwMediaInput.video(item.scanPath)
                  : NsfwMediaInput.image(item.scanPath),
            )
            .toList(growable: false),
        settings: settings,
        onProgress: onScanProgress == null
            ? null
            : (progress) {
                final normalizedProcessed = chunkBase + progress.processed;
                final totalForProgress =
                    maxItems ??
                    (chunkBase +
                        chunk.length +
                        math.max(0, pendingChunk.length - progress.processed));
                final percent = totalForProgress <= 0
                    ? 0.0
                    : (normalizedProcessed / totalForProgress).clamp(0.0, 1.0);
                onScanProgress(
                  NsfwMediaBatchProgress(
                    processed: normalizedProcessed,
                    total: totalForProgress,
                    percent: percent,
                    currentPath:
                        aliasMap[progress.currentPath] ?? progress.currentPath,
                    currentType: progress.currentType,
                    error: progress.error,
                  ),
                );
              },
      );

      processedItems += chunkResult.processed;
      successCount += chunkResult.successCount;
      errorCount += chunkResult.errorCount;
      flaggedCount += chunkResult.flaggedCount;

      final chunkSelectedResults = <NsfwMediaBatchItemResult>[];
      for (final item in chunkResult.items) {
        final mapped = _mapItemPaths(item, aliasMap);
        if (!config.includeCleanResults && !mapped.hasError && !mapped.isNsfw) {
          continue;
        }
        selectedResults.add(mapped);
        chunkSelectedResults.add(mapped);
      }

      if (chunkSelectedResults.isNotEmpty) {
        onChunkResult?.call(
          NsfwMediaBatchResult(
            items: chunkSelectedResults,
            processed: chunkResult.processed,
            successCount: chunkResult.successCount,
            errorCount: chunkResult.errorCount,
            flaggedCount: chunkResult.flaggedCount,
          ),
        );
      }

      for (final entry in chunk) {
        await entry.deleteTempFileIfNeeded();
      }
    }

    try {
      while (start < totalAssets) {
        if (endPageExclusive != null && page >= endPageExclusive) {
          break;
        }

        final end = math.min(start + safePageSize, totalAssets);
        final assets = await album.getAssetListRange(start: start, end: end);
        if (assets.isEmpty) {
          break;
        }

        var reachedMaxItems = false;
        var sinceLastLoadProgress = 0;

        for (
          var offset = 0;
          offset < assets.length;
          offset += safeResolveConcurrency
        ) {
          final endOffset = math.min(
            offset + safeResolveConcurrency,
            assets.length,
          );
          final resolveBatch = assets.sublist(offset, endOffset);
          final resolvedBatch = await Future.wait(
            resolveBatch.map(
              (asset) => _resolveAsset(
                asset: asset,
                includeImages: config.includeImages,
                includeVideos: config.includeVideos,
                preferThumbnailForImages: config.preferThumbnailForImages,
                thumbnailWidth: config.thumbnailWidth,
                thumbnailHeight: config.thumbnailHeight,
                thumbnailQuality: config.thumbnailQuality,
                includeOriginFileFallback: config.includeOriginFileFallback,
              ),
            ),
            eagerError: false,
          );

          scannedAssets += resolveBatch.length;
          sinceLastLoadProgress += resolveBatch.length;

          for (final resolved in resolvedBatch) {
            if (resolved == null) {
              continue;
            }
            if (resolved.type == NsfwMediaType.image) {
              selectedImageCount += 1;
            } else {
              selectedVideoCount += 1;
            }
            pendingChunk.add(resolved);

            final selectedCount = selectedImageCount + selectedVideoCount;
            if (maxItems != null && selectedCount >= maxItems) {
              reachedMaxItems = true;
              break;
            }
            if (pendingChunk.length >= safeChunkSize) {
              await flushChunk();
            }
          }

          if (sinceLastLoadProgress >= safeLoadProgressEvery) {
            emitLoadProgress(isCompleted: false);
            sinceLastLoadProgress = 0;
          }

          if (reachedMaxItems) {
            break;
          }
          await Future<void>.delayed(Duration.zero);
        }

        emitLoadProgress(isCompleted: false);

        final selectedCount = selectedImageCount + selectedVideoCount;
        if (maxItems != null && selectedCount >= maxItems) {
          break;
        }

        start += safePageSize;
        page += 1;
        await Future<void>.delayed(Duration.zero);
      }

      await flushChunk();
      emitLoadProgress(isCompleted: true);

      return NsfwMediaBatchResult(
        items: selectedResults,
        processed: processedItems,
        successCount: successCount,
        errorCount: errorCount,
        flaggedCount: flaggedCount,
      );
    } finally {
      for (final item in pendingChunk) {
        await item.deleteTempFileIfNeeded();
      }
    }
  }

  int? _resolveTargetCount(int totalAssets, int startIndex) {
    final maxItems = config.maxItems;
    if (maxItems != null && maxItems > 0) {
      return maxItems;
    }
    final maxPages = config.maxPages;
    if (maxPages == null || maxPages <= 0) {
      return totalAssets - startIndex;
    }
    final pageBudget = maxPages * config.pageSize.clamp(20, 1000);
    return math.max(0, math.min(totalAssets - startIndex, pageBudget));
  }
}

class _ResolvedMediaInput {
  const _ResolvedMediaInput({
    required this.scanPath,
    required this.displayPath,
    required this.type,
    required this.tempFile,
  });

  final String scanPath;
  final String displayPath;
  final NsfwMediaType type;
  final File? tempFile;

  Future<void> deleteTempFileIfNeeded() async {
    final file = tempFile;
    if (file == null) {
      return;
    }
    if (await file.exists()) {
      await file.delete();
    }
  }
}

Future<_ResolvedMediaInput?> _resolveAsset({
  required AssetEntity asset,
  required bool includeImages,
  required bool includeVideos,
  required bool preferThumbnailForImages,
  required int thumbnailWidth,
  required int thumbnailHeight,
  required int thumbnailQuality,
  required bool includeOriginFileFallback,
}) async {
  if (asset.type != AssetType.image && asset.type != AssetType.video) {
    return null;
  }
  if (asset.type == AssetType.image && !includeImages) {
    return null;
  }
  if (asset.type == AssetType.video && !includeVideos) {
    return null;
  }

  if (asset.type == AssetType.image && preferThumbnailForImages) {
    final displayPath =
        await _resolveAssetPath(
          asset,
          includeOriginFileFallback: includeOriginFileFallback,
        ) ??
        'asset://${asset.id}';
    final thumb = await asset.thumbnailDataWithSize(
      ThumbnailSize(
        thumbnailWidth.clamp(96, 1024),
        thumbnailHeight.clamp(96, 1024),
      ),
      quality: thumbnailQuality.clamp(20, 100),
    );
    if (thumb != null && thumb.isNotEmpty) {
      final tempDir = await _thumbnailTempDirectory();
      final safeAssetId = asset.id.replaceAll(RegExp(r'[^a-zA-Z0-9_\-.]'), '_');
      final tempFile = File(
        '${tempDir.path}/thumb_${DateTime.now().microsecondsSinceEpoch}_$safeAssetId.jpg',
      );
      await tempFile.writeAsBytes(thumb, flush: false);
      return _ResolvedMediaInput(
        scanPath: tempFile.path,
        displayPath: displayPath,
        type: NsfwMediaType.image,
        tempFile: tempFile,
      );
    }
  }

  final path = await _resolveAssetPath(
    asset,
    includeOriginFileFallback: includeOriginFileFallback,
  );
  if (path == null || path.isEmpty) {
    return null;
  }

  return _ResolvedMediaInput(
    scanPath: path,
    displayPath: path,
    type: asset.type == AssetType.video
        ? NsfwMediaType.video
        : NsfwMediaType.image,
    tempFile: null,
  );
}

Future<String?> _resolveAssetPath(
  AssetEntity asset, {
  required bool includeOriginFileFallback,
}) async {
  final directPath = (await asset.file)?.path.trim();
  if (directPath != null && directPath.isNotEmpty) {
    return directPath;
  }
  if (!includeOriginFileFallback) {
    return null;
  }
  final originPath = (await asset.originFile)?.path.trim();
  if (originPath == null || originPath.isEmpty) {
    return null;
  }
  return originPath;
}

Future<Directory> _thumbnailTempDirectory() async {
  final directory = Directory(
    '${Directory.systemTemp.path}/flutter_nsfw_scaner',
  );
  if (!directory.existsSync()) {
    await directory.create(recursive: true);
  }
  return directory;
}

NsfwMediaBatchItemResult _mapItemPaths(
  NsfwMediaBatchItemResult item,
  Map<String, String> pathAlias,
) {
  final mappedPath = pathAlias[item.path] ?? item.path;
  final imageResult = item.imageResult;
  final videoResult = item.videoResult;

  return NsfwMediaBatchItemResult(
    path: mappedPath,
    type: item.type,
    imageResult: imageResult == null
        ? null
        : NsfwScanResult(
            imagePath:
                pathAlias[imageResult.imagePath] ?? imageResult.imagePath,
            nsfwScore: imageResult.nsfwScore,
            safeScore: imageResult.safeScore,
            isNsfw: imageResult.isNsfw,
            topLabel: imageResult.topLabel,
            topScore: imageResult.topScore,
            scores: imageResult.scores,
            error: imageResult.error,
          ),
    videoResult: videoResult == null
        ? null
        : NsfwVideoScanResult(
            videoPath:
                pathAlias[videoResult.videoPath] ?? videoResult.videoPath,
            sampleRateFps: videoResult.sampleRateFps,
            sampledFrames: videoResult.sampledFrames,
            flaggedFrames: videoResult.flaggedFrames,
            flaggedRatio: videoResult.flaggedRatio,
            maxNsfwScore: videoResult.maxNsfwScore,
            isNsfw: videoResult.isNsfw,
            frames: videoResult.frames,
          ),
    error: item.error,
  );
}
