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

  @override
  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  @override
  Future<void> disposeScanner() async {}

  @override
  Future<void> cancelScan({String? scanId}) async {}

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
  Future<Map<String, dynamic>?> resolveMediaAsset({
    required String assetId,
    required bool includeOriginFileFallback,
  }) async {
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
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> scanBatch({
    required String scanId,
    required List<String> imagePaths,
    required double threshold,
    required int maxConcurrency,
  }) async {
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
              'path': item['path'],
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
    };
  }

  @override
  Future<Map<String, dynamic>> scanGallery({
    required String scanId,
    required Map<String, dynamic> settings,
  }) async {
    _progressController.add({
      'eventType': 'gallery_scan_progress',
      'scanId': scanId,
      'processed': 0,
      'total': 1,
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
      'processed': 1,
      'processedTotal': 1,
      'total': 1,
      'percent': 1.0,
      'items': [
        {
          'path': '/tmp/gallery1.jpg',
          'type': 'image',
          'imageResult': {
            'imagePath': '/tmp/gallery1.jpg',
            'nsfwScore': 0.9,
            'safeScore': 0.1,
            'isNsfw': true,
            'topLabel': 'nsfw',
            'topScore': 0.9,
            'scores': {'safe': 0.1, 'nsfw': 0.9},
          },
          'videoResult': null,
          'error': null,
        },
      ],
      'successCount': 1,
      'errorCount': 0,
      'flaggedCount': 1,
    });
    _progressController.add({
      'eventType': 'gallery_scan_progress',
      'scanId': scanId,
      'processed': 1,
      'total': 1,
      'percent': 1.0,
      'status': 'completed',
      'imagePath': null,
      'error': null,
      'mediaType': null,
    });
    return {
      'items': const [],
      'processed': 1,
      'successCount': 1,
      'errorCount': 0,
      'flaggedCount': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> scanImage({
    required String imagePath,
    required double threshold,
  }) async {
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

  test('scanMediaInChunks aggregates progress and counters', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

    final progress = <double>[];
    final result = await plugin.scanMediaInChunks(
      media: const [
        NsfwMediaInput.image('/tmp/a.jpg'),
        NsfwMediaInput.image('/tmp/b.jpg'),
        NsfwMediaInput.video('/tmp/c.mp4'),
      ],
      chunkSize: 2,
      settings: const NsfwMediaBatchSettings(maxConcurrency: 2),
      onProgress: (event) => progress.add(event.percent),
    );

    expect(result.processed, 3);
    expect(result.successCount, 3);
    expect(result.errorCount, 0);
    expect(result.flaggedCount, 3);
    expect(result.items, hasLength(3));
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);

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

  test('scanMultipleMedia skips failing assetRefs and continues', () async {
    final fakePlatform = MockFlutterNsfwScanerPlatform();
    FlutterNsfwScanerPlatform.instance = fakePlatform;
    final plugin = FlutterNsfwScaner();

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
    );

    expect(result.processed, 2);
    expect(result.successCount, 1);
    expect(result.errorCount, 1);
    expect(
      result.items.where((item) => item.hasError).single.error,
      contains('Asset-Auflosung fehlgeschlagen'),
    );

    await fakePlatform.close();
  });

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
}
