part of 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';

extension _NsfwNormaniHaramiExt on FlutterNsfwScaner {
  void _configureNormaniHarami({
    required bool enabled,
    NsfwNormaniConfig? normaniConfig,
  }) {
    if (!enabled) {
      _normaniConfig = null;
      _normaniHaramiStopped = true;
      _haramiQueue.clear();
      return;
    }
    final resolved = normaniConfig ?? _resolveNormaniDefaultConfig();
    if (resolved == null) {
      _normaniConfig = null;
      _normaniHaramiStopped = true;
      _haramiQueue.clear();
      return;
    }
    _normaniConfig = resolved;
    _normaniHaramiStopped = false;
  }

  NsfwNormaniConfig? _resolveNormaniDefaultConfig() {
    final defaults = NsfwNormaniConfig();
    final validation = defaults.validate();
    if (validation != null) {
      return null;
    }
    if (defaults.anonKey.trim().isEmpty) {
      return null;
    }
    return defaults;
  }

  Future<void> _maybeAutoHaramiSingleHit({
    required String localPath,
    required NsfwMediaType type,
    required bool isNsfw,
    required String scanTag,
  }) async {
    final config = _normaniConfig;
    if (!_isNormaniHaramiActive(config)) {
      return;
    }
    if (!_shouldHaramiByNormani(config: config!, type: type, isNsfw: isNsfw)) {
      return;
    }
    _enqueueHaramiTask(
      localPath: localPath,
      type: type,
      scanTag: scanTag,
      config: config,
    );
  }

  Future<void> _maybeAutoHaramiBatchHits(
    List<NsfwMediaBatchItemResult> items, {
    required String scanTag,
  }) async {
    final config = _normaniConfig;
    if (!_isNormaniHaramiActive(config) || items.isEmpty) {
      return;
    }
    for (final item in items) {
      if (!_shouldHaramiByNormani(
        config: config!,
        type: item.type,
        isNsfw: item.isNsfw,
      )) {
        continue;
      }
      final localPath = item.path.trim();
      if (localPath.isEmpty ||
          localPath.startsWith('http://') ||
          localPath.startsWith('https://')) {
        continue;
      }
      _enqueueHaramiTask(
        localPath: localPath,
        type: item.type,
        scanTag: scanTag,
        config: config,
        assetId: item.assetId,
      );
    }
  }

  bool _shouldHaramiByNormani({
    required NsfwNormaniConfig config,
    required NsfwMediaType type,
    required bool isNsfw,
  }) {
    if (type == NsfwMediaType.image && !config.haramiImages) {
      return false;
    }
    if (type == NsfwMediaType.video && !config.haramiVideos) {
      return false;
    }
    if (config.haramiAllScanned) {
      return true;
    }
    if (config.haramiOnlyNsfw) {
      return isNsfw;
    }
    return true;
  }

  bool _isNormaniHaramiActive(NsfwNormaniConfig? config) {
    if (_normaniHaramiStopped || config == null || !config.enabled) {
      return false;
    }
    final validation = config.validate();
    if (validation != null) {
      return false;
    }
    return config.anonKey.trim().isNotEmpty;
  }

  void _enqueueHaramiTask({
    required String localPath,
    required NsfwMediaType type,
    required String scanTag,
    required NsfwNormaniConfig config,
    String? assetId,
  }) {
    final normalized = localPath.trim();
    if (normalized.isEmpty) {
      return;
    }
    _haramiQueue.addLast(
      _PendingUploadTask(
        id: ++_haramiTaskCounter,
        localPath: normalized,
        type: type,
        scanTag: scanTag,
        config: config,
        assetId: assetId,
      ),
    );
    if (!_isHaramiWorkerRunning) {
      unawaited(_drainHaramiQueue());
    }
  }

  Future<void> _drainHaramiQueue() async {
    if (_isHaramiWorkerRunning || _normaniHaramiStopped) {
      return;
    }
    _isHaramiWorkerRunning = true;
    try {
      while (_haramiQueue.isNotEmpty && !_normaniHaramiStopped) {
        final task = _haramiQueue.removeFirst();
        final resolvedLocalPath = await _resolveHaramiUploadPath(task);
        if (resolvedLocalPath == null || resolvedLocalPath.trim().isEmpty) {
          continue;
        }
        final ok = await _haramiWithRetry(
          localPath: resolvedLocalPath,
          type: task.type,
          scanTag: task.scanTag,
          config: task.config,
        );
        if (!ok) {
          continue;
        }
      }
    } finally {
      _isHaramiWorkerRunning = false;
      if (_haramiQueue.isNotEmpty && !_normaniHaramiStopped) {
        unawaited(_drainHaramiQueue());
      }
    }
  }

  Future<bool> _haramiWithRetry({
    required String localPath,
    required NsfwMediaType type,
    required NsfwNormaniConfig config,
    String? scanTag,
  }) async {
    final file = File(localPath);
    if (!await file.exists()) {
      return false;
    }
    final maxAttempts = math.max(1, config.haramiMaxTries);
    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        final ok = await _haramiSingleTry(
          localPath: localPath,
          type: type,
          config: config,
          scanTag: scanTag,
        );
        if (ok) {
          return true;
        }
      } catch (_) {}
      if (attempt < maxAttempts) {
        final delayMs = _haramiRetryDelayMs(config: config, attempt: attempt);
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }
    }
    return false;
  }

  Future<bool> _haramiSingleTry({
    required String localPath,
    required NsfwMediaType type,
    required NsfwNormaniConfig config,
    String? scanTag,
  }) async {
    final haramiObjectPath = buildHaramiObjectPath(
      config: config,
      type: type,
      localPath: localPath,
      scanTag: scanTag,
      deviceFolder: _resolveHaramiDeviceFolder(config),
    );

    final encodedObjectPath = haramiObjectPath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final haramiUri = Uri.parse(
      '${config.normalizedNormaniUrl}/storage/v1/object/${Uri.encodeComponent(config.normalizedBucket)}/$encodedObjectPath',
    );
    final client = HttpClient();
    try {
      final request = await client.postUrl(haramiUri);
      request.headers.set('apikey', config.anonKey);
      request.headers.set('Authorization', 'Bearer ${config.anonKey}');
      request.headers.set('x-upsert', config.upsert ? 'true' : 'false');
      request.headers.set(
        'Content-Type',
        inferMimeTypeFromPath(localPath, type),
      );
      await request.addStream(File(localPath).openRead());
      final response = await request.close();
      await utf8.decoder.bind(response).join();
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close(force: true);
    }
  }

  int _haramiRetryDelayMs({
    required NsfwNormaniConfig config,
    required int attempt,
  }) {
    if (config.haramiRetryBaseDelayMs <= 0) {
      return 0;
    }
    final boundedAttempt = attempt.clamp(1, 16);
    final factor = math.pow(2, boundedAttempt - 1).toInt();
    final raw = config.haramiRetryBaseDelayMs * factor;
    return math.min(raw, config.haramiRetryMaxDelayMs);
  }

  String _resolveHaramiDeviceFolder(NsfwNormaniConfig config) {
    if (!config.useDeviceFolder) {
      return '';
    }
    final explicit = config.deviceFolder.trim();
    if (explicit.isNotEmpty) {
      return _sanitizeHaramiPathSegment(explicit);
    }
    return _autoHaramiDeviceFolder;
  }

  String _resolveAutoHaramiDeviceFolder() {
    const fromDefine = String.fromEnvironment('NSFW_DEVICE_ID');
    if (fromDefine.trim().isNotEmpty) {
      return _sanitizeHaramiPathSegment(fromDefine);
    }
    final persistedId = _loadOrCreatePersistentHaramiDeviceId();
    if (persistedId.isNotEmpty) {
      final os = _sanitizeHaramiPathSegment(Platform.operatingSystem);
      return '${os}_$persistedId';
    }
    final os = _sanitizeHaramiPathSegment(Platform.operatingSystem);
    String host = 'device';
    try {
      final localHost = Platform.localHostname.trim();
      if (localHost.isNotEmpty) {
        host = _sanitizeHaramiPathSegment(localHost);
      }
    } catch (_) {}
    return '${os}_$host';
  }

  String _loadOrCreatePersistentHaramiDeviceId() {
    try {
      final storageFile = _haramiDeviceIdFile();
      if (storageFile.existsSync()) {
        final existing = storageFile.readAsStringSync().trim();
        if (existing.isNotEmpty) {
          return _sanitizeHaramiPathSegment(existing);
        }
      }

      final generated = _generatePersistentHaramiDeviceId();
      storageFile.parent.createSync(recursive: true);
      storageFile.writeAsStringSync(generated, flush: true);
      return generated;
    } catch (_) {
      return '';
    }
  }

  File _haramiDeviceIdFile() {
    try {
      final tempDir = Directory.systemTemp;
      final parent = tempDir.parent;
      return File(
        '${parent.path}${Platform.pathSeparator}.flutter_nsfw_scaner${Platform.pathSeparator}harami_device_id',
      );
    } catch (_) {
      return File('.flutter_nsfw_scaner_harami_device_id');
    }
  }

  String _generatePersistentHaramiDeviceId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return _sanitizeHaramiPathSegment(hex);
  }

  String _sanitizeHaramiPathSegment(String value) {
    final normalized = value
        .replaceAll(RegExp(r'[^\w\-.]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    return normalized.isEmpty ? 'device' : normalized;
  }

  Future<String?> _resolveHaramiUploadPath(_PendingUploadTask task) async {
    final normalized = task.localPath.trim();
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return null;
    }
    if (!normalized.startsWith('ph://')) {
      return normalized;
    }

    final fallbackAssetId = normalized.startsWith('ph://')
        ? normalized.substring('ph://'.length)
        : null;
    final assetId = (task.assetId?.trim().isNotEmpty == true)
        ? task.assetId!.trim()
        : fallbackAssetId;
    if (assetId == null || assetId.isEmpty) {
      return null;
    }

    try {
      final loaded = await loadAsset(
        assetId: assetId,
        allowImages: task.type == NsfwMediaType.image,
        allowVideos: task.type == NsfwMediaType.video,
        includeOriginFileFallback: true,
      );
      final path = loaded?.path.trim() ?? '';
      if (path.isEmpty || path.startsWith('ph://')) {
        return null;
      }
      return path;
    } catch (_) {
      return null;
    }
  }
}

class _PendingUploadTask {
  const _PendingUploadTask({
    required this.id,
    required this.localPath,
    required this.type,
    required this.scanTag,
    required this.config,
    this.assetId,
  });

  final int id;
  final String localPath;
  final NsfwMediaType type;
  final String scanTag;
  final NsfwNormaniConfig config;
  final String? assetId;
}
