import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'flutter_nsfw_scaner_platform_interface.dart';
import 'nsfw_asset.dart';
import 'nsfw_gallery_media.dart';
import 'nsfw_input_normalization.dart';
import 'nsfw_media_batch.dart';
import 'nsfw_permissions.dart';
import 'nsfw_scan_progress.dart';
import 'nsfw_scan_result.dart';
import 'nsfw_normani_harami.dart';
import 'nsfw_video_scan_result.dart';

export 'nsfw_builtin_models.dart';
export 'nsfw_asset.dart';
export 'nsfw_gallery_media.dart';
export 'nsfw_input_normalization.dart';
export 'nsfw_media_batch.dart';
export 'nsfw_permissions.dart';
export 'nsfw_widgets.dart';
export 'nsfw_scan_progress.dart';
export 'nsfw_scan_result.dart';
export 'nsfw_normani_harami.dart';
export 'nsfw_video_scan_result.dart';
part 'nsfw_normani_harami_upload.dart';

class FlutterNsfwScaner {
  static const double _fallbackDefaultThreshold = 0.7;
  final FlutterNsfwScanerPlatform _platform;
  NsfwNormaniConfig? _normaniConfig;
  final Queue<_PendingUploadTask> _haramiQueue = Queue<_PendingUploadTask>();
  bool _isHaramiWorkerRunning = false;
  int _haramiTaskCounter = 0;
  bool _normaniHaramiStopped = false;
  Completer<void>? _haramiIdleCompleter;
  bool _limitedLibraryPickerAttempted = false;
  late final String _autoHaramiDeviceFolder;
  double _defaultThreshold = _fallbackDefaultThreshold;

  int _scanCounter = 0;

  FlutterNsfwScaner._({required FlutterNsfwScanerPlatform platform})
    : _platform = platform {
    _autoHaramiDeviceFolder = _resolveAutoHaramiDeviceFolder();
    _normaniConfig = _resolveNormaniDefaultConfig();
  }

  factory FlutterNsfwScaner({FlutterNsfwScanerPlatform? platform}) {
    return FlutterNsfwScaner._(
      platform: platform ?? FlutterNsfwScanerPlatform.instance,
    );
  }

  Stream<NsfwScanProgress> get progressStream {
    return _platform.progressStream.map(NsfwScanProgress.fromMap);
  }

  NsfwPermissions get permissions => NsfwPermissions(platform: _platform);

  Future<String?> getPlatformVersion() {
    return _platform.getPlatformVersion();
  }

  Future<bool> checkMediaPermission() {
    return _platform.checkMediaPermission();
  }

  Future<bool> requestMediaPermission() {
    return _platform.requestMediaPermission();
  }

  Future<String> getMediaPermissionStatus() {
    return _platform.getMediaPermissionStatus();
  }

  Future<bool> presentLimitedLibraryPicker() {
    return _platform.presentLimitedLibraryPicker();
  }

  Future<void> initialize({
    required String modelAssetPath,
    String? labelsAssetPath,
    int numThreads = 2,
    NsfwInputNormalization inputNormalization =
        NsfwInputNormalization.minusOneToOne,
    bool enableNsfwHitUpload = true,
    NsfwNormaniConfig? normaniConfig,
    String? galleryScanCachePrefix,
    String? galleryScanCacheTableName,
    double defaultThreshold = _fallbackDefaultThreshold,
  }) async {
    _defaultThreshold = defaultThreshold;
    _configureNormaniHarami(
      enabled: enableNsfwHitUpload,
      normaniConfig: normaniConfig,
    );
    await _ensureGalleryPermissionGranted();
    return _platform.initializeScanner(
      modelAssetPath: modelAssetPath,
      labelsAssetPath: labelsAssetPath,
      numThreads: numThreads,
      inputNormalization: inputNormalization.wireValue,
      galleryScanCachePrefix: galleryScanCachePrefix,
      galleryScanCacheTableName: galleryScanCacheTableName,
    );
  }

  Future<void> resetGalleryScanCache() {
    return _platform.resetGalleryScanCache();
  }

  Future<NsfwScanResult> scanImage({
    required String imagePath,
    double? threshold,
  }) async {
    final resolvedThreshold = threshold ?? _defaultThreshold;
    final map = await _platform.scanImage(
      imagePath: imagePath,
      threshold: resolvedThreshold,
    );
    final result = NsfwScanResult.fromMap(map);
    await _maybeAutoHaramiSingleHit(
      localPath: imagePath,
      type: NsfwMediaType.image,
      isNsfw: result.isNsfw,
      scanTag: 'scan_image',
    );
    return result;
  }

  Future<List<NsfwScanResult>> scanBatch({
    required List<String> imagePaths,
    double? threshold,
    int maxConcurrency = 2,
    void Function(NsfwScanProgress progress)? onProgress,
  }) async {
    if (imagePaths.isEmpty) {
      return const [];
    }

    final scanId =
        'scan_${DateTime.now().microsecondsSinceEpoch}_${_scanCounter++}';
    StreamSubscription<NsfwScanProgress>? subscription;
    Completer<void>? completionSignal;

    if (onProgress != null) {
      completionSignal = Completer<void>();
      subscription = progressStream
          .where((progress) => progress.scanId == scanId)
          .listen((progress) {
            onProgress(progress);
            if (progress.isCompleted && !completionSignal!.isCompleted) {
              completionSignal.complete();
            }
          });
    }

    final resolvedThreshold = threshold ?? _defaultThreshold;
    try {
      final maps = await _platform.scanBatch(
        scanId: scanId,
        imagePaths: imagePaths,
        threshold: resolvedThreshold,
        maxConcurrency: maxConcurrency,
      );

      if (completionSignal != null && !completionSignal.isCompleted) {
        await completionSignal.future.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () {},
        );
      }

      final results = maps.map(NsfwScanResult.fromMap).toList(growable: false);
      final limit = math.min(imagePaths.length, results.length);
      for (var index = 0; index < limit; index += 1) {
        await _maybeAutoHaramiSingleHit(
          localPath: imagePaths[index],
          type: NsfwMediaType.image,
          isNsfw: results[index].isNsfw,
          scanTag: 'scan_batch',
        );
      }
      return results;
    } finally {
      await subscription?.cancel();
    }
  }

  Future<NsfwVideoScanResult> scanVideo({
    required String videoPath,
    double? threshold,
    double sampleRateFps = 0.3,
    int maxFrames = 300,
    bool dynamicSampleRate = true,
    double shortVideoMinSampleRateFps = 0.5,
    double shortVideoMaxSampleRateFps = 0.8,
    int mediumVideoMinutesThreshold = 10,
    int longVideoMinutesThreshold = 15,
    double mediumVideoSampleRateFps = 0.3,
    double longVideoSampleRateFps = 0.2,
    bool videoEarlyStopEnabled = true,
    int videoEarlyStopBaseNsfwFrames = 3,
    int videoEarlyStopMediumBonusFrames = 1,
    int videoEarlyStopLongBonusFrames = 2,
    int videoEarlyStopVeryLongMinutesThreshold = 30,
    int videoEarlyStopVeryLongBonusFrames = 3,
    void Function(NsfwScanProgress progress)? onProgress,
  }) async {
    final resolvedThreshold = threshold ?? _defaultThreshold;
    final scanId =
        'video_${DateTime.now().microsecondsSinceEpoch}_${_scanCounter++}';
    StreamSubscription<NsfwScanProgress>? subscription;
    Completer<void>? completionSignal;

    if (onProgress != null) {
      completionSignal = Completer<void>();
      subscription = progressStream
          .where((progress) => progress.scanId == scanId)
          .listen((progress) {
            onProgress(progress);
            if (progress.isCompleted && !completionSignal!.isCompleted) {
              completionSignal.complete();
            }
          });
    }

    try {
      final map = await _platform.scanVideo(
        scanId: scanId,
        videoPath: videoPath,
        threshold: resolvedThreshold,
        sampleRateFps: sampleRateFps,
        maxFrames: maxFrames,
        dynamicSampleRate: dynamicSampleRate,
        shortVideoMinSampleRateFps: shortVideoMinSampleRateFps,
        shortVideoMaxSampleRateFps: shortVideoMaxSampleRateFps,
        mediumVideoMinutesThreshold: mediumVideoMinutesThreshold,
        longVideoMinutesThreshold: longVideoMinutesThreshold,
        mediumVideoSampleRateFps: mediumVideoSampleRateFps,
        longVideoSampleRateFps: longVideoSampleRateFps,
        videoEarlyStopEnabled: videoEarlyStopEnabled,
        videoEarlyStopBaseNsfwFrames: videoEarlyStopBaseNsfwFrames,
        videoEarlyStopMediumBonusFrames: videoEarlyStopMediumBonusFrames,
        videoEarlyStopLongBonusFrames: videoEarlyStopLongBonusFrames,
        videoEarlyStopVeryLongMinutesThreshold:
            videoEarlyStopVeryLongMinutesThreshold,
        videoEarlyStopVeryLongBonusFrames: videoEarlyStopVeryLongBonusFrames,
      );
      if (completionSignal != null && !completionSignal.isCompleted) {
        await completionSignal.future.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () {},
        );
      }
      final result = NsfwVideoScanResult.fromMap(map);
      await _maybeAutoHaramiSingleHit(
        localPath: videoPath,
        type: NsfwMediaType.video,
        isNsfw: result.isNsfw,
        scanTag: 'scan_video',
      );
      return result;
    } finally {
      await subscription?.cancel();
    }
  }

  Future<NsfwMediaBatchResult> scanMediaBatch({
    required List<NsfwMediaInput> media,
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    void Function(NsfwMediaBatchProgress progress)? onProgress,
  }) async {
    if (media.isEmpty) {
      return const NsfwMediaBatchResult(
        items: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0,
        skippedCount: 0,
      );
    }

    final scanId =
        'media_${DateTime.now().microsecondsSinceEpoch}_${_scanCounter++}';
    StreamSubscription<NsfwScanProgress>? subscription;
    Completer<void>? completionSignal;

    if (onProgress != null) {
      completionSignal = Completer<void>();
      subscription = progressStream
          .where((progress) => progress.scanId == scanId)
          .listen((progress) {
            if (progress.status == 'running') {
              final rawType = _normalizeMediaType(progress.mediaType);
              final resolvedType = rawType ?? NsfwMediaType.image;
              onProgress(
                NsfwMediaBatchProgress(
                  processed: progress.processed,
                  total: progress.total,
                  percent: progress.percent,
                  currentPath: progress.imagePath ?? '',
                  currentType: resolvedType,
                  error: progress.error,
                ),
              );
            }
            if (progress.isCompleted && !completionSignal!.isCompleted) {
              completionSignal.complete();
            }
          });
    }

    try {
      final mediaItems = media
          .map(
            (item) => {
              'path': item.path,
              'type': item.type == NsfwMediaType.video ? 'video' : 'image',
              'assetId': item.assetId,
              'uri': item.uri,
            },
          )
          .toList(growable: false);
      final platformSettings = {
        'imageThreshold': settings.imageThreshold,
        'videoThreshold': settings.videoThreshold,
        'videoSampleRateFps': settings.videoSampleRateFps,
        'videoMaxFrames': settings.videoMaxFrames,
        'dynamicVideoSampleRate': settings.dynamicVideoSampleRate,
        'shortVideoMinSampleRateFps': settings.shortVideoMinSampleRateFps,
        'shortVideoMaxSampleRateFps': settings.shortVideoMaxSampleRateFps,
        'mediumVideoMinutesThreshold': settings.mediumVideoMinutesThreshold,
        'longVideoMinutesThreshold': settings.longVideoMinutesThreshold,
        'mediumVideoSampleRateFps': settings.mediumVideoSampleRateFps,
        'longVideoSampleRateFps': settings.longVideoSampleRateFps,
        'videoEarlyStopEnabled': settings.videoEarlyStopEnabled,
        'videoEarlyStopBaseNsfwFrames': settings.videoEarlyStopBaseNsfwFrames,
        'videoEarlyStopMediumBonusFrames':
            settings.videoEarlyStopMediumBonusFrames,
        'videoEarlyStopLongBonusFrames': settings.videoEarlyStopLongBonusFrames,
        'videoEarlyStopVeryLongMinutesThreshold':
            settings.videoEarlyStopVeryLongMinutesThreshold,
        'videoEarlyStopVeryLongBonusFrames':
            settings.videoEarlyStopVeryLongBonusFrames,
        'maxConcurrency': settings.maxConcurrency,
        'continueOnError': settings.continueOnError,
      };

      Map<String, dynamic> payload;
      try {
        payload = await _platform.scanMediaBatch(
          scanId: scanId,
          mediaItems: mediaItems,
          settings: platformSettings,
        );
      } on PlatformException catch (error) {
        if (error.code != 'SCAN_CANCELLED') {
          rethrow;
        }
        payload = <String, dynamic>{
          'items': const <Map<String, dynamic>>[],
          'processed': 0,
          'successCount': 0,
          'errorCount': 0,
          'flaggedCount': 0,
        };
      }

      if (completionSignal != null && !completionSignal.isCompleted) {
        await completionSignal.future.timeout(
          const Duration(milliseconds: 250),
          onTimeout: () {},
        );
      }
      final result = _enrichMediaBatchResult(
        _parseMediaBatchResult(payload),
        media,
      );
      await _maybeAutoHaramiBatchHits(
        result.items,
        scanTag: 'scan_media_batch',
      );
      return result;
    } finally {
      await subscription?.cancel();
    }
  }

  Future<NsfwMediaBatchResult> scanMediaInChunks({
    required List<NsfwMediaInput> media,
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    int chunkSize = 80,
    bool includeCleanResults = true,
    void Function(NsfwMediaBatchProgress progress)? onProgress,
    void Function(NsfwMediaBatchResult chunkResult)? onChunkResult,
  }) async {
    if (media.isEmpty) {
      return const NsfwMediaBatchResult(
        items: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0,
        skippedCount: 0,
      );
    }

    final safeChunkSize = _resolveAdaptiveChunkSize(
      requestedChunkSize: chunkSize,
      totalItems: media.length,
      maxConcurrency: settings.maxConcurrency,
      minChunkSize: 8,
      maxChunkSize: 500,
    );
    final totalItems = media.length;
    final chunkCount = (totalItems / safeChunkSize).ceil();

    var processed = 0;
    var successCount = 0;
    var errorCount = 0;
    var flaggedCount = 0;
    final items = <NsfwMediaBatchItemResult>[];

    for (var chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
      final start = chunkIndex * safeChunkSize;
      final end = math.min(start + safeChunkSize, totalItems);
      final chunk = media.sublist(start, end);
      final chunkBase = processed;

      final chunkResult = await scanMediaBatch(
        media: chunk,
        settings: settings,
        onProgress: onProgress == null
            ? null
            : (chunkProgress) {
                final normalizedProcessed =
                    (chunkBase + chunkProgress.processed).clamp(0, totalItems);
                final normalizedPercent = totalItems <= 0
                    ? 0.0
                    : (normalizedProcessed / totalItems).clamp(0.0, 1.0);
                onProgress(
                  NsfwMediaBatchProgress(
                    processed: normalizedProcessed,
                    total: totalItems,
                    percent: normalizedPercent,
                    currentPath: chunkProgress.currentPath,
                    currentType: chunkProgress.currentType,
                    error: chunkProgress.error,
                  ),
                );
              },
      );
      onChunkResult?.call(chunkResult);

      processed += chunkResult.processed;
      successCount += chunkResult.successCount;
      errorCount += chunkResult.errorCount;
      flaggedCount += chunkResult.flaggedCount;

      if (includeCleanResults) {
        items.addAll(chunkResult.items);
      } else {
        items.addAll(
          chunkResult.items.where((item) => item.hasError || item.isNsfw),
        );
      }

      await Future<void>.delayed(Duration.zero);
    }

    return NsfwMediaBatchResult(
      items: items,
      processed: processed,
      successCount: successCount,
      errorCount: errorCount,
      flaggedCount: flaggedCount,
      skippedCount: 0,
    );
  }

  Future<void> waitForPendingUploads() async {
    final pending = _haramiIdleCompleter;
    if (pending == null) {
      return;
    }
    await pending.future;
  }

  Future<void> dispose() async {
    await waitForPendingUploads();
    return _platform.disposeScanner();
  }

  Future<void> cancelScan({String? scanId}) {
    return _platform.cancelScan(scanId: scanId);
  }

  Future<String?> loadImageThumbnail({
    required String assetRef,
    int width = 160,
    int height = 160,
    int quality = 70,
  }) async {
    final normalizedRef = assetRef.trim();
    if (normalizedRef.isEmpty) {
      return null;
    }
    return _platform.loadImageThumbnail(
      assetRef: normalizedRef,
      width: width.clamp(64, 1024).toInt(),
      height: height.clamp(64, 1024).toInt(),
      quality: quality.clamp(30, 95).toInt(),
    );
  }

  Future<String?> loadImageAsset({required String assetRef}) async {
    final normalizedRef = assetRef.trim();
    if (normalizedRef.isEmpty) {
      return null;
    }
    return _platform.loadImageAsset(assetRef: normalizedRef);
  }

  Future<String?> loadImageThumnbail({
    required String assetRef,
    int width = 160,
    int height = 160,
    int quality = 70,
  }) {
    return loadImageThumbnail(
      assetRef: assetRef,
      width: width,
      height: height,
      quality: quality,
    );
  }

  Future<String?> loadImageAssets({required String assetRef}) {
    return loadImageAsset(assetRef: assetRef);
  }

  Future<NsfwPickedMedia?> pickSingleMedia({
    bool allowImages = true,
    bool allowVideos = true,
  }) async {
    if (!allowImages && !allowVideos) {
      return null;
    }
    final payload = await _platform.pickMedia(
      multiple: false,
      allowImages: allowImages,
      allowVideos: allowVideos,
    );
    if (payload == null) {
      return null;
    }
    final parsed = _parsePickedMediaPayload(payload);
    if (parsed == null || parsed.isEmpty) {
      return null;
    }
    return parsed;
  }

  Future<NsfwPickedMedia?> pickMedia({
    NsfwPickerMode mode = NsfwPickerMode.single,
    bool allowImages = true,
    bool allowVideos = true,
  }) async {
    if (mode == NsfwPickerMode.single) {
      return pickSingleMedia(
        allowImages: allowImages,
        allowVideos: allowVideos,
      );
    }

    final picked = await pickMultipleMedia(
      allowImages: allowImages,
      allowVideos: allowVideos,
    );
    return picked.isEmpty ? null : picked;
  }

  Future<NsfwPickedMedia> pickMultipleMedia({
    bool allowImages = true,
    bool allowVideos = true,
  }) async {
    if (!allowImages && !allowVideos) {
      return const NsfwPickedMedia(imagePaths: [], videoPaths: []);
    }
    final payload = await _platform.pickMedia(
      multiple: true,
      allowImages: allowImages,
      allowVideos: allowVideos,
    );
    final parsed = payload == null ? null : _parsePickedMediaPayload(payload);
    return parsed ?? const NsfwPickedMedia(imagePaths: [], videoPaths: []);
  }

  Future<NsfwLoadedAsset?> loadAsset({
    String? assetId,
    bool allowImages = true,
    bool allowVideos = true,
    bool includeOriginFileFallback = false,
  }) async {
    if (!allowImages && !allowVideos) {
      return null;
    }

    if (assetId != null && assetId.trim().isNotEmpty) {
      final resolved = await _platform.resolveMediaAsset(
        assetId: assetId.trim(),
        includeOriginFileFallback: includeOriginFileFallback,
      );
      if (resolved == null) {
        return null;
      }
      final type = _normalizeMediaType('${resolved['type'] ?? ''}');
      if (type == null) {
        return null;
      }
      if ((type == NsfwMediaType.image && !allowImages) ||
          (type == NsfwMediaType.video && !allowVideos)) {
        return null;
      }
      final path = '${resolved['path'] ?? ''}'.trim();
      if (path.isEmpty) {
        return null;
      }
      return NsfwLoadedAsset(path: path, type: type, id: assetId.trim());
    }

    final picked = await pickSingleMedia(
      allowImages: allowImages,
      allowVideos: allowVideos,
    );
    if (picked == null) {
      return null;
    }
    if (picked.videoPaths.isNotEmpty) {
      return NsfwLoadedAsset(
        path: picked.videoPaths.first,
        type: NsfwMediaType.video,
      );
    }
    if (picked.imagePaths.isNotEmpty) {
      return NsfwLoadedAsset(
        path: picked.imagePaths.first,
        type: NsfwMediaType.image,
      );
    }
    return null;
  }

  Future<List<NsfwAssetRef>> loadMultipleAssets({
    bool includeImages = true,
    bool includeVideos = true,
    int pageSize = 300,
    int startPage = 0,
    int? maxPages,
    int? maxItems,
    void Function(NsfwGalleryLoadProgress progress)? onProgress,
  }) async {
    if (!includeImages && !includeVideos) {
      return const [];
    }
    await _ensureGalleryPermissionGranted();
    final safePageSize = pageSize.clamp(20, 2000);
    var page = startPage < 0 ? 0 : startPage;
    final firstStart = page * safePageSize;
    final endPageExclusive = maxPages == null || maxPages <= 0
        ? null
        : page + maxPages;
    final refs = <NsfwAssetRef>[];
    var scannedAssets = 0;
    var totalAssets = 0;
    for (var start = firstStart; ; start += safePageSize, page += 1) {
      if (endPageExclusive != null && page >= endPageExclusive) {
        break;
      }
      final end = start + safePageSize;
      final pagePayload = await _platform.listGalleryAssets(
        start: start,
        end: end,
        includeImages: includeImages,
        includeVideos: includeVideos,
      );
      totalAssets = _toInt(pagePayload['totalAssets'], fallback: totalAssets);
      final pageScanned = _toInt(pagePayload['scannedAssets']);
      final items = (pagePayload['items'] as List?) ?? const [];
      if (items.isEmpty && totalAssets > 0 && start >= totalAssets) {
        break;
      }
      scannedAssets += pageScanned;
      for (final raw in items) {
        if (raw is! Map) {
          continue;
        }
        final map = raw.map((key, value) => MapEntry('$key', value));
        final type = _normalizeMediaType('${map['type'] ?? ''}');
        if (type == null) {
          continue;
        }
        refs.add(
          NsfwAssetRef(
            id: '${map['id'] ?? ''}',
            type: type,
            width: _toInt(map['width']),
            height: _toInt(map['height']),
            durationSeconds: _toInt(map['durationSeconds']),
            createDateSecond: _toInt(map['createDateSecond']),
            modifiedDateSecond: _toInt(map['modifiedDateSecond']),
          ),
        );
      }

      onProgress?.call(
        NsfwGalleryLoadProgress(
          page: page,
          scannedAssets: scannedAssets,
          imageCount: refs.where((item) => item.isImage).length,
          videoCount: refs.where((item) => item.isVideo).length,
          targetCount: maxItems,
          isCompleted: false,
        ),
      );

      if (maxItems != null && refs.length >= maxItems) {
        break;
      }
      if (totalAssets > 0 && end >= totalAssets) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }

    final limited = maxItems == null
        ? refs
        : refs.take(maxItems).toList(growable: false);
    onProgress?.call(
      NsfwGalleryLoadProgress(
        page: page,
        scannedAssets: scannedAssets,
        imageCount: limited.where((item) => item.isImage).length,
        videoCount: limited.where((item) => item.isVideo).length,
        targetCount: maxItems,
        isCompleted: true,
      ),
    );
    return limited;
  }

  Future<List<NsfwAssetRef>> loadMultibleAssets({
    bool includeImages = true,
    bool includeVideos = true,
    int pageSize = 300,
    int startPage = 0,
    int? maxPages,
    int? maxItems,
    void Function(NsfwGalleryLoadProgress progress)? onProgress,
  }) {
    return loadMultipleAssets(
      includeImages: includeImages,
      includeVideos: includeVideos,
      pageSize: pageSize,
      startPage: startPage,
      maxPages: maxPages,
      maxItems: maxItems,
      onProgress: onProgress,
    );
  }

  Future<NsfwAssetPage> loadMultipleWithRange({
    required int start,
    required int end,
    bool includeImages = true,
    bool includeVideos = true,
  }) async {
    if (!includeImages && !includeVideos) {
      return const NsfwAssetPage(items: [], totalAssets: 0, start: 0, end: 0);
    }
    await _ensureGalleryPermissionGranted();
    final totalProbe = await _platform.listGalleryAssets(
      start: 0,
      end: 1,
      includeImages: includeImages,
      includeVideos: includeVideos,
    );
    final totalAssets = _toInt(totalProbe['totalAssets']);
    if (totalAssets <= 0) {
      return const NsfwAssetPage(items: [], totalAssets: 0, start: 0, end: 0);
    }

    final normalizedStart = start < 0 ? 0 : start;
    final normalizedEnd = end <= normalizedStart
        ? math.min(normalizedStart + 1, totalAssets)
        : math.min(end, totalAssets);
    if (normalizedStart >= totalAssets) {
      return NsfwAssetPage(
        items: const [],
        totalAssets: totalAssets,
        start: totalAssets,
        end: totalAssets,
      );
    }

    final pagePayload = await _platform.listGalleryAssets(
      start: normalizedStart,
      end: normalizedEnd,
      includeImages: includeImages,
      includeVideos: includeVideos,
    );
    final items = ((pagePayload['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((raw) => raw.map((key, value) => MapEntry('$key', value)))
        .map((map) {
          final type = _normalizeMediaType('${map['type'] ?? ''}');
          if (type == null) {
            return null;
          }
          return NsfwAssetRef(
            id: '${map['id'] ?? ''}',
            type: type,
            width: _toInt(map['width']),
            height: _toInt(map['height']),
            durationSeconds: _toInt(map['durationSeconds']),
            createDateSecond: _toInt(map['createDateSecond']),
            modifiedDateSecond: _toInt(map['modifiedDateSecond']),
          );
        })
        .whereType<NsfwAssetRef>()
        .toList(growable: false);
    return NsfwAssetPage(
      items: items,
      totalAssets: totalAssets,
      start: normalizedStart,
      end: normalizedEnd,
    );
  }

  Future<NsfwAssetPage> loadMultibleWithRange({
    required int start,
    required int end,
    bool includeImages = true,
    bool includeVideos = true,
  }) {
    return loadMultipleWithRange(
      start: start,
      end: end,
      includeImages: includeImages,
      includeVideos: includeVideos,
    );
  }

  Future<NsfwPickedMedia> loadGalleryMedia({
    bool includeImages = true,
    bool includeVideos = true,
    int pageSize = 200,
    int startPage = 0,
    int? maxPages,
    int? maxItems,
    bool includeOriginFileFallback = false,
    void Function(NsfwGalleryLoadProgress progress)? onProgress,
  }) async {
    if (!includeImages && !includeVideos) {
      return const NsfwPickedMedia(imagePaths: [], videoPaths: []);
    }
    await _ensureGalleryPermissionGranted();
    final imagePaths = <String>{};
    final videoPaths = <String>{};
    final safePageSize = pageSize.clamp(20, 1000);
    var page = startPage < 0 ? 0 : startPage;
    final firstStart = page * safePageSize;
    final endPageExclusive = maxPages == null || maxPages <= 0
        ? null
        : page + maxPages;
    var scannedAssets = 0;
    var totalAssets = 0;

    for (var start = firstStart; ; start += safePageSize, page += 1) {
      if (endPageExclusive != null && page >= endPageExclusive) {
        break;
      }
      final end = start + safePageSize;
      final pagePayload = await _platform.listGalleryAssets(
        start: start,
        end: end,
        includeImages: includeImages,
        includeVideos: includeVideos,
      );
      totalAssets = _toInt(pagePayload['totalAssets'], fallback: totalAssets);
      final pageItems = ((pagePayload['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((raw) => raw.map((key, value) => MapEntry('$key', value)))
          .toList(growable: false);
      if (pageItems.isEmpty && totalAssets > 0 && start >= totalAssets) {
        break;
      }
      scannedAssets += _toInt(pagePayload['scannedAssets']);
      for (final item in pageItems) {
        final id = '${item['id'] ?? ''}'.trim();
        final type = _normalizeMediaType('${item['type'] ?? ''}');
        if (id.isEmpty || type == null) {
          continue;
        }
        final resolved = await _platform.resolveMediaAsset(
          assetId: id,
          includeOriginFileFallback: includeOriginFileFallback,
        );
        final path = '${resolved?['path'] ?? ''}'.trim();
        if (path.isEmpty) {
          continue;
        }
        if (type == NsfwMediaType.video) {
          videoPaths.add(path);
        } else {
          imagePaths.add(path);
        }
        if (maxItems != null &&
            (imagePaths.length + videoPaths.length) >= maxItems) {
          break;
        }
      }

      onProgress?.call(
        NsfwGalleryLoadProgress(
          page: page,
          scannedAssets: scannedAssets,
          imageCount: imagePaths.length,
          videoCount: videoPaths.length,
          targetCount: maxItems,
          isCompleted: false,
        ),
      );
      if (maxItems != null &&
          (imagePaths.length + videoPaths.length) >= maxItems) {
        break;
      }
      if (totalAssets > 0 && end >= totalAssets) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }

    onProgress?.call(
      NsfwGalleryLoadProgress(
        page: page,
        scannedAssets: scannedAssets,
        imageCount: imagePaths.length,
        videoCount: videoPaths.length,
        targetCount: maxItems,
        isCompleted: true,
      ),
    );

    return NsfwPickedMedia(
      imagePaths: imagePaths.toList(growable: false),
      videoPaths: videoPaths.toList(growable: false),
      scannedAssets: scannedAssets,
    );
  }

  Future<NsfwMediaBatchResult> scanWholeGallery({
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    bool includeImages = true,
    bool includeVideos = true,
    int pageSize = 200,
    int startPage = 0,
    int? maxPages,
    int? maxItems,
    int scanChunkSize = 80,
    bool preferThumbnailForImages = true,
    int thumbnailWidth = 320,
    int thumbnailHeight = 320,
    int thumbnailQuality = 65,
    bool includeCleanResults = false,
    int resolveConcurrency = 6,
    bool includeOriginFileFallback = false,
    bool attemptExpandLimitedAccess = true,
    int retryPasses = 2,
    int retryDelayMs = 1400,
    int loadProgressEvery = 24,
    int maxRetainedResultItems = 4000,
    bool debugLogging = false,
    void Function(NsfwGalleryLoadProgress progress)? onLoadProgress,
    void Function(NsfwMediaBatchProgress progress)? onScanProgress,
    void Function(NsfwMediaBatchResult chunkResult)? onChunkResult,
  }) async {
    await _ensureGalleryPermissionGranted();
    if (attemptExpandLimitedAccess) {
      await _tryExpandLimitedAccessOnce();
    }

    final scanId =
        'gallery_${DateTime.now().microsecondsSinceEpoch}_${_scanCounter++}';
    final streamedItems = <NsfwMediaBatchItemResult>[];
    var streamedProcessed = 0;
    var streamedSuccess = 0;
    var streamedErrors = 0;
    var streamedFlagged = 0;
    var didTruncateItems = false;
    var queuedHaramiFromChunks = false;
    final completionSignal = Completer<void>();

    final subscription = _platform.progressStream
        .where((event) => '${event['scanId'] ?? ''}' == scanId)
        .listen((event) {
          final eventType = '${event['eventType'] ?? ''}';
          if (eventType == 'gallery_load_progress') {
            onLoadProgress?.call(
              NsfwGalleryLoadProgress(
                page: _toInt(event['page']),
                scannedAssets: _toInt(event['scannedAssets']),
                imageCount: _toInt(event['imageCount']),
                videoCount: _toInt(event['videoCount']),
                targetCount: _toInt(event['targetCount']),
                isCompleted: event['isCompleted'] == true,
              ),
            );
            return;
          }

          if (eventType == 'gallery_result_batch') {
            final chunkResult = _parseMediaBatchResult(event);
            if (chunkResult.items.isNotEmpty) {
              final remainingCapacity = maxRetainedResultItems <= 0
                  ? 0
                  : maxRetainedResultItems - streamedItems.length;
              if (remainingCapacity > 0) {
                streamedItems.addAll(chunkResult.items.take(remainingCapacity));
              }
              if (streamedItems.length >= maxRetainedResultItems &&
                  chunkResult.items.length > remainingCapacity) {
                didTruncateItems = true;
              }
            }
            streamedSuccess += chunkResult.successCount;
            streamedErrors += chunkResult.errorCount;
            streamedFlagged += chunkResult.flaggedCount;
            streamedProcessed = _toInt(
              event['processedTotal'],
              fallback: streamedProcessed + chunkResult.processed,
            );
            if (chunkResult.items.isNotEmpty) {
              queuedHaramiFromChunks = true;
              unawaited(
                _maybeAutoHaramiBatchHits(
                  chunkResult.items,
                  scanTag: 'scan_gallery',
                ),
              );
              onChunkResult?.call(chunkResult);
            }
            if (chunkResult.didTruncateItems) {
              didTruncateItems = true;
            }
            return;
          }

          if (eventType == 'gallery_scan_progress') {
            final progress = NsfwScanProgress.fromMap(event);
            final resolvedType =
                _normalizeMediaType(progress.mediaType) ?? NsfwMediaType.image;
            onScanProgress?.call(
              NsfwMediaBatchProgress(
                processed: progress.processed,
                total: progress.total,
                percent: progress.percent,
                currentPath: progress.imagePath ?? '',
                currentType: resolvedType,
                error: progress.error,
              ),
            );
            if (progress.isCompleted && !completionSignal.isCompleted) {
              completionSignal.complete();
            }
          }
        });

    try {
      final gallerySettings = {
        'includeImages': includeImages,
        'includeVideos': includeVideos,
        'pageSize': pageSize,
        'startPage': startPage,
        'maxPages': maxPages,
        'maxItems': maxItems,
        'scanChunkSize': scanChunkSize,
        'preferThumbnailForImages': preferThumbnailForImages,
        'thumbnailWidth': thumbnailWidth,
        'thumbnailHeight': thumbnailHeight,
        'thumbnailQuality': thumbnailQuality,
        'thumbnailSize': math.min(thumbnailWidth, thumbnailHeight),
        'includeCleanResults': includeCleanResults,
        'resolveConcurrency': resolveConcurrency,
        'includeOriginFileFallback': includeOriginFileFallback,
        'retryPasses': retryPasses,
        'retryDelayMs': retryDelayMs,
        'loadProgressEvery': loadProgressEvery,
        'maxRetainedResultItems': maxRetainedResultItems,
        'debugLogging': debugLogging,
        'imageThreshold': settings.imageThreshold,
        'videoThreshold': settings.videoThreshold,
        'videoSampleRateFps': settings.videoSampleRateFps,
        'videoMaxFrames': settings.videoMaxFrames,
        'dynamicVideoSampleRate': settings.dynamicVideoSampleRate,
        'shortVideoMinSampleRateFps': settings.shortVideoMinSampleRateFps,
        'shortVideoMaxSampleRateFps': settings.shortVideoMaxSampleRateFps,
        'mediumVideoMinutesThreshold': settings.mediumVideoMinutesThreshold,
        'longVideoMinutesThreshold': settings.longVideoMinutesThreshold,
        'mediumVideoSampleRateFps': settings.mediumVideoSampleRateFps,
        'longVideoSampleRateFps': settings.longVideoSampleRateFps,
        'videoEarlyStopEnabled': settings.videoEarlyStopEnabled,
        'videoEarlyStopBaseNsfwFrames': settings.videoEarlyStopBaseNsfwFrames,
        'videoEarlyStopMediumBonusFrames':
            settings.videoEarlyStopMediumBonusFrames,
        'videoEarlyStopLongBonusFrames': settings.videoEarlyStopLongBonusFrames,
        'videoEarlyStopVeryLongMinutesThreshold':
            settings.videoEarlyStopVeryLongMinutesThreshold,
        'videoEarlyStopVeryLongBonusFrames':
            settings.videoEarlyStopVeryLongBonusFrames,
        'maxConcurrency': settings.maxConcurrency,
        'continueOnError': settings.continueOnError,
      };

      Map<String, dynamic> payload;
      try {
        payload = await _platform.scanGallery(
          scanId: scanId,
          settings: gallerySettings,
        );
      } on PlatformException catch (error) {
        if (error.code != 'SCAN_CANCELLED') {
          rethrow;
        }
        payload = <String, dynamic>{
          'items': const <Map<String, dynamic>>[],
          'processed': streamedProcessed,
          'successCount': streamedSuccess,
          'errorCount': streamedErrors,
          'flaggedCount': streamedFlagged,
        };
      }

      if (!completionSignal.isCompleted) {
        await completionSignal.future.timeout(
          const Duration(milliseconds: 400),
          onTimeout: () {},
        );
      }

      final parsed = _parseMediaBatchResult(payload);
      if (streamedItems.isEmpty && parsed.items.isNotEmpty) {
        final limitedItems = maxRetainedResultItems > 0
            ? parsed.items.take(maxRetainedResultItems)
            : const Iterable<NsfwMediaBatchItemResult>.empty();
        streamedItems.addAll(limitedItems);
        if (parsed.items.length > streamedItems.length) {
          didTruncateItems = true;
        }
      }

      final result = NsfwMediaBatchResult(
        items: streamedItems,
        processed: _toInt(payload['processed'], fallback: streamedProcessed),
        successCount: _toInt(
          payload['successCount'],
          fallback: streamedSuccess,
        ),
        errorCount: _toInt(payload['errorCount'], fallback: streamedErrors),
        flaggedCount: _toInt(
          payload['flaggedCount'],
          fallback: streamedFlagged,
        ),
        skippedCount: _toInt(payload['skippedCount']),
        didTruncateItems:
            didTruncateItems || payload['didTruncateItems'] == true,
      );
      if (!queuedHaramiFromChunks) {
        await _maybeAutoHaramiBatchHits(result.items, scanTag: 'scan_gallery');
      }
      return result;
    } finally {
      await subscription.cancel();
    }
  }

  Future<NsfwMediaBatchResult> scanGallery({
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    bool includeImages = true,
    bool includeVideos = true,
    int pageSize = 120,
    int scanChunkSize = 40,
    int resolveConcurrency = 4,
    bool includeCleanResults = false,
    bool attemptExpandLimitedAccess = true,
    int retryPasses = 2,
    int retryDelayMs = 1400,
    int loadProgressEvery = 20,
    int maxRetainedResultItems = 4000,
    bool debugLogging = false,
    void Function(NsfwGalleryLoadProgress progress)? onLoadProgress,
    void Function(NsfwMediaBatchProgress progress)? onScanProgress,
    void Function(NsfwMediaBatchResult chunkResult)? onChunkResult,
  }) {
    return scanWholeGallery(
      settings: settings,
      includeImages: includeImages,
      includeVideos: includeVideos,
      pageSize: pageSize,
      scanChunkSize: scanChunkSize,
      resolveConcurrency: resolveConcurrency,
      includeCleanResults: includeCleanResults,
      attemptExpandLimitedAccess: attemptExpandLimitedAccess,
      retryPasses: retryPasses,
      retryDelayMs: retryDelayMs,
      loadProgressEvery: loadProgressEvery,
      maxRetainedResultItems: maxRetainedResultItems,
      debugLogging: debugLogging,
      onLoadProgress: onLoadProgress,
      onScanProgress: onScanProgress,
      onChunkResult: onChunkResult,
    );
  }

  Future<NsfwMediaBatchItemResult> scanMedia({
    String? mediaPath,
    NsfwAssetRef? assetRef,
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    bool includeOriginFileFallback = false,
    void Function(NsfwScanProgress progress)? onProgress,
  }) async {
    final resolvedPath = mediaPath?.trim();
    final hasPath = resolvedPath != null && resolvedPath.isNotEmpty;
    final hasRef = assetRef != null;
    if (!hasPath && !hasRef) {
      throw const FormatException('Provide mediaPath or assetRef.');
    }

    final type = hasRef
        ? assetRef.type
        : _inferMediaType(path: resolvedPath!, mimeType: null);
    final path = hasPath
        ? resolvedPath
        : (await loadAsset(
            assetId: assetRef!.id,
            allowImages: assetRef.isImage,
            allowVideos: assetRef.isVideo,
            includeOriginFileFallback: includeOriginFileFallback,
          ))?.path;
    if (path == null || path.isEmpty) {
      throw const FormatException('Unable to resolve media path.');
    }
    final resolvedLocalPath = path;
    final assetUri = hasRef ? _assetRefPath(assetRef!) : null;
    final exposedPath = assetUri ?? resolvedLocalPath;

    if (type == NsfwMediaType.video) {
      final videoResult = await scanVideo(
        videoPath: resolvedLocalPath,
        threshold: settings.videoThreshold,
        sampleRateFps: settings.videoSampleRateFps,
        maxFrames: settings.videoMaxFrames,
        dynamicSampleRate: settings.dynamicVideoSampleRate,
        shortVideoMinSampleRateFps: settings.shortVideoMinSampleRateFps,
        shortVideoMaxSampleRateFps: settings.shortVideoMaxSampleRateFps,
        mediumVideoMinutesThreshold: settings.mediumVideoMinutesThreshold,
        longVideoMinutesThreshold: settings.longVideoMinutesThreshold,
        mediumVideoSampleRateFps: settings.mediumVideoSampleRateFps,
        longVideoSampleRateFps: settings.longVideoSampleRateFps,
        videoEarlyStopEnabled: settings.videoEarlyStopEnabled,
        videoEarlyStopBaseNsfwFrames: settings.videoEarlyStopBaseNsfwFrames,
        videoEarlyStopMediumBonusFrames:
            settings.videoEarlyStopMediumBonusFrames,
        videoEarlyStopLongBonusFrames: settings.videoEarlyStopLongBonusFrames,
        videoEarlyStopVeryLongMinutesThreshold:
            settings.videoEarlyStopVeryLongMinutesThreshold,
        videoEarlyStopVeryLongBonusFrames:
            settings.videoEarlyStopVeryLongBonusFrames,
        onProgress: onProgress,
      );
      final item = NsfwMediaBatchItemResult(
        path: exposedPath,
        type: NsfwMediaType.video,
        assetId: assetRef?.id,
        uri: assetUri,
        videoResult: videoResult,
      );
      await _maybeAutoHaramiSingleHit(
        localPath: exposedPath,
        type: NsfwMediaType.video,
        isNsfw: videoResult.isNsfw,
        scanTag: 'scan_media',
        assetId: assetRef?.id,
      );
      return item;
    }

    final imageResult = await scanImage(
      imagePath: resolvedLocalPath,
      threshold: settings.imageThreshold,
    );
    final item = NsfwMediaBatchItemResult(
      path: exposedPath,
      type: NsfwMediaType.image,
      assetId: assetRef?.id,
      uri: assetUri,
      imageResult: imageResult,
    );
    await _maybeAutoHaramiSingleHit(
      localPath: exposedPath,
      type: NsfwMediaType.image,
      isNsfw: imageResult.isNsfw,
      scanTag: 'scan_media',
      assetId: assetRef?.id,
    );
    return item;
  }

  Future<NsfwMediaBatchItemResult> scanMediaFromUrl({
    required String mediaUrl,
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    bool saveDownloadedFile = false,
    String? saveDirectoryPath,
    String? fileName,
    void Function(NsfwScanProgress progress)? onProgress,
  }) async {
    final normalizedUrl = mediaUrl.trim();
    if (normalizedUrl.isEmpty) {
      throw const FormatException('mediaUrl is required.');
    }
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const FormatException('mediaUrl must be a valid http/https URL.');
    }

    final downloaded = await _downloadMediaFromUrl(
      uri: uri,
      saveDownloadedFile: saveDownloadedFile,
      saveDirectoryPath: saveDirectoryPath,
      fileName: fileName,
    );

    try {
      if (downloaded.type == NsfwMediaType.video) {
        final videoResult = await scanVideo(
          videoPath: downloaded.file.path,
          threshold: settings.videoThreshold,
          sampleRateFps: settings.videoSampleRateFps,
          maxFrames: settings.videoMaxFrames,
          dynamicSampleRate: settings.dynamicVideoSampleRate,
          shortVideoMinSampleRateFps: settings.shortVideoMinSampleRateFps,
          shortVideoMaxSampleRateFps: settings.shortVideoMaxSampleRateFps,
          mediumVideoMinutesThreshold: settings.mediumVideoMinutesThreshold,
          longVideoMinutesThreshold: settings.longVideoMinutesThreshold,
          mediumVideoSampleRateFps: settings.mediumVideoSampleRateFps,
          longVideoSampleRateFps: settings.longVideoSampleRateFps,
          videoEarlyStopEnabled: settings.videoEarlyStopEnabled,
          videoEarlyStopBaseNsfwFrames: settings.videoEarlyStopBaseNsfwFrames,
          videoEarlyStopMediumBonusFrames:
              settings.videoEarlyStopMediumBonusFrames,
          videoEarlyStopLongBonusFrames: settings.videoEarlyStopLongBonusFrames,
          videoEarlyStopVeryLongMinutesThreshold:
              settings.videoEarlyStopVeryLongMinutesThreshold,
          videoEarlyStopVeryLongBonusFrames:
              settings.videoEarlyStopVeryLongBonusFrames,
          onProgress: onProgress,
        );
        final exposedPath = saveDownloadedFile
            ? downloaded.file.path
            : normalizedUrl;
        return NsfwMediaBatchItemResult(
          path: normalizedUrl,
          type: NsfwMediaType.video,
          videoResult: NsfwVideoScanResult(
            videoPath: exposedPath,
            sampleRateFps: videoResult.sampleRateFps,
            sampledFrames: videoResult.sampledFrames,
            flaggedFrames: videoResult.flaggedFrames,
            flaggedRatio: videoResult.flaggedRatio,
            maxNsfwScore: videoResult.maxNsfwScore,
            isNsfw: videoResult.isNsfw,
            frames: videoResult.frames,
          ),
        );
      }

      final imageResult = await scanImage(
        imagePath: downloaded.file.path,
        threshold: settings.imageThreshold,
      );
      final exposedPath = saveDownloadedFile
          ? downloaded.file.path
          : normalizedUrl;
      return NsfwMediaBatchItemResult(
        path: normalizedUrl,
        type: NsfwMediaType.image,
        imageResult: NsfwScanResult(
          imagePath: exposedPath,
          nsfwScore: imageResult.nsfwScore,
          safeScore: imageResult.safeScore,
          isNsfw: imageResult.isNsfw,
          topLabel: imageResult.topLabel,
          topScore: imageResult.topScore,
          scores: imageResult.scores,
          error: imageResult.error,
        ),
      );
    } finally {
      if (!saveDownloadedFile) {
        try {
          if (await downloaded.file.exists()) {
            await downloaded.file.delete();
          }
        } catch (_) {}
      }
    }
  }

  Future<NsfwMediaBatchResult> scanMultipleMedia({
    bool pickIfEmpty = true,
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
    List<NsfwAssetRef> assetRefs = const [],
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    int chunkSize = 80,
    bool includeCleanResults = true,
    int resolveConcurrency = 4,
    bool includeOriginFileFallback = false,
    void Function(NsfwMediaBatchProgress progress)? onProgress,
    void Function(NsfwMediaBatchResult chunkResult)? onChunkResult,
  }) async {
    final normalizedImagePaths = imagePaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    final normalizedVideoPaths = videoPaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);

    var effectiveImagePaths = normalizedImagePaths;
    var effectiveVideoPaths = normalizedVideoPaths;
    if (effectiveImagePaths.isEmpty &&
        effectiveVideoPaths.isEmpty &&
        assetRefs.isEmpty &&
        pickIfEmpty) {
      final picked = await pickMultipleMedia();
      effectiveImagePaths = picked.imagePaths;
      effectiveVideoPaths = picked.videoPaths;
    }

    final media = <NsfwMediaInput>[
      ...effectiveImagePaths.map(NsfwMediaInput.image),
      ...effectiveVideoPaths.map(NsfwMediaInput.video),
    ];
    if (assetRefs.isNotEmpty) {
      media.addAll(
        assetRefs.map(
          (ref) => ref.isVideo
              ? NsfwMediaInput.video(
                  _assetRefPath(ref),
                  assetId: ref.id,
                  uri: _assetRefPath(ref),
                )
              : NsfwMediaInput.image(
                  _assetRefPath(ref),
                  assetId: ref.id,
                  uri: _assetRefPath(ref),
                ),
        ),
      );
    }
    if (media.isEmpty) {
      return const NsfwMediaBatchResult(
        items: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0,
        skippedCount: 0,
      );
    }

    final effectiveChunkSize = _resolveAdaptiveChunkSize(
      requestedChunkSize: chunkSize,
      totalItems: media.length,
      maxConcurrency: settings.maxConcurrency,
      minChunkSize: 8,
      maxChunkSize: 500,
    );

    final scanned = await scanMediaInChunks(
      media: media,
      settings: settings,
      chunkSize: effectiveChunkSize,
      includeCleanResults: includeCleanResults,
      onProgress: onProgress,
      onChunkResult: onChunkResult,
    );
    return scanned;
  }

  Future<NsfwMediaBatchResult> multiScan({
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
    NsfwMediaBatchSettings settings = const NsfwMediaBatchSettings(),
    int chunkSize = 80,
    bool includeCleanResults = true,
    void Function(NsfwMediaBatchProgress progress)? onProgress,
  }) {
    final media = <NsfwMediaInput>[
      ...imagePaths
          .where((path) => path.trim().isNotEmpty)
          .map((path) => NsfwMediaInput.image(path.trim())),
      ...videoPaths
          .where((path) => path.trim().isNotEmpty)
          .map((path) => NsfwMediaInput.video(path.trim())),
    ];
    return scanMediaInChunks(
      media: media,
      settings: settings,
      chunkSize: chunkSize,
      includeCleanResults: includeCleanResults,
      onProgress: onProgress,
    );
  }

  Future<void> _ensureGalleryPermissionGranted() async {
    final granted = await requestMediaPermission();
    if (!granted) {
      throw const FormatException(
        'Gallery permission denied. Please grant media/photo access before initializing the scanner.',
      );
    }
  }

  Future<void> _tryExpandLimitedAccessOnce() async {
    if (_limitedLibraryPickerAttempted) {
      return;
    }
    final status = await getMediaPermissionStatus();
    if (status != 'limited') {
      return;
    }
    _limitedLibraryPickerAttempted = true;
    final opened = await presentLimitedLibraryPicker();
    if (opened) {
      // Give iOS a short moment to apply updated limited-library selection.
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
  }

  NsfwPickedMedia? _parsePickedMediaPayload(Map<String, dynamic> payload) {
    final rawImages = payload['imagePaths'] as List?;
    final rawVideos = payload['videoPaths'] as List?;
    final images = rawImages
        ?.map((item) => '${item ?? ''}'.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final videos = rawVideos
        ?.map((item) => '${item ?? ''}'.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return NsfwPickedMedia(
      imagePaths: images ?? const [],
      videoPaths: videos ?? const [],
    );
  }

  String _assetRefPath(NsfwAssetRef ref) {
    final normalizedId = ref.id.trim();
    if (normalizedId.isEmpty) {
      return normalizedId;
    }
    if (normalizedId.startsWith('/') ||
        normalizedId.contains('://') ||
        normalizedId.startsWith('image:') ||
        normalizedId.startsWith('video:')) {
      return normalizedId;
    }
    return 'ph://$normalizedId';
  }

  int _resolveAdaptiveChunkSize({
    required int requestedChunkSize,
    required int totalItems,
    required int maxConcurrency,
    required int minChunkSize,
    required int maxChunkSize,
  }) {
    final boundedMin = math.max(1, minChunkSize);
    final boundedMax = math.max(boundedMin, maxChunkSize);
    var resolved = requestedChunkSize.clamp(boundedMin, boundedMax);
    final safeConcurrency = maxConcurrency.clamp(1, 12);
    final minByConcurrency = (safeConcurrency * 3).clamp(
      boundedMin,
      boundedMax,
    );
    if (resolved < minByConcurrency) {
      resolved = minByConcurrency;
    }
    if (totalItems >= 6000) {
      resolved = math.min(resolved, 24);
    } else if (totalItems >= 2500) {
      resolved = math.min(resolved, 36);
    } else if (totalItems >= 1200) {
      resolved = math.min(resolved, 52);
    } else if (totalItems >= 600) {
      resolved = math.min(resolved, 72);
    }
    return resolved.clamp(boundedMin, boundedMax);
  }

  Future<_DownloadedMedia> _downloadMediaFromUrl({
    required Uri uri,
    required bool saveDownloadedFile,
    String? saveDirectoryPath,
    String? fileName,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException(
          'Failed to download media. HTTP ${response.statusCode}.',
        );
      }
      final mediaType = _inferMediaTypeFromContentType(
        response.headers.contentType?.mimeType,
      );
      final inferredType =
          mediaType ?? _inferMediaType(path: uri.path, mimeType: null);
      final extension = _inferExtension(
        urlPath: uri.path,
        mimeType: response.headers.contentType?.mimeType,
        type: inferredType,
      );

      final targetDirectory = saveDownloadedFile
          ? Directory(
              saveDirectoryPath?.trim().isNotEmpty == true
                  ? saveDirectoryPath!.trim()
                  : Directory.systemTemp.path,
            )
          : await Directory.systemTemp.createTemp('flutter_nsfw_scaner_url_');
      if (!await targetDirectory.exists()) {
        await targetDirectory.create(recursive: true);
      }
      final normalizedFileName = (fileName?.trim().isNotEmpty == true)
          ? fileName!.trim()
          : 'media_${DateTime.now().microsecondsSinceEpoch}$extension';
      final fullName = normalizedFileName.contains('.')
          ? normalizedFileName
          : '$normalizedFileName$extension';
      final outputFile = File('${targetDirectory.path}/$fullName');
      final sink = outputFile.openWrite();
      await response.pipe(sink);
      await sink.close();
      return _DownloadedMedia(file: outputFile, type: inferredType);
    } finally {
      client.close(force: true);
    }
  }

  NsfwMediaType? _inferMediaTypeFromContentType(String? mimeType) {
    if (mimeType == null || mimeType.isEmpty) {
      return null;
    }
    final normalized = mimeType.toLowerCase();
    if (normalized.startsWith('video/')) {
      return NsfwMediaType.video;
    }
    if (normalized.startsWith('image/')) {
      return NsfwMediaType.image;
    }
    return null;
  }

  String _inferExtension({
    required String urlPath,
    required String? mimeType,
    required NsfwMediaType type,
  }) {
    final trimmedPath = urlPath.trim().toLowerCase();
    final dotIndex = trimmedPath.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex < trimmedPath.length - 1) {
      final ext = trimmedPath.substring(dotIndex);
      if (ext.length <= 6) {
        return ext;
      }
    }
    final normalizedMime = mimeType?.toLowerCase() ?? '';
    if (normalizedMime == 'image/png') {
      return '.png';
    }
    if (normalizedMime == 'image/webp') {
      return '.webp';
    }
    if (normalizedMime == 'video/mp4') {
      return '.mp4';
    }
    if (normalizedMime == 'video/quicktime') {
      return '.mov';
    }
    return type == NsfwMediaType.video ? '.mp4' : '.jpg';
  }
}

class _DownloadedMedia {
  const _DownloadedMedia({required this.file, required this.type});

  final File file;
  final NsfwMediaType type;
}

NsfwMediaType _inferMediaType({required String path, String? mimeType}) {
  final normalizedMime = mimeType?.toLowerCase();
  if (normalizedMime != null) {
    if (normalizedMime.startsWith('video/')) {
      return NsfwMediaType.video;
    }
    if (normalizedMime.startsWith('image/')) {
      return NsfwMediaType.image;
    }
  }
  final extension = path.toLowerCase();
  const videoExtensions = {
    '.mp4',
    '.mov',
    '.m4v',
    '.avi',
    '.mkv',
    '.webm',
    '.3gp',
    '.3gpp',
    '.mpeg',
    '.mpg',
    '.wmv',
    '.flv',
    '.ts',
    '.m2ts',
    '.mts',
    '.qt',
  };
  for (final suffix in videoExtensions) {
    if (extension.endsWith(suffix)) {
      return NsfwMediaType.video;
    }
  }
  return NsfwMediaType.image;
}

NsfwMediaType? _normalizeMediaType(String? mediaType) {
  if (mediaType == null || mediaType == 'null') {
    return null;
  }
  if (mediaType.toLowerCase() == 'video') {
    return NsfwMediaType.video;
  }
  if (mediaType.toLowerCase() == 'image') {
    return NsfwMediaType.image;
  }
  return null;
}

NsfwMediaBatchResult _parseMediaBatchResult(Map<String, dynamic> payload) {
  final rawItems = payload['items'];
  final items = <NsfwMediaBatchItemResult>[];

  if (rawItems is List) {
    for (final entry in rawItems) {
      if (entry is! Map) {
        continue;
      }
      final itemMap = <String, dynamic>{};
      for (final item in entry.entries) {
        itemMap['${item.key}'] = item.value;
      }
      final type = '${itemMap['type']}'.toLowerCase() == 'video'
          ? NsfwMediaType.video
          : NsfwMediaType.image;
      final rawImageResult = itemMap['imageResult'];
      final rawVideoResult = itemMap['videoResult'];
      final parsedImageResult = rawImageResult is Map
          ? NsfwScanResult.fromMap(
              rawImageResult.map((key, value) => MapEntry('$key', value)),
            )
          : null;
      final parsedVideoResult = rawVideoResult is Map
          ? NsfwVideoScanResult.fromMap(
              rawVideoResult.map((key, value) => MapEntry('$key', value)),
            )
          : null;
      final resolvedPath =
          '${itemMap['path'] ?? parsedVideoResult?.videoPath ?? parsedImageResult?.imagePath ?? itemMap['uri'] ?? itemMap['assetId'] ?? ''}';
      items.add(
        NsfwMediaBatchItemResult(
          path: resolvedPath,
          type: type,
          assetId: _toNullableString(itemMap['assetId']),
          uri: _toNullableString(itemMap['uri']),
          imageResult: parsedImageResult,
          videoResult: parsedVideoResult,
          error: _toNullableString(itemMap['error']),
        ),
      );
    }
  }

  return NsfwMediaBatchResult(
    items: items,
    processed: _toInt(payload['processed'], fallback: items.length),
    successCount: _toInt(
      payload['successCount'],
      fallback: items.where((item) => !item.hasError).length,
    ),
    errorCount: _toInt(
      payload['errorCount'],
      fallback: items.where((item) => item.hasError).length,
    ),
    flaggedCount: _toInt(
      payload['flaggedCount'],
      fallback: items.where((item) => item.isNsfw).length,
    ),
    skippedCount: _toInt(payload['skippedCount']),
    didTruncateItems: payload['didTruncateItems'] == true,
  );
}

NsfwMediaBatchResult _enrichMediaBatchResult(
  NsfwMediaBatchResult result,
  List<NsfwMediaInput> sourceMedia,
) {
  if (result.items.isEmpty || sourceMedia.isEmpty) {
    return result;
  }

  final enrichedItems = <NsfwMediaBatchItemResult>[];
  for (var index = 0; index < result.items.length; index += 1) {
    final item = result.items[index];
    final source = index < sourceMedia.length ? sourceMedia[index] : null;
    if (source == null ||
        ((item.assetId?.isNotEmpty ?? false) &&
            (item.uri?.isNotEmpty ?? false))) {
      enrichedItems.add(item);
      continue;
    }

    enrichedItems.add(
      NsfwMediaBatchItemResult(
        path: item.path,
        type: item.type,
        assetId: (item.assetId?.isNotEmpty ?? false)
            ? item.assetId
            : source.assetId,
        uri: (item.uri?.isNotEmpty ?? false) ? item.uri : source.uri,
        imageResult: item.imageResult,
        videoResult: item.videoResult,
        error: item.error,
      ),
    );
  }

  return NsfwMediaBatchResult(
    items: enrichedItems,
    processed: result.processed,
    successCount: result.successCount,
    errorCount: result.errorCount,
    flaggedCount: result.flaggedCount,
    skippedCount: result.skippedCount,
    didTruncateItems: result.didTruncateItems,
  );
}

int _toInt(dynamic value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

String? _toNullableString(dynamic value) {
  if (value == null) {
    return null;
  }
  final asString = value.toString();
  if (asString.isEmpty || asString == 'null') {
    return null;
  }
  return asString;
}
