import 'dart:async';
import 'dart:io';

import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';
import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner_method_channel.dart';
import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterNsfwScanerPlatform
    with MockPlatformInterfaceMixin
    implements FlutterNsfwScanerPlatform {
  final _progressController =
      StreamController<Map<String, dynamic>>.broadcast();
  int resolveMediaAssetCallCount = 0;
  double? lastScanImageThreshold;
  double? lastScanBatchThreshold;
  double? lastScanVideoThreshold;
  bool returnEmptyPathForVideoBatch = false;

  @override
  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  @override
  Future<Map<String, dynamic>> getUploadRuntimeInfo() async => {
    'buildVersion': '1.0+1',
    'deviceId': 'test-device-id',
    'platform': 'ios',
  };

  @override
  Future<void> disposeScanner() async {}

  @override
  Future<void> cancelScan({String? scanId}) async {}

  @override
  Future<void> resetGalleryScanCache() async {}

  @override
  Future<String?> loadImageThumbnail({
    required String assetRef,
    required int width,
    required int height,
    required int quality,
  }) async {
    return '/tmp/thumb.jpg';
  }

  @override
  Future<String?> loadImageAsset({required String assetRef}) async {
    return '/tmp/asset.jpg';
  }

  @override
  Future<Map<String, dynamic>?> pickMedia({
    required bool multiple,
    required bool allowImages,
    required bool allowVideos,
  }) async {
    if (!allowImages && !allowVideos) {
      return null;
    }
    return {
      'imagePaths': allowImages ? ['/tmp/picked_image.jpg'] : const <String>[],
      'videoPaths': allowVideos && !multiple
          ? ['/tmp/picked_video.mp4']
          : const <String>[],
    };
  }

  @override
  Future<bool> checkMediaPermission() async => true;

  @override
  Future<bool> requestMediaPermission() async => true;

  @override
  Future<String> getMediaPermissionStatus() async => 'authorized';

  @override
  Future<bool> presentLimitedLibraryPicker() async => false;

  @override
  Future<Map<String, dynamic>?> resolveMediaAsset({
    required String assetId,
    required bool includeOriginFileFallback,
  }) async {
    resolveMediaAssetCallCount += 1;
    if (assetId.toLowerCase().contains('fail')) {
      throw const FormatException('PHPhotosErrorDomain Code=3164');
    }
    return {
      'id': assetId,
      'type': assetId.toLowerCase().contains('video') ? 'video' : 'image',
      'path': '/tmp/resolved_${assetId.replaceAll(':', '_')}',
    };
  }

  @override
  Future<Map<String, dynamic>> listGalleryAssets({
    required int start,
    required int end,
    required bool includeImages,
    required bool includeVideos,
  }) async {
    final items = <Map<String, dynamic>>[];
    var index = 0;
    if (includeImages) {
      items.add({
        'id': 'image:1',
        'type': 'image',
        'width': 100,
        'height': 100,
        'durationSeconds': 0,
        'createDateSecond': 1,
        'modifiedDateSecond': 1,
      });
      index += 1;
    }
    if (includeVideos) {
      items.add({
        'id': 'video:2',
        'type': 'video',
        'width': 1920,
        'height': 1080,
        'durationSeconds': 12,
        'createDateSecond': 2,
        'modifiedDateSecond': 2,
      });
      index += 1;
    }
    return {
      'items': items.skip(start).take(end - start).toList(growable: false),
      'totalAssets': index,
      'scannedAssets': items.skip(start).take(end - start).length,
    };
  }

  @override
  Future<String?> getPlatformVersion() async => '42';

  @override
  Future<void> initializeScanner({
    required String modelAssetPath,
    String? labelsAssetPath,
    required int numThreads,
    required String inputNormalization,
    String? galleryScanCachePrefix,
    String? galleryScanCacheTableName,
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> scanBatch({
    required String scanId,
    required List<String> imagePaths,
    required double threshold,
    required int maxConcurrency,
  }) async {
    lastScanBatchThreshold = threshold;
    _progressController.add({
      'scanId': scanId,
      'processed': 1,
      'total': imagePaths.length,
      'percent': imagePaths.isEmpty ? 0.0 : 1 / imagePaths.length,
      'status': 'running',
      'imagePath': imagePaths.isEmpty ? null : imagePaths.first,
      'error': null,
    });
    _progressController.add({
      'scanId': scanId,
      'processed': imagePaths.length,
      'total': imagePaths.length,
      'percent': 1.0,
      'status': 'completed',
      'imagePath': null,
      'error': null,
    });

    return imagePaths
        .map(
          (path) => <String, dynamic>{
            'imagePath': path,
            'nsfwScore': 0.9,
            'safeScore': 0.1,
            'isNsfw': true,
            'topLabel': 'nsfw',
            'topScore': 0.9,
            'scores': {'safe': 0.1, 'nsfw': 0.9},
          },
        )
        .toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>> scanVideo({
    required String scanId,
    required String videoPath,
    required double threshold,
    required double sampleRateFps,
    required int maxFrames,
    required bool dynamicSampleRate,
    required double shortVideoMinSampleRateFps,
    required double shortVideoMaxSampleRateFps,
    required int mediumVideoMinutesThreshold,
    required int longVideoMinutesThreshold,
    required double mediumVideoSampleRateFps,
    required double longVideoSampleRateFps,
    required bool videoEarlyStopEnabled,
    required int videoEarlyStopBaseNsfwFrames,
    required int videoEarlyStopMediumBonusFrames,
    required int videoEarlyStopLongBonusFrames,
    required int videoEarlyStopVeryLongMinutesThreshold,
    required int videoEarlyStopVeryLongBonusFrames,
  }) async {
    lastScanVideoThreshold = threshold;
    return <String, dynamic>{
      'videoPath': videoPath,
      'sampleRateFps': sampleRateFps,
      'sampledFrames': 10,
      'flaggedFrames': 2,
      'flaggedRatio': 0.2,
      'maxNsfwScore': 0.9,
      'isNsfw': true,
      'frames': [
        {
          'timestampMs': 0.0,
          'nsfwScore': 0.9,
          'safeScore': 0.1,
          'isNsfw': true,
          'topLabel': 'nsfw',
          'topScore': 0.9,
          'scores': {'safe': 0.1, 'nsfw': 0.9},
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> scanMediaBatch({
    required String scanId,
    required List<Map<String, dynamic>> mediaItems,
    required Map<String, dynamic> settings,
  }) async {
    for (var i = 0; i < mediaItems.length; i += 1) {
      _progressController.add({
        'scanId': scanId,
        'processed': i + 1,
        'total': mediaItems.length,
        'percent': mediaItems.isEmpty ? 0.0 : (i + 1) / mediaItems.length,
        'status': 'running',
        'imagePath': mediaItems[i]['path'],
        'error': null,
        'mediaType': mediaItems[i]['type'],
      });
    }
    _progressController.add({
      'scanId': scanId,
      'processed': mediaItems.length,
      'total': mediaItems.length,
      'percent': 1.0,
      'status': 'completed',
      'imagePath': null,
      'error': null,
      'mediaType': null,
    });
    final items = mediaItems
        .map((item) {
          final type = '${item['type']}';
          if (type == 'video') {
            return {
              'path': returnEmptyPathForVideoBatch ? null : item['path'],
              'type': 'video',
              'imageResult': null,
              'videoResult': {
                'videoPath': item['path'],
                'sampleRateFps': 0.3,
                'sampledFrames': 10,
                'flaggedFrames': 2,
                'flaggedRatio': 0.2,
                'maxNsfwScore': 0.9,
                'isNsfw': true,
                'requiredNsfwFrames': 3,
                'frames': const [],
              },
              'error': null,
            };
          }
          return {
            'path': item['path'],
            'type': 'image',
            'imageResult': {
              'imagePath': item['path'],
              'nsfwScore': 0.9,
              'safeScore': 0.1,
              'isNsfw': true,
              'topLabel': 'nsfw',
              'topScore': 0.9,
              'scores': {'safe': 0.1, 'nsfw': 0.9},
            },
            'videoResult': null,
            'error': null,
          };
        })
        .toList(growable: false);
    return {
      'items': items,
      'processed': items.length,
      'successCount': items.length,
      'errorCount': 0,
      'flaggedCount': items.length,
      'skippedCount': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> scanGallery({
    required String scanId,
    required Map<String, dynamic> settings,
  }) async {
    final requestedRetained =
        (settings['maxRetainedResultItems'] as num?)?.toInt() ?? 4000;
    final chunkItems = List.generate(3, (index) {
      final path = '/tmp/gallery${index + 1}.jpg';
      return {
        'path': path,
        'type': 'image',
        'imageResult': {
          'imagePath': path,
          'nsfwScore': 0.9,
          'safeScore': 0.1,
          'isNsfw': true,
          'topLabel': 'nsfw',
          'topScore': 0.9,
          'scores': {'safe': 0.1, 'nsfw': 0.9},
        },
        'videoResult': null,
        'error': null,
      };
    });
    _progressController.add({
      'eventType': 'gallery_scan_progress',
      'scanId': scanId,
      'processed': 0,
      'total': 3,
      'percent': 0.0,
      'status': 'started',
      'imagePath': null,
      'error': null,
      'mediaType': null,
    });
    _progressController.add({
      'eventType': 'gallery_result_batch',
      'scanId': scanId,
      'status': 'running',
      'processed': 3,
      'processedTotal': 3,
      'total': 3,
      'percent': 1.0,
      'items': chunkItems,
      'successCount': 3,
      'errorCount': 0,
      'flaggedCount': 3,
      'didTruncateItems': requestedRetained < chunkItems.length,
    });
    _progressController.add({
      'eventType': 'gallery_scan_progress',
      'scanId': scanId,
      'processed': 3,
      'total': 3,
      'percent': 1.0,
      'status': 'completed',
      'imagePath': null,
      'error': null,
      'mediaType': null,
    });
    return {
      'items': const [],
      'processed': 3,
      'successCount': 3,
      'errorCount': 0,
      'flaggedCount': 3,
      'skippedCount': 0,
      'didTruncateItems': requestedRetained < chunkItems.length,
    };
  }

  @override
  Future<Map<String, dynamic>> scanImage({
    required String imagePath,
    required double threshold,
  }) async {
    lastScanImageThreshold = threshold;
    return <String, dynamic>{
      'imagePath': imagePath,
      'nsfwScore': 0.9,
      'safeScore': 0.1,
      'isNsfw': true,
      'topLabel': 'nsfw',
      'topScore': 0.9,
      'scores': {'safe': 0.1, 'nsfw': 0.9},
    };
  }

  Future<void> close() => _progressController.close();
}

void main() {
  final FlutterNsfwScanerPlatform initialPlatform =
      FlutterNsfwScanerPlatform.instance;

  test('$MethodChannelFlutterNsfwScaner is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterNsfwScaner>());
  });

  test('scanImage parses payload', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final result = await plugin.scanImage(imagePath: '/tmp/image.jpg');

    expect(result.imagePath, '/tmp/image.jpg');
    expect(result.isNsfw, true);
    expect(result.nsfwScore, 0.9);
    expect(result.topLabel, 'nsfw');
    expect(fakePlatform.lastScanImageThreshold, 0.7);

    await fakePlatform.close();
  });

  test('initialize sets default threshold for direct scans', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    await plugin.initialize(
      modelAssetPath: 'assets/models/model.tflite',
      defaultThreshold: 0.61,
    );

    await plugin.scanImage(imagePath: '/tmp/image.jpg');
    await plugin.scanBatch(imagePaths: const ['/tmp/a.jpg']);
    await plugin.scanVideo(videoPath: '/tmp/video.mp4');

    expect(fakePlatform.lastScanImageThreshold, 0.61);
    expect(fakePlatform.lastScanBatchThreshold, 0.61);
    expect(fakePlatform.lastScanVideoThreshold, 0.61);

    await fakePlatform.close();
  });

  test('explicit threshold still overrides initialized default', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    await plugin.initialize(
      modelAssetPath: 'assets/models/model.tflite',
      defaultThreshold: 0.61,
    );

    await plugin.scanImage(imagePath: '/tmp/image.jpg', threshold: 0.42);
    await plugin.scanBatch(imagePaths: const ['/tmp/a.jpg'], threshold: 0.43);
    await plugin.scanVideo(videoPath: '/tmp/video.mp4', threshold: 0.44);

    expect(fakePlatform.lastScanImageThreshold, 0.42);
    expect(fakePlatform.lastScanBatchThreshold, 0.43);
    expect(fakePlatform.lastScanVideoThreshold, 0.44);

    await fakePlatform.close();
  });

  test('scanBatch emits progress callback', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final progressEvents = <double>[];

    final results = await plugin.scanBatch(
      imagePaths: const ['/tmp/a.jpg', '/tmp/b.jpg'],
      onProgress: (progress) {
        progressEvents.add(progress.percent);
      },
    );

    expect(results, hasLength(2));
    expect(progressEvents, isNotEmpty);
    expect(progressEvents.last, 1.0);

    await fakePlatform.close();
  });

  test('scanVideo parses payload', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final result = await plugin.scanVideo(videoPath: '/tmp/video.mp4');

    expect(result.videoPath, '/tmp/video.mp4');
    expect(result.sampledFrames, 10);
    expect(result.isNsfw, true);
    expect(result.frames, isNotEmpty);

    await fakePlatform.close();
  });

  test(
    'scanMediaFromUrl scans image and does not persist local file by default',
    () async {
      final fakePlatform = MockFlutterNsfwScanerPlatform();
      FlutterNsfwScanerPlatform.instance = fakePlatform;
      final plugin = FlutterNsfwScaner();

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(List<int>.filled(32, 7));
        await request.response.close();
      });
      final url = 'http://${server.address.host}:${server.port}/image.jpg';

      final result = await plugin.scanMediaFromUrl(mediaUrl: url);
      expect(result.type, NsfwMediaType.image);
      expect(result.path, url);
      expect(result.imageResult, isNotNull);
      expect(result.imageResult!.imagePath, url);

      await fakePlatform.close();
    },
  );

  test(
    'scanMediaFromUrl scans image and persists file when requested',
    () async {
      final fakePlatform = MockFlutterNsfwScanerPlatform();
      FlutterNsfwScanerPlatform.instance = fakePlatform;
      final plugin = FlutterNsfwScaner();

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(List<int>.filled(64, 11));
        await request.response.close();
      });
      final targetDir = await Directory.systemTemp.createTemp(
        'nsfw_url_scan_test_',
      );
      addTearDown(() async {
        if (await targetDir.exists()) {
          await targetDir.delete(recursive: true);
        }
      });
      final url = 'http://${server.address.host}:${server.port}/keep.jpg';

      final result = await plugin.scanMediaFromUrl(
        mediaUrl: url,
        saveDownloadedFile: true,
        saveDirectoryPath: targetDir.path,
        fileName: 'saved_image.jpg',
      );

      expect(result.type, NsfwMediaType.image);
      final savedPath = result.imageResult!.imagePath;
      expect(savedPath.startsWith(targetDir.path), isTrue);
      expect(await File(savedPath).exists(), isTrue);

      await fakePlatform.close();
    },
  );

  test('scanMediaBatch scans mixed media with settings', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final progress = <double>[];
    final result = await plugin.scanMediaBatch(
      media: const [
        NsfwMediaInput.image('/tmp/a.jpg'),
        NsfwMediaInput.video('/tmp/b.mp4'),
      ],
      settings: const NsfwMediaBatchSettings(
        imageThreshold: 0.6,
        videoThreshold: 0.8,
        videoSampleRateFps: 3.0,
        videoMaxFrames: 120,
        maxConcurrency: 2,
      ),
      onProgress: (event) {
        progress.add(event.percent);
      },
    );

    expect(result.processed, 2);
    expect(result.items, hasLength(2));
    expect(result.flaggedCount, 2);
    expect(progress.isNotEmpty, true);
    expect(progress.last, 1.0);

    await fakePlatform.close();
  });

  test(
    'scanWholeGallery caps retained items in memory for large result streams',
    () async {
      final fakePlatform = MockFlutterNsfwScanerPlatform();
      FlutterNsfwScanerPlatform.instance = fakePlatform;
      final plugin = FlutterNsfwScaner();

      final chunkSizes = <int>[];
      final result = await plugin.scanWholeGallery(
        maxRetainedResultItems: 2,
        onChunkResult: (chunk) => chunkSizes.add(chunk.items.length),
      );

      expect(result.processed, 3);
      expect(result.flaggedCount, 3);
      expect(result.items, hasLength(2));
      expect(result.didTruncateItems, isTrue);
      expect(chunkSizes, [3]);

      await fakePlatform.close();
    },
  );

  test('scanMediaInChunks aggregates progress and counters', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final progress = <double>[];
    final chunkProcessed = <int>[];
    final result = await plugin.scanMediaInChunks(
      media: const [
        NsfwMediaInput.image('/tmp/1.jpg'),
        NsfwMediaInput.image('/tmp/2.jpg'),
        NsfwMediaInput.image('/tmp/3.jpg'),
        NsfwMediaInput.image('/tmp/4.jpg'),
        NsfwMediaInput.image('/tmp/5.jpg'),
        NsfwMediaInput.image('/tmp/6.jpg'),
        NsfwMediaInput.image('/tmp/7.jpg'),
        NsfwMediaInput.image('/tmp/8.jpg'),
        NsfwMediaInput.video('/tmp/9.mp4'),
      ],
      chunkSize: 2,
      settings: const NsfwMediaBatchSettings(maxConcurrency: 2),
      onProgress: (event) => progress.add(event.percent),
      onChunkResult: (chunk) => chunkProcessed.add(chunk.processed),
    );

    expect(result.processed, 9);
    expect(result.successCount, 9);
    expect(result.errorCount, 0);
    expect(result.flaggedCount, 9);
    expect(result.items, hasLength(9));
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
    expect(chunkProcessed, [8, 1]);

    await fakePlatform.close();
  });

  test('multiScan combines image and video lists', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final result = await plugin.multiScan(
      imagePaths: const ['/tmp/a.jpg'],
      videoPaths: const ['/tmp/b.mp4'],
    );

    expect(result.processed, 2);
    expect(result.items, hasLength(2));

    await fakePlatform.close();
  });

  test(
    'scanMultipleMedia scans assetRefs lazily without pre-resolve',
    () async {
      final fakePlatform = MockFlutterNsfwScanerPlatform();
      FlutterNsfwScanerPlatform.instance = fakePlatform;
      final plugin = FlutterNsfwScaner();

      final chunkProcessed = <int>[];
      final result = await plugin.scanMultipleMedia(
        pickIfEmpty: false,
        assetRefs: const [
          NsfwAssetRef(
            id: 'ok-image-1',
            type: NsfwMediaType.image,
            width: 100,
            height: 100,
            durationSeconds: 0,
            createDateSecond: 1,
            modifiedDateSecond: 1,
          ),
          NsfwAssetRef(
            id: 'fail-image-2',
            type: NsfwMediaType.image,
            width: 100,
            height: 100,
            durationSeconds: 0,
            createDateSecond: 1,
            modifiedDateSecond: 1,
          ),
        ],
        onChunkResult: (chunk) => chunkProcessed.add(chunk.processed),
      );

      expect(result.processed, 2);
      expect(result.successCount, 2);
      expect(result.errorCount, 0);
      expect(result.items, hasLength(2));
      expect(result.items.first.path, 'ph://ok-image-1');
      expect(result.items.first.assetId, 'ok-image-1');
      expect(result.items.first.uri, 'ph://ok-image-1');
      expect(result.items.last.path, 'ph://fail-image-2');
      expect(result.items.last.assetId, 'fail-image-2');
      expect(result.items.last.uri, 'ph://fail-image-2');
      expect(chunkProcessed, [2]);

      await fakePlatform.close();
    },
  );

  test('loadImageThumbnail and loadImageAsset return plugin paths', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final thumbnailPath = await plugin.loadImageThumbnail(
      assetRef: 'ph://asset-id',
      width: 180,
      height: 180,
      quality: 75,
    );
    final fullAssetPath = await plugin.loadImageAsset(
      assetRef: 'ph://asset-id',
    );

    expect(thumbnailPath, '/tmp/thumb.jpg');
    expect(fullAssetPath, '/tmp/asset.jpg');

    await fakePlatform.close();
  });

  test('waitForPendingUploads flushes queued hit uploads', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    final tempDir = await Directory.systemTemp.createTemp('nsfw_upload_test');
    final imageFile = File('${tempDir.path}/hit.jpg');
    await imageFile.writeAsBytes(const [1, 2, 3, 4], flush: true);

    unawaited(() async {
      await for (final request in server) {
        requests.add(request.uri.path);
        await request.drain();
        request.response.statusCode = 200;
        await request.response.close();
      }
    }());

    await plugin.initialize(
      modelAssetPath: 'ignored.tflite',
      enableNsfwHitUpload: true,
      normaniConfig: NsfwNormaniConfig(
        normaniUrl: 'http://127.0.0.1:${server.port}',
        anonKey: 'anon',
        bucket: 'bucket',
      ),
    );

    final result = await plugin.scanImage(imagePath: imageFile.path);
    expect(result.isNsfw, isTrue);

    await plugin.waitForPendingUploads();

    expect(requests, hasLength(1));
    expect(requests.single, contains('/storage/v1/object/'));

    await server.close(force: true);
    await tempDir.delete(recursive: true);
    await fakePlatform.close();
  });

  test('scanMedia preserves asset references for video assets', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final result = await plugin.scanMedia(
      assetRef: const NsfwAssetRef(
        id: 'video:2',
        type: NsfwMediaType.video,
        width: 1920,
        height: 1080,
        durationSeconds: 12,
        createDateSecond: 2,
        modifiedDateSecond: 2,
      ),
    );

    expect(result.type, NsfwMediaType.video);
    expect(result.path, 'video:2');
    expect(result.assetId, 'video:2');
    expect(result.uri, 'video:2');
    expect(result.videoResult, isNotNull);
    expect(result.videoResult!.videoPath, '/tmp/resolved_video_2');
    expect(result.videoResult!.requiredNsfwFrames, 1);

    await fakePlatform.close();
  });

  test(
    'scanMediaBatch falls back to videoResult.videoPath when path is empty',
    () async {
      final fakePlatform = MockFlutterNsfwScanerPlatform()
        ..returnEmptyPathForVideoBatch = true;
      FlutterNsfwScanerPlatform.instance = fakePlatform;
      final plugin = FlutterNsfwScaner();

      final result = await plugin.scanMediaBatch(
        media: const [NsfwMediaInput.video('/tmp/b.mp4')],
      );

      expect(result.items, hasLength(1));
      expect(result.items.first.type, NsfwMediaType.video);
      expect(result.items.first.path, '/tmp/b.mp4');
      expect(result.items.first.videoResult, isNotNull);
      expect(result.items.first.videoResult!.requiredNsfwFrames, 3);

      await fakePlatform.close();
    },
  );
}
