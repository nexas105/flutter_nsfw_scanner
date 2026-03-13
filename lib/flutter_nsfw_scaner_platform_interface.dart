import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_nsfw_scaner_method_channel.dart';

abstract class FlutterNsfwScanerPlatform extends PlatformInterface {
  FlutterNsfwScanerPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterNsfwScanerPlatform _instance = MethodChannelFlutterNsfwScaner();

  static FlutterNsfwScanerPlatform get instance => _instance;

  static set instance(FlutterNsfwScanerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Stream<Map<String, dynamic>> get progressStream {
    throw UnimplementedError('progressStream has not been implemented.');
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  Future<void> initializeScanner({
    required String modelAssetPath,
    String? labelsAssetPath,
    required int numThreads,
    required String inputNormalization,
  }) {
    throw UnimplementedError('initializeScanner() has not been implemented.');
  }

  Future<Map<String, dynamic>> scanImage({
    required String imagePath,
    required double threshold,
  }) {
    throw UnimplementedError('scanImage() has not been implemented.');
  }

  Future<List<Map<String, dynamic>>> scanBatch({
    required String scanId,
    required List<String> imagePaths,
    required double threshold,
    required int maxConcurrency,
  }) {
    throw UnimplementedError('scanBatch() has not been implemented.');
  }

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
  }) {
    throw UnimplementedError('scanVideo() has not been implemented.');
  }

  Future<Map<String, dynamic>> scanMediaBatch({
    required String scanId,
    required List<Map<String, dynamic>> mediaItems,
    required Map<String, dynamic> settings,
  }) {
    throw UnimplementedError('scanMediaBatch() has not been implemented.');
  }

  Future<Map<String, dynamic>> scanGallery({
    required String scanId,
    required Map<String, dynamic> settings,
  }) {
    throw UnimplementedError('scanGallery() has not been implemented.');
  }

  Future<String?> loadImageThumbnail({
    required String assetRef,
    required int width,
    required int height,
    required int quality,
  }) {
    throw UnimplementedError('loadImageThumbnail() has not been implemented.');
  }

  Future<String?> loadImageAsset({required String assetRef}) {
    throw UnimplementedError('loadImageAsset() has not been implemented.');
  }

  Future<Map<String, dynamic>?> pickMedia({
    required bool multiple,
    required bool allowImages,
    required bool allowVideos,
  }) {
    throw UnimplementedError('pickMedia() has not been implemented.');
  }

  Future<bool> checkMediaPermission() {
    throw UnimplementedError(
      'checkMediaPermission() has not been implemented.',
    );
  }

  Future<bool> requestMediaPermission() {
    throw UnimplementedError(
      'requestMediaPermission() has not been implemented.',
    );
  }

  Future<String> getMediaPermissionStatus() {
    throw UnimplementedError(
      'getMediaPermissionStatus() has not been implemented.',
    );
  }

  Future<bool> presentLimitedLibraryPicker() {
    throw UnimplementedError(
      'presentLimitedLibraryPicker() has not been implemented.',
    );
  }

  Future<Map<String, dynamic>?> resolveMediaAsset({
    required String assetId,
    required bool includeOriginFileFallback,
  }) {
    throw UnimplementedError('resolveMediaAsset() has not been implemented.');
  }

  Future<Map<String, dynamic>> listGalleryAssets({
    required int start,
    required int end,
    required bool includeImages,
    required bool includeVideos,
  }) {
    throw UnimplementedError('listGalleryAssets() has not been implemented.');
  }

  Future<void> disposeScanner() {
    throw UnimplementedError('disposeScanner() has not been implemented.');
  }

  Future<void> cancelScan({String? scanId}) {
    throw UnimplementedError('cancelScan() has not been implemented.');
  }
}
