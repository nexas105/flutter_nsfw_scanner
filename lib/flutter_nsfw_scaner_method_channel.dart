import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_nsfw_scaner_platform_interface.dart';

class MethodChannelFlutterNsfwScaner extends FlutterNsfwScanerPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_nsfw_scaner');

  @visibleForTesting
  final eventChannel = const EventChannel('flutter_nsfw_scaner/progress');

  Stream<Map<String, dynamic>>? _progressStream;

  @override
  Stream<Map<String, dynamic>> get progressStream {
    return _progressStream ??= eventChannel.receiveBroadcastStream().map(
      (event) => _asStringDynamicMap(event),
    );
  }

  @override
  Future<String?> getPlatformVersion() async {
    return methodChannel.invokeMethod<String>('getPlatformVersion');
  }

  @override
  Future<void> initializeScanner({
    required String modelAssetPath,
    String? labelsAssetPath,
    required int numThreads,
    required String inputNormalization,
  }) async {
    await methodChannel.invokeMethod<void>('initializeScanner', {
      'modelAssetPath': modelAssetPath,
      'labelsAssetPath': labelsAssetPath,
      'numThreads': numThreads,
      'inputNormalization': inputNormalization,
    });
  }

  @override
  Future<Map<String, dynamic>> scanImage({
    required String imagePath,
    required double threshold,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>('scanImage', {
      'imagePath': imagePath,
      'threshold': threshold,
    });

    return _asStringDynamicMap(result);
  }

  @override
  Future<List<Map<String, dynamic>>> scanBatch({
    required String scanId,
    required List<String> imagePaths,
    required double threshold,
    required int maxConcurrency,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>('scanBatch', {
      'scanId': scanId,
      'imagePaths': imagePaths,
      'threshold': threshold,
      'maxConcurrency': maxConcurrency,
    });

    if (result is! List) {
      return const [];
    }

    return result
        .map<Map<String, dynamic>>(_asStringDynamicMap)
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
    final result = await methodChannel.invokeMethod<dynamic>('scanVideo', {
      'scanId': scanId,
      'videoPath': videoPath,
      'threshold': threshold,
      'sampleRateFps': sampleRateFps,
      'maxFrames': maxFrames,
      'dynamicSampleRate': dynamicSampleRate,
      'shortVideoMinSampleRateFps': shortVideoMinSampleRateFps,
      'shortVideoMaxSampleRateFps': shortVideoMaxSampleRateFps,
      'mediumVideoMinutesThreshold': mediumVideoMinutesThreshold,
      'longVideoMinutesThreshold': longVideoMinutesThreshold,
      'mediumVideoSampleRateFps': mediumVideoSampleRateFps,
      'longVideoSampleRateFps': longVideoSampleRateFps,
      'videoEarlyStopEnabled': videoEarlyStopEnabled,
      'videoEarlyStopBaseNsfwFrames': videoEarlyStopBaseNsfwFrames,
      'videoEarlyStopMediumBonusFrames': videoEarlyStopMediumBonusFrames,
      'videoEarlyStopLongBonusFrames': videoEarlyStopLongBonusFrames,
      'videoEarlyStopVeryLongMinutesThreshold':
          videoEarlyStopVeryLongMinutesThreshold,
      'videoEarlyStopVeryLongBonusFrames': videoEarlyStopVeryLongBonusFrames,
    });

    return _asStringDynamicMap(result);
  }

  @override
  Future<Map<String, dynamic>> scanMediaBatch({
    required String scanId,
    required List<Map<String, dynamic>> mediaItems,
    required Map<String, dynamic> settings,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>('scanMediaBatch', {
      'scanId': scanId,
      'mediaItems': mediaItems,
      'settings': settings,
    });
    return _asStringDynamicMap(result);
  }

  @override
  Future<Map<String, dynamic>> scanGallery({
    required String scanId,
    required Map<String, dynamic> settings,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>('scanGallery', {
      'scanId': scanId,
      'settings': settings,
    });
    return _asStringDynamicMap(result);
  }

  @override
  Future<String?> loadImageThumbnail({
    required String assetRef,
    required int width,
    required int height,
    required int quality,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>(
      'loadImageThumbnail',
      {
        'assetRef': assetRef,
        'width': width,
        'height': height,
        'quality': quality,
      },
    );
    return result?.toString();
  }

  @override
  Future<String?> loadImageAsset({required String assetRef}) async {
    final result = await methodChannel.invokeMethod<dynamic>('loadImageAsset', {
      'assetRef': assetRef,
    });
    return result?.toString();
  }

  @override
  Future<Map<String, dynamic>?> pickMedia({
    required bool multiple,
    required bool allowImages,
    required bool allowVideos,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>('pickMedia', {
      'multiple': multiple,
      'allowImages': allowImages,
      'allowVideos': allowVideos,
    });
    if (result == null) {
      return null;
    }
    return _asStringDynamicMap(result);
  }

  @override
  Future<bool> checkMediaPermission() async {
    final result = await methodChannel.invokeMethod<dynamic>(
      'checkMediaPermission',
    );
    return result == true;
  }

  @override
  Future<bool> requestMediaPermission() async {
    final result = await methodChannel.invokeMethod<dynamic>(
      'requestMediaPermission',
    );
    return result == true;
  }

  @override
  Future<Map<String, dynamic>?> resolveMediaAsset({
    required String assetId,
    required bool includeOriginFileFallback,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>(
      'resolveMediaAsset',
      {
        'assetId': assetId,
        'includeOriginFileFallback': includeOriginFileFallback,
      },
    );
    if (result == null) {
      return null;
    }
    return _asStringDynamicMap(result);
  }

  @override
  Future<Map<String, dynamic>> listGalleryAssets({
    required int start,
    required int end,
    required bool includeImages,
    required bool includeVideos,
  }) async {
    final result = await methodChannel.invokeMethod<dynamic>('listGalleryAssets', {
      'start': start,
      'end': end,
      'includeImages': includeImages,
      'includeVideos': includeVideos,
    });
    return _asStringDynamicMap(result);
  }

  @override
  Future<void> disposeScanner() async {
    await methodChannel.invokeMethod<void>('disposeScanner');
  }

  @override
  Future<void> cancelScan({String? scanId}) async {
    await methodChannel.invokeMethod<void>('cancelScan', {'scanId': scanId});
  }

  Map<String, dynamic> _asStringDynamicMap(dynamic value) {
    if (value is! Map) {
      return const {};
    }

    final parsed = <String, dynamic>{};
    for (final entry in value.entries) {
      parsed['${entry.key}'] = entry.value;
    }
    return parsed;
  }
}
