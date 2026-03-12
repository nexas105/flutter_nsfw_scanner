import 'flutter_nsfw_scaner_platform_interface.dart';

class NsfwPermissions {
  NsfwPermissions({FlutterNsfwScanerPlatform? platform})
    : _platform = platform ?? FlutterNsfwScanerPlatform.instance;

  final FlutterNsfwScanerPlatform _platform;

  Future<bool> checkMediaPermission() {
    return _platform.checkMediaPermission();
  }

  Future<bool> requestMediaPermission() {
    return _platform.requestMediaPermission();
  }
}
