import 'package:flutter/services.dart';
import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelFlutterNsfwScaner();
  const channel = MethodChannel('flutter_nsfw_scaner');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'scanImage':
              return {
                'imagePath': '/tmp/image.jpg',
                'nsfwScore': 0.8,
                'safeScore': 0.2,
                'isNsfw': true,
                'topLabel': 'nsfw',
                'topScore': 0.8,
                'scores': {'safe': 0.2, 'nsfw': 0.8},
              };
            case 'scanBatch':
              return [
                {
                  'imagePath': '/tmp/image1.jpg',
                  'nsfwScore': 0.8,
                  'safeScore': 0.2,
                  'isNsfw': true,
                  'topLabel': 'nsfw',
                  'topScore': 0.8,
                  'scores': {'safe': 0.2, 'nsfw': 0.8},
                },
              ];
            case 'scanVideo':
              return {
                'videoPath': '/tmp/video.mp4',
                'sampleRateFps': 2.0,
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
            case 'scanMediaBatch':
              return {
                'items': [
                  {
                    'path': '/tmp/image1.jpg',
                    'type': 'image',
                    'imageResult': {
                      'imagePath': '/tmp/image1.jpg',
                      'nsfwScore': 0.8,
                      'safeScore': 0.2,
                      'isNsfw': true,
                      'topLabel': 'nsfw',
                      'topScore': 0.8,
                      'scores': {'safe': 0.2, 'nsfw': 0.8},
                    },
                    'videoResult': null,
                    'error': null,
                  },
                ],
                'processed': 1,
                'successCount': 1,
                'errorCount': 0,
                'flaggedCount': 1,
              };
            case 'scanGallery':
              return {
                'items': const [],
                'processed': 10,
                'successCount': 9,
                'errorCount': 1,
                'flaggedCount': 3,
              };
            case 'loadImageThumbnail':
              return '/tmp/thumb.jpg';
            case 'loadImageAsset':
              return '/tmp/asset.jpg';
            case 'pickMedia':
              return {
                'imagePaths': ['/tmp/picked_image.jpg'],
                'videoPaths': const <String>[],
              };
            case 'requestMediaPermission':
              return true;
            case 'checkMediaPermission':
              return true;
            case 'getMediaPermissionStatus':
              return 'limited';
            case 'presentLimitedLibraryPicker':
              return true;
            case 'resolveMediaAsset':
              return {
                'id': 'image:1',
                'type': 'image',
                'path': '/tmp/resolved_image.jpg',
              };
            case 'listGalleryAssets':
              return {
                'items': [
                  {
                    'id': 'image:1',
                    'type': 'image',
                    'width': 100,
                    'height': 100,
                    'durationSeconds': 0,
                    'createDateSecond': 1,
                    'modifiedDateSecond': 1,
                  },
                ],
                'totalAssets': 1,
                'scannedAssets': 1,
              };
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('scanImage returns map payload', () async {
    final response = await platform.scanImage(
      imagePath: '/tmp/image.jpg',
      threshold: 0.7,
    );

    expect(response['isNsfw'], true);
    expect(response['topLabel'], 'nsfw');
  });

  test('scanBatch returns ordered payload', () async {
    final response = await platform.scanBatch(
      scanId: 'scan_1',
      imagePaths: const ['/tmp/image1.jpg'],
      threshold: 0.7,
      maxConcurrency: 2,
    );

    expect(response, hasLength(1));
    expect(response.first['imagePath'], '/tmp/image1.jpg');
  });

  test('scanVideo returns summary payload', () async {
    final response = await platform.scanVideo(
      scanId: 'video_1',
      videoPath: '/tmp/video.mp4',
      threshold: 0.7,
      sampleRateFps: 2.0,
      maxFrames: 300,
      dynamicSampleRate: true,
      shortVideoMinSampleRateFps: 0.5,
      shortVideoMaxSampleRateFps: 0.8,
      mediumVideoMinutesThreshold: 10,
      longVideoMinutesThreshold: 15,
      mediumVideoSampleRateFps: 0.3,
      longVideoSampleRateFps: 0.2,
      videoEarlyStopEnabled: true,
      videoEarlyStopBaseNsfwFrames: 3,
      videoEarlyStopMediumBonusFrames: 1,
      videoEarlyStopLongBonusFrames: 2,
      videoEarlyStopVeryLongMinutesThreshold: 30,
      videoEarlyStopVeryLongBonusFrames: 3,
    );

    expect(response['videoPath'], '/tmp/video.mp4');
    expect(response['sampledFrames'], 10);
    expect(response['isNsfw'], true);
  });

  test('scanMediaBatch returns aggregate payload', () async {
    final response = await platform.scanMediaBatch(
      scanId: 'media_1',
      mediaItems: const [
        {'path': '/tmp/image1.jpg', 'type': 'image'},
      ],
      settings: const {},
    );

    expect(response['processed'], 1);
    expect((response['items'] as List).length, 1);
  });

  test('scanGallery returns aggregate payload', () async {
    final response = await platform.scanGallery(
      scanId: 'gallery_1',
      settings: const {},
    );

    expect(response['processed'], 10);
    expect(response['flaggedCount'], 3);
  });

  test('cancelScan calls platform method', () async {
    await platform.cancelScan(scanId: 'scan_1');
  });

  test('resetGalleryScanCache calls platform method', () async {
    await platform.resetGalleryScanCache();
  });

  test('loadImageThumbnail returns cached thumbnail path', () async {
    final response = await platform.loadImageThumbnail(
      assetRef: 'ph://A-B-C',
      width: 160,
      height: 160,
      quality: 70,
    );
    expect(response, '/tmp/thumb.jpg');
  });

  test('loadImageAsset returns local full asset path', () async {
    final response = await platform.loadImageAsset(assetRef: 'ph://A-B-C');
    expect(response, '/tmp/asset.jpg');
  });

  test('pickMedia returns picked media payload', () async {
    final response = await platform.pickMedia(
      multiple: false,
      allowImages: true,
      allowVideos: false,
    );
    expect(response, isNotNull);
    expect(response!['imagePaths'], ['/tmp/picked_image.jpg']);
  });

  test('requestMediaPermission returns granted state', () async {
    expect(await platform.requestMediaPermission(), isTrue);
  });

  test('checkMediaPermission returns current granted state', () async {
    expect(await platform.checkMediaPermission(), isTrue);
  });

  test('getMediaPermissionStatus returns current status string', () async {
    expect(await platform.getMediaPermissionStatus(), 'limited');
  });

  test('presentLimitedLibraryPicker returns operation state', () async {
    expect(await platform.presentLimitedLibraryPicker(), isTrue);
  });

  test('resolveMediaAsset returns resolved path payload', () async {
    final response = await platform.resolveMediaAsset(
      assetId: 'image:1',
      includeOriginFileFallback: false,
    );
    expect(response, isNotNull);
    expect(response!['path'], '/tmp/resolved_image.jpg');
  });

  test('listGalleryAssets returns gallery page payload', () async {
    final response = await platform.listGalleryAssets(
      start: 0,
      end: 20,
      includeImages: true,
      includeVideos: true,
    );
    expect(response['totalAssets'], 1);
    expect((response['items'] as List).length, 1);
  });
}
