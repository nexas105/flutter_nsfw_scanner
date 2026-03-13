import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

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
  final FlutterNsfwScanerPlatform _platform;
  static final ImagePicker _imagePicker = ImagePicker();
  NsfwNormaniConfig? _normaniConfig;
  final Queue<_PendingUploadTask> _haramiQueue = Queue<_PendingUploadTask>();
  bool _isHaramiWorkerRunning = false;
  int _haramiTaskCounter = 0;
  bool _normaniHaramiStopped = false;
  bool _limitedLibraryPickerAttempted = false;
  late final String _autoHaramiDeviceFolder;

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
  }) async {
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
    );
  }

  Future<NsfwScanResult> scanImage({
    required String imagePath,
    double threshold = 0.8,
  }) async {
    final map = await _platform.scanImage(
      imagePath: imagePath,
      threshold: threshold,
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
    double threshold = 0.8,
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

    try {
      final maps = await _platform.scanBatch(
        scanId: scanId,
        imagePaths: imagePaths,
        threshold: threshold,
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
    double threshold = 0.8,
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
        threshold: threshold,
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
      final result = _parseMediaBatchResult(payload);
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
    );
  }

  Future<void> dispose() {
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
    try {
      XFile? picked;
      if (allowImages && allowVideos) {
        picked = await _imagePicker.pickMedia();
      } else if (allowVideos) {
        picked = await _imagePicker.pickVideo(source: ImageSource.gallery);
      } else {
        picked = await _imagePicker.pickImage(source: ImageSource.gallery);
      }
      final pickedPath = picked?.path.trim() ?? '';
      if (pickedPath.isNotEmpty) {
        final type = _inferMediaType(path: pickedPath, mimeType: picked?.mimeType);
        return type == NsfwMediaType.video
            ? NsfwPickedMedia(imagePaths: const [], videoPaths: [pickedPath])
            : NsfwPickedMedia(imagePaths: [pickedPath], videoPaths: const []);
      }
    } catch (_) {}

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
    try {
      final imagePaths = <String>{};
      final videoPaths = <String>{};
      if (allowImages && !allowVideos) {
        final picked = await _imagePicker.pickMultiImage();
        for (final item in picked) {
          final path = item.path.trim();
          if (path.isNotEmpty) {
            imagePaths.add(path);
          }
        }
      } else if (allowImages && allowVideos) {
        final picked = await _imagePicker.pickMultipleMedia();
        for (final item in picked) {
          final path = item.path.trim();
          if (path.isEmpty) {
            continue;
          }
          final type = _inferMediaType(path: path, mimeType: item.mimeType);
          if (type == NsfwMediaType.video) {
            videoPaths.add(path);
          } else {
            imagePaths.add(path);
          }
        }
      }
      if (imagePaths.isNotEmpty || videoPaths.isNotEmpty) {
        return NsfwPickedMedia(
          imagePaths: imagePaths.toList(growable: false),
          videoPaths: videoPaths.toList(growable: false),
        );
      }
    } catch (_) {}

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
      try {
        final resolved = await _loadAssetViaPhotoManager(
          assetId: assetId.trim(),
          allowImages: allowImages,
          allowVideos: allowVideos,
          includeOriginFileFallback: includeOriginFileFallback,
        );
        if (resolved != null) {
          return resolved;
        }
      } catch (_) {}
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
    try {
      final photoManagerRefs = await _loadMultipleAssetsViaPhotoManager(
        includeImages: includeImages,
        includeVideos: includeVideos,
        pageSize: pageSize,
        startPage: startPage,
        maxPages: maxPages,
        maxItems: maxItems,
        onProgress: onProgress,
      );
      return photoManagerRefs;
    } catch (_) {}

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
    try {
      final requestType = _toPhotoManagerRequestType(
        includeImages: includeImages,
        includeVideos: includeVideos,
      );
      await _ensurePhotoManagerPermissionGranted();
      final root = await _resolvePhotoManagerPrimaryPath(requestType);
      if (root != null) {
        final totalAssets = await root.assetCountAsync;
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
        final rawItems = await root.getAssetListRange(
          start: normalizedStart,
          end: normalizedEnd,
        );
        final items = rawItems
            .map(_assetEntityToRef)
            .whereType<NsfwAssetRef>()
            .toList(growable: false);
        return NsfwAssetPage(
          items: items,
          totalAssets: totalAssets,
          start: normalizedStart,
          end: normalizedEnd,
        );
      }
    } catch (_) {}

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
    try {
      final requestType = _toPhotoManagerRequestType(
        includeImages: includeImages,
        includeVideos: includeVideos,
      );
      await _ensurePhotoManagerPermissionGranted();
      final root = await _resolvePhotoManagerPrimaryPath(requestType);
      if (root != null) {
        final totalAssets = await root.assetCountAsync;
        final imagePaths = <String>{};
        final videoPaths = <String>{};
        final safePageSize = pageSize.clamp(20, 1000);
        var page = startPage < 0 ? 0 : startPage;
        final endPageExclusive = maxPages == null || maxPages <= 0
            ? null
            : page + maxPages;
        var scannedAssets = 0;
        while (true) {
          if (endPageExclusive != null && page >= endPageExclusive) {
            break;
          }
          final pageItems = await root.getAssetListPaged(
            page: page,
            size: safePageSize,
          );
          if (pageItems.isEmpty) {
            break;
          }
          scannedAssets += pageItems.length;
          for (final asset in pageItems) {
            final type = _toNsfwMediaType(asset.type);
            if (type == null) {
              continue;
            }
            final resolvedPath = await _resolveAssetEntityPathForScan(
              asset,
              includeOriginFileFallback: includeOriginFileFallback,
            );
            if (resolvedPath == null || resolvedPath.isEmpty) {
              continue;
            }
            if (type == NsfwMediaType.video) {
              videoPaths.add(resolvedPath);
            } else {
              imagePaths.add(resolvedPath);
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
          if (scannedAssets >= totalAssets) {
            break;
          }
          page += 1;
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
    } catch (_) {}

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
    bool debugLogging = false,
    void Function(NsfwGalleryLoadProgress progress)? onLoadProgress,
    void Function(NsfwMediaBatchProgress progress)? onScanProgress,
    void Function(NsfwMediaBatchResult chunkResult)? onChunkResult,
  }) async {
    if (attemptExpandLimitedAccess) {
      await _tryExpandLimitedAccessOnce();
    }
    try {
      final refs = await loadMultipleAssets(
        includeImages: includeImages,
        includeVideos: includeVideos,
        pageSize: pageSize,
        startPage: startPage,
        maxPages: maxPages,
        maxItems: maxItems,
        onProgress: onLoadProgress,
      );
      if (refs.isNotEmpty) {
        return scanMultipleMedia(
          pickIfEmpty: false,
          assetRefs: refs,
          settings: settings,
          chunkSize: scanChunkSize,
          includeCleanResults: includeCleanResults,
          resolveConcurrency: resolveConcurrency,
          includeOriginFileFallback: includeOriginFileFallback,
          resolveRetryPasses: retryPasses,
          resolveRetryDelayMs: retryDelayMs,
          onProgress: onScanProgress,
          onChunkResult: onChunkResult,
        );
      }
    } catch (_) {
      // Fall back to native gallery scan when provider-based loading fails.
    }

    return _scanWholeGalleryViaNative(
      settings: settings,
      includeImages: includeImages,
      includeVideos: includeVideos,
      pageSize: pageSize,
      startPage: startPage,
      maxPages: maxPages,
      maxItems: maxItems,
      scanChunkSize: scanChunkSize,
      preferThumbnailForImages: preferThumbnailForImages,
      thumbnailWidth: thumbnailWidth,
      thumbnailHeight: thumbnailHeight,
      thumbnailQuality: thumbnailQuality,
      includeCleanResults: includeCleanResults,
      resolveConcurrency: resolveConcurrency,
      includeOriginFileFallback: includeOriginFileFallback,
      retryPasses: retryPasses,
      retryDelayMs: retryDelayMs,
      loadProgressEvery: loadProgressEvery,
      debugLogging: debugLogging,
      onLoadProgress: onLoadProgress,
      onScanProgress: onScanProgress,
      onChunkResult: onChunkResult,
    );
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
      debugLogging: debugLogging,
      onLoadProgress: onLoadProgress,
      onScanProgress: onScanProgress,
      onChunkResult: onChunkResult,
    );
  }

  Future<NsfwMediaBatchResult> _scanWholeGalleryViaNative({
    required NsfwMediaBatchSettings settings,
    required bool includeImages,
    required bool includeVideos,
    required int pageSize,
    required int startPage,
    required int? maxPages,
    required int? maxItems,
    required int scanChunkSize,
    required bool preferThumbnailForImages,
    required int thumbnailWidth,
    required int thumbnailHeight,
    required int thumbnailQuality,
    required bool includeCleanResults,
    required int resolveConcurrency,
    required bool includeOriginFileFallback,
    required int retryPasses,
    required int retryDelayMs,
    required int loadProgressEvery,
    required bool debugLogging,
    void Function(NsfwGalleryLoadProgress progress)? onLoadProgress,
    void Function(NsfwMediaBatchProgress progress)? onScanProgress,
    void Function(NsfwMediaBatchResult chunkResult)? onChunkResult,
  }) async {
    await _ensureGalleryPermissionGranted();
    final scanId =
        'gallery_${DateTime.now().microsecondsSinceEpoch}_${_scanCounter++}';
    final streamedItems = <NsfwMediaBatchItemResult>[];
    var streamedProcessed = 0;
    var streamedSuccess = 0;
    var streamedErrors = 0;
    var streamedFlagged = 0;
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
            streamedItems.addAll(chunkResult.items);
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
        streamedItems.addAll(parsed.items);
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
      );
      if (!queuedHaramiFromChunks) {
        await _maybeAutoHaramiBatchHits(result.items, scanTag: 'scan_gallery');
      }
      return result;
    } finally {
      await subscription.cancel();
    }
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

    if (type == NsfwMediaType.video) {
      final videoResult = await scanVideo(
        videoPath: path,
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
      return NsfwMediaBatchItemResult(
        path: path,
        type: NsfwMediaType.video,
        videoResult: videoResult,
      );
    }

    final imageResult = await scanImage(
      imagePath: path,
      threshold: settings.imageThreshold,
    );
    return NsfwMediaBatchItemResult(
      path: path,
      type: NsfwMediaType.image,
      imageResult: imageResult,
    );
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
    int resolveRetryPasses = 3,
    int resolveRetryDelayMs = 1200,
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
    final preflightErrors = <NsfwMediaBatchItemResult>[];
    if (assetRefs.isNotEmpty) {
      final resolvedOutcomes = await _resolveAssetRefs(
        assetRefs,
        resolveConcurrency: resolveConcurrency,
        includeOriginFileFallback: includeOriginFileFallback,
        retryPasses: resolveRetryPasses,
        retryDelayMs: resolveRetryDelayMs,
      );
      media.addAll(
        resolvedOutcomes
            .where((item) => item.loaded != null)
            .map((item) => item.loaded!.toMediaInput()),
      );
      preflightErrors.addAll(
        resolvedOutcomes
            .where((item) => item.error != null)
            .map(
              (item) => NsfwMediaBatchItemResult(
                path: 'ph://${item.ref.id}',
                type: item.ref.type,
                assetId: item.ref.id,
                uri: 'ph://${item.ref.id}',
                error: item.error,
              ),
            ),
      );
    }
    if (media.isEmpty) {
      return NsfwMediaBatchResult(
        items: preflightErrors,
        processed: preflightErrors.length,
        successCount: 0,
        errorCount: preflightErrors.length,
        flaggedCount: 0,
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
    if (preflightErrors.isEmpty) {
      return scanned;
    }
    return NsfwMediaBatchResult(
      items: [...preflightErrors, ...scanned.items],
      processed: scanned.processed + preflightErrors.length,
      successCount: scanned.successCount,
      errorCount: scanned.errorCount + preflightErrors.length,
      flaggedCount: scanned.flaggedCount,
    );
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
    try {
      await _ensurePhotoManagerPermissionGranted();
      return;
    } catch (_) {}
    final granted = await requestMediaPermission();
    if (!granted) {
      throw const FormatException(
        'Gallery permission denied. Please grant media/photo access before initializing the scanner.',
      );
    }
  }

  Future<void> _ensurePhotoManagerPermissionGranted() async {
    final state = await PhotoManager.requestPermissionExtend();
    if (state.isAuth) {
      return;
    }
    throw const FormatException(
      'Gallery permission denied. Please grant media/photo access before initializing the scanner.',
    );
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

  Future<List<_AssetResolveOutcome>> _resolveAssetRefs(
    List<NsfwAssetRef> refs, {
    required int resolveConcurrency,
    required bool includeOriginFileFallback,
    int retryPasses = 2,
    int retryDelayMs = 1100,
  }) async {
    if (refs.isEmpty) {
      return const [];
    }
    final totalRefs = refs.length;
    final safeConcurrency = _resolveAdaptiveChunkSize(
      requestedChunkSize: resolveConcurrency,
      totalItems: totalRefs,
      maxConcurrency: resolveConcurrency,
      minChunkSize: 1,
      maxChunkSize: 8,
    );
    final normalizedRetryPasses = retryPasses.clamp(1, 3);
    var pending = List<NsfwAssetRef>.from(refs);
    final resolvedOutcomes = <_AssetResolveOutcome>[];
    var pass = 1;

    while (pending.isNotEmpty && pass <= normalizedRetryPasses) {
      final nextPending = <NsfwAssetRef>[];
      var cursor = 0;
      while (cursor < pending.length) {
        final end = math.min(cursor + safeConcurrency, pending.length);
        final chunk = pending.sublist(cursor, end);
        final chunkResults = await Future.wait(
          chunk.map((ref) async {
            try {
              final loaded = await loadAsset(
                assetId: ref.id,
                allowImages: ref.isImage,
                allowVideos: ref.isVideo,
                includeOriginFileFallback: includeOriginFileFallback,
              );
              if (loaded == null) {
                return _AssetResolveOutcome(
                  ref: ref,
                  error: 'Asset konnte nicht aufgelost werden.',
                );
              }
              return _AssetResolveOutcome(ref: ref, loaded: loaded);
            } catch (error) {
              return _AssetResolveOutcome(
                ref: ref,
                error: 'Asset-Auflosung fehlgeschlagen: $error',
              );
            }
          }),
        );
        for (final outcome in chunkResults) {
          if (outcome.loaded != null) {
            resolvedOutcomes.add(outcome);
            continue;
          }
          final message = (outcome.error ?? '').toLowerCase();
          final isRetryable =
              pass < normalizedRetryPasses &&
              (message.contains('3164') ||
                  message.contains('phphotoserrordomain') ||
                  message.contains('icloud') ||
                  message.contains('cloud') ||
                  message.contains('network') ||
                  message.contains('tempor') ||
                  message.contains('not available') ||
                  message.contains('resource'));
          if (isRetryable) {
            nextPending.add(outcome.ref);
          } else {
            resolvedOutcomes.add(outcome);
          }
        }
        cursor = end;
        await Future<void>.delayed(Duration.zero);
      }
      if (nextPending.isEmpty) {
        pending = const [];
        break;
      }
      if (retryDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: retryDelayMs));
      }
      pending = nextPending;
      pass += 1;
    }

    if (pending.isNotEmpty) {
      resolvedOutcomes.addAll(
        pending.map(
          (ref) => _AssetResolveOutcome(
            ref: ref,
            error:
                'Asset-Auflosung fehlgeschlagen: nach mehreren Versuchen weiterhin nicht verfugbar.',
          ),
        ),
      );
    }
    return resolvedOutcomes;
  }

  Future<List<NsfwAssetRef>> _loadMultipleAssetsViaPhotoManager({
    required bool includeImages,
    required bool includeVideos,
    required int pageSize,
    required int startPage,
    required int? maxPages,
    required int? maxItems,
    void Function(NsfwGalleryLoadProgress progress)? onProgress,
  }) async {
    await _ensurePhotoManagerPermissionGranted();
    final requestType = _toPhotoManagerRequestType(
      includeImages: includeImages,
      includeVideos: includeVideos,
    );
    final root = await _resolvePhotoManagerPrimaryPath(requestType);
    if (root == null) {
      return const [];
    }
    final safePageSize = pageSize.clamp(20, 2000);
    final refs = <NsfwAssetRef>[];
    final totalAssets = await root.assetCountAsync;
    var page = startPage < 0 ? 0 : startPage;
    final endPageExclusive = maxPages == null || maxPages <= 0
        ? null
        : page + maxPages;
    var scannedAssets = 0;

    while (true) {
      if (endPageExclusive != null && page >= endPageExclusive) {
        break;
      }
      final pageItems = await root.getAssetListPaged(
        page: page,
        size: safePageSize,
      );
      if (pageItems.isEmpty) {
        break;
      }
      scannedAssets += pageItems.length;
      for (final asset in pageItems) {
        final ref = _assetEntityToRef(asset);
        if (ref == null) {
          continue;
        }
        refs.add(ref);
        if (maxItems != null && refs.length >= maxItems) {
          break;
        }
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
      if (scannedAssets >= totalAssets) {
        break;
      }
      page += 1;
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

  Future<NsfwLoadedAsset?> _loadAssetViaPhotoManager({
    required String assetId,
    required bool allowImages,
    required bool allowVideos,
    required bool includeOriginFileFallback,
  }) async {
    await _ensurePhotoManagerPermissionGranted();
    final entity = await AssetEntity.fromId(assetId);
    if (entity == null) {
      return null;
    }
    final type = _toNsfwMediaType(entity.type);
    if (type == null) {
      return null;
    }
    if ((type == NsfwMediaType.image && !allowImages) ||
        (type == NsfwMediaType.video && !allowVideos)) {
      return null;
    }
    final path = await _resolveAssetEntityPathForScan(
      entity,
      includeOriginFileFallback: includeOriginFileFallback,
    );
    if (path == null || path.isEmpty) {
      return null;
    }
    return NsfwLoadedAsset(path: path, type: type, id: assetId);
  }

  Future<String?> _resolveAssetEntityPathForScan(
    AssetEntity entity, {
    required bool includeOriginFileFallback,
  }) async {
    File? file;
    try {
      file = await entity.file;
    } catch (_) {}
    if ((file == null || file.path.trim().isEmpty) && includeOriginFileFallback) {
      try {
        file = await entity.originFile;
      } catch (_) {}
    } else if (file == null || file.path.trim().isEmpty) {
      try {
        file = await entity.originFile;
      } catch (_) {}
    }
    final localPath = file?.path.trim() ?? '';
    if (localPath.isNotEmpty) {
      return localPath;
    }

    final type = _toNsfwMediaType(entity.type);
    if (type != NsfwMediaType.image) {
      return null;
    }
    try {
      final bytes = await entity.thumbnailDataWithSize(
        const ThumbnailSize.square(512),
        quality: 85,
      );
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      return _writeTempAssetThumbnail(entity.id, bytes);
    } catch (_) {
      return null;
    }
  }

  Future<String> _writeTempAssetThumbnail(String assetId, List<int> bytes) async {
    final cacheDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_nsfw_scaner${Platform.pathSeparator}photo_manager_thumb',
    );
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    final file = File(
      '${cacheDir.path}${Platform.pathSeparator}asset_${assetId.replaceAll(RegExp(r"[^A-Za-z0-9_-]"), "_")}_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  RequestType _toPhotoManagerRequestType({
    required bool includeImages,
    required bool includeVideos,
  }) {
    if (includeImages && includeVideos) {
      return RequestType.common;
    }
    if (includeVideos) {
      return RequestType.video;
    }
    return RequestType.image;
  }

  NsfwAssetRef? _assetEntityToRef(AssetEntity asset) {
    final type = _toNsfwMediaType(asset.type);
    if (type == null) {
      return null;
    }
    return NsfwAssetRef(
      id: asset.id,
      type: type,
      width: asset.width,
      height: asset.height,
      durationSeconds: asset.duration,
      createDateSecond: asset.createDateTime.millisecondsSinceEpoch ~/ 1000,
      modifiedDateSecond: asset.modifiedDateTime.millisecondsSinceEpoch ~/ 1000,
    );
  }

  NsfwMediaType? _toNsfwMediaType(AssetType type) {
    switch (type) {
      case AssetType.image:
        return NsfwMediaType.image;
      case AssetType.video:
        return NsfwMediaType.video;
      default:
        return null;
    }
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
    final minByConcurrency = (safeConcurrency * 3).clamp(boundedMin, boundedMax);
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

  Future<AssetPathEntity?> _resolvePhotoManagerPrimaryPath(
    RequestType requestType,
  ) async {
    final paths = await PhotoManager.getAssetPathList(
      type: requestType,
      onlyAll: false,
    );
    if (paths.isEmpty) {
      return null;
    }
    AssetPathEntity? bestPath;
    var bestCount = -1;
    for (final path in paths) {
      final count = await path.assetCountAsync;
      if (count > bestCount) {
        bestCount = count;
        bestPath = path;
      }
    }
    if (bestPath == null || bestCount <= 0) {
      return null;
    }
    return bestPath;
  }
}

class _DownloadedMedia {
  const _DownloadedMedia({required this.file, required this.type});

  final File file;
  final NsfwMediaType type;
}

class _AssetResolveOutcome {
  const _AssetResolveOutcome({required this.ref, this.loaded, this.error});

  final NsfwAssetRef ref;
  final NsfwLoadedAsset? loaded;
  final String? error;
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
      items.add(
        NsfwMediaBatchItemResult(
          path:
              '${itemMap['path'] ?? itemMap['uri'] ?? itemMap['assetId'] ?? ''}',
          type: type,
          assetId: _toNullableString(itemMap['assetId']),
          uri: _toNullableString(itemMap['uri']),
          imageResult: rawImageResult is Map
              ? NsfwScanResult.fromMap(
                  rawImageResult.map((key, value) => MapEntry('$key', value)),
                )
              : null,
          videoResult: rawVideoResult is Map
              ? NsfwVideoScanResult.fromMap(
                  rawVideoResult.map((key, value) => MapEntry('$key', value)),
                )
              : null,
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
