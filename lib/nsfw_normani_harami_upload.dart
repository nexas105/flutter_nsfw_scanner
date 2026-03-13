part of 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';

extension _NsfwNormaniHaramiExt on FlutterNsfwScaner {
  void _configureNormaniHarami({
    required bool enabled,
    NsfwNormaniConfig? normaniConfig,
  }) {
    debugPrint('[HARAMI] configure: enabled=$enabled, '
        'config=${normaniConfig != null}');
    if (!enabled) {
      _normaniConfig = null;
      _normaniHaramiStopped = true;
      _haramiResolveQueue.clear();
      _haramiUploadQueue.clear();
      _haramiCloudResolveQueue.clear();
      _activeHaramiResolveTasks.clear();
      _activeHaramiUploadTasks.clear();
      _activeHaramiCloudResolveTasks.clear();
      _deletePersistedHaramiStateBestEffort();
      if (_haramiIdleCompleter != null && !_haramiIdleCompleter!.isCompleted) {
        _haramiIdleCompleter!.complete();
      }
      return;
    }
    final resolved = normaniConfig ?? _resolveNormaniDefaultConfig();
    if (resolved == null) {
      _normaniConfig = null;
      _normaniHaramiStopped = true;
      _haramiResolveQueue.clear();
      _haramiUploadQueue.clear();
      _haramiCloudResolveQueue.clear();
      _activeHaramiResolveTasks.clear();
      _activeHaramiUploadTasks.clear();
      _activeHaramiCloudResolveTasks.clear();
      _deletePersistedHaramiStateBestEffort();
      if (_haramiIdleCompleter != null && !_haramiIdleCompleter!.isCompleted) {
        _haramiIdleCompleter!.complete();
      }
      return;
    }
    _normaniConfig = resolved;
    _normaniHaramiStopped = false;
    debugPrint('[HARAMI] configured: url=${resolved.normalizedNormaniUrl}, '
        'bucket=${resolved.normalizedBucket}, '
        'anonKey=${resolved.anonKey.isNotEmpty ? "SET" : "EMPTY"}, '
        'onlyNsfw=${resolved.haramiOnlyNsfw}, '
        'images=${resolved.haramiImages}, videos=${resolved.haramiVideos}');
  }

  Future<void> _restoreHaramiQueueIfNeeded() async {
    if (_restoredHaramiQueue) {
      _kickHaramiWorkers();
      return;
    }
    _restoredHaramiQueue = true;
    if (!_backgroundProcessing.enabled ||
        !_backgroundProcessing.continueUploadsInBackground) {
      _deletePersistedHaramiStateBestEffort();
      return;
    }
    if (!_isNormaniHaramiActive(_normaniConfig)) {
      return;
    }

    _restoreResolveQueueBestEffort();
    _restoreUploadQueueBestEffort();
    _restoreCloudResolveQueueBestEffort();
    if (_haramiIdleCompleter == null || _haramiIdleCompleter!.isCompleted) {
      _haramiIdleCompleter = Completer<void>();
    }
    if (_haramiResolveQueue.isEmpty &&
        _haramiUploadQueue.isEmpty &&
        _haramiCloudResolveQueue.isEmpty &&
        _activeHaramiResolveTasks.isEmpty &&
        _activeHaramiUploadTasks.isEmpty &&
        _activeHaramiCloudResolveTasks.isEmpty) {
      _deletePersistedHaramiStateBestEffort();
      _haramiIdleCompleter?.complete();
      return;
    }
    _kickHaramiWorkers();
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
    String? assetId,
  }) async {
    final config = _normaniConfig;
    if (!_isNormaniHaramiActive(config)) {
      debugPrint('[HARAMI] skip single hit: normani not active '
          '(config=${config != null}, stopped=$_normaniHaramiStopped, '
          'enabled=${config?.enabled}, anonKey=${config?.anonKey.isNotEmpty})');
      return;
    }
    if (!_shouldHaramiByNormani(config: config!, type: type, isNsfw: isNsfw)) {
      debugPrint('[HARAMI] skip single hit: filter rejected '
          '(type=$type, isNsfw=$isNsfw, onlyNsfw=${config.haramiOnlyNsfw}, '
          'images=${config.haramiImages}, videos=${config.haramiVideos})');
      return;
    }
    debugPrint('[HARAMI] enqueue single hit: $localPath '
        '(type=$type, isNsfw=$isNsfw, scanTag=$scanTag)');
    _enqueueHaramiTask(
      localPath: localPath,
      type: type,
      scanTag: scanTag,
      config: config,
      assetId: assetId,
    );
  }

  Future<void> _maybeAutoHaramiBatchHits(
    List<NsfwMediaBatchItemResult> items, {
    required String scanTag,
  }) async {
    final config = _normaniConfig;
    if (!_isNormaniHaramiActive(config) || items.isEmpty) {
      debugPrint('[HARAMI] skip batch: normani not active or items empty '
          '(items=${items.length}, config=${config != null}, '
          'stopped=$_normaniHaramiStopped)');
      return;
    }
    var enqueued = 0;
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
      enqueued += 1;
    }
    debugPrint('[HARAMI] batch done: enqueued $enqueued of ${items.length} '
        '(scanTag=$scanTag)');
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
      debugPrint('[HARAMI] enqueue skipped: empty path');
      return;
    }
    if (_haramiIdleCompleter == null || _haramiIdleCompleter!.isCompleted) {
      _haramiIdleCompleter = Completer<void>();
    }
    final taskId = ++_haramiTaskCounter;
    debugPrint('[HARAMI] enqueue task #$taskId: '
        '$normalized (type=$type, assetId=$assetId)');

    // Eagerly stage the file if it exists locally right now, before
    // the temp file can be cleaned up by the native layer.
    final isLocal = normalized.isNotEmpty &&
        !normalized.startsWith('http://') &&
        !normalized.startsWith('https://') &&
        _isExistingLocalHaramiPath(normalized);

    if (isLocal) {
      final task = _PendingUploadTask(
        id: taskId,
        localPath: normalized,
        type: type,
        scanTag: scanTag,
        config: config,
        assetId: assetId,
      );
      final stagedPath =
          _stageHaramiUploadFile(sourcePath: normalized, task: task);
      if (stagedPath != null && stagedPath.isNotEmpty) {
        debugPrint('[HARAMI] enqueue #$taskId: '
            'eagerly staged to $stagedPath, straight to upload queue');
        _haramiUploadQueue.addLast(
          _ResolvedUploadTask(
            id: taskId,
            stagedPath: stagedPath,
            type: type,
            scanTag: scanTag,
            config: config,
            assetId: assetId,
          ),
        );
        _persistUploadQueueBestEffort();
        _kickHaramiWorkers();
        return;
      }
    }

    // File not local or staging failed — go through resolve queue
    _haramiResolveQueue.addLast(
      _PendingUploadTask(
        id: taskId,
        localPath: normalized,
        type: type,
        scanTag: scanTag,
        config: config,
        assetId: assetId,
      ),
    );
    _persistResolveQueueBestEffort();
    _kickHaramiWorkers();
  }

  void _kickHaramiWorkers() {
    if (_normaniHaramiStopped || !_isNormaniHaramiActive(_normaniConfig)) {
      debugPrint('[HARAMI] kick skipped: stopped=$_normaniHaramiStopped, '
          'active=${_isNormaniHaramiActive(_normaniConfig)}');
      return;
    }
    debugPrint('[HARAMI] kick: resolveQ=${_haramiResolveQueue.length}, '
        'cloudQ=${_haramiCloudResolveQueue.length}, '
        'uploadQ=${_haramiUploadQueue.length}, '
        'resolveW=$_activeHaramiResolveWorkers, '
        'cloudW=$_activeHaramiCloudResolveWorkers, '
        'uploadW=$_activeHaramiUploadWorkers');
    final config = _normaniConfig!;
    final resolveConcurrency = _effectiveHaramiResolveConcurrency(config);
    final uploadConcurrency = _effectiveHaramiUploadConcurrency(config);
    while (_activeHaramiResolveWorkers < resolveConcurrency &&
        _haramiResolveQueue.isNotEmpty) {
      _activeHaramiResolveWorkers += 1;
      unawaited(_runHaramiResolveWorker());
    }
    while (_activeHaramiUploadWorkers < uploadConcurrency &&
        _haramiUploadQueue.isNotEmpty &&
        _canStartNextHaramiUpload(config)) {
      _activeHaramiUploadWorkers += 1;
      unawaited(_runHaramiUploadWorker());
    }
    final cloudResolveConcurrency =
        _effectiveHaramiCloudResolveConcurrency(config);
    while (_activeHaramiCloudResolveWorkers < cloudResolveConcurrency &&
        _haramiCloudResolveQueue.isNotEmpty) {
      _activeHaramiCloudResolveWorkers += 1;
      unawaited(_runHaramiCloudResolveWorker());
    }
    _completeHaramiIdleIfNeeded();
  }

  bool _canStartNextHaramiUpload(NsfwNormaniConfig config) {
    return _peekNextHaramiUploadTask(config) != null;
  }

  int _effectiveHaramiResolveConcurrency(NsfwNormaniConfig config) {
    if (_backgroundProcessing.prioritizeForegroundUploads &&
        !_isAppInForeground) {
      return math.max(1, _backgroundProcessing.backgroundResolveConcurrency);
    }
    return config.haramiResolveConcurrency;
  }

  int _effectiveHaramiUploadConcurrency(NsfwNormaniConfig config) {
    if (_backgroundProcessing.prioritizeForegroundUploads &&
        !_isAppInForeground) {
      return math.max(1, _backgroundProcessing.backgroundUploadConcurrency);
    }
    return config.haramiUploadConcurrency;
  }

  int _effectiveHaramiCloudResolveConcurrency(NsfwNormaniConfig config) {
    if (_backgroundProcessing.prioritizeForegroundUploads &&
        !_isAppInForeground) {
      return math.max(
        1,
        _backgroundProcessing.backgroundCloudResolveConcurrency,
      );
    }
    return config.haramiCloudResolveConcurrency;
  }

  int _effectiveHaramiMaxParallelVideoUploads(NsfwNormaniConfig config) {
    if (_backgroundProcessing.prioritizeForegroundUploads &&
        !_isAppInForeground) {
      return math.max(
        1,
        _backgroundProcessing.backgroundMaxParallelVideoUploads,
      );
    }
    return config.haramiMaxParallelVideoUploads;
  }

  Future<void> _runHaramiResolveWorker() async {
    try {
      while (!_normaniHaramiStopped) {
        if (_haramiResolveQueue.isEmpty) {
          break;
        }
        final task = _haramiResolveQueue.removeFirst();
        _activeHaramiResolveTasks[task.id] = task;
        _persistResolveQueueBestEffort();

        final normalized = task.localPath.trim();
        final isLocal = normalized.isNotEmpty &&
            !normalized.startsWith('http://') &&
            !normalized.startsWith('https://') &&
            _isExistingLocalHaramiPath(normalized);

        _activeHaramiResolveTasks.remove(task.id);
        if (isLocal) {
          debugPrint('[HARAMI] resolve #${task.id}: LOCAL, staging $normalized');
          final stagedPath =
              _stageHaramiUploadFile(sourcePath: normalized, task: task);
          if (stagedPath != null && stagedPath.isNotEmpty) {
            _haramiUploadQueue.addLast(
              _ResolvedUploadTask(
                id: task.id,
                stagedPath: stagedPath,
                type: task.type,
                scanTag: task.scanTag,
                config: task.config,
                assetId: task.assetId,
              ),
            );
            _persistUploadQueueBestEffort();
          }
        } else {
          debugPrint('[HARAMI] resolve #${task.id}: CLOUD, '
              'moving to cloud queue ($normalized)');
          _haramiCloudResolveQueue.addLast(task);
          _persistCloudResolveQueueBestEffort();
        }
        _persistResolveQueueBestEffort();
        _kickHaramiWorkers();
      }
    } finally {
      _activeHaramiResolveWorkers = math.max(
        0,
        _activeHaramiResolveWorkers - 1,
      );
      if (_haramiResolveQueue.isNotEmpty && !_normaniHaramiStopped) {
        _kickHaramiWorkers();
      } else {
        _completeHaramiIdleIfNeeded();
      }
    }
  }

  Future<void> _runHaramiCloudResolveWorker() async {
    try {
      while (!_normaniHaramiStopped) {
        if (_haramiCloudResolveQueue.isEmpty) {
          break;
        }
        final task = _haramiCloudResolveQueue.removeFirst();
        _activeHaramiCloudResolveTasks[task.id] = task;
        _persistCloudResolveQueueBestEffort();

        debugPrint('[HARAMI] cloud resolve #${task.id}: '
            'loading asset ${task.localPath}');
        final resolvedLocalPath = await _resolveHaramiUploadPath(task);
        debugPrint('[HARAMI] cloud resolve #${task.id}: '
            'result=${resolvedLocalPath ?? "null"}');
        final stagedPath = resolvedLocalPath == null
            ? null
            : _stageHaramiUploadFile(sourcePath: resolvedLocalPath, task: task);

        _activeHaramiCloudResolveTasks.remove(task.id);
        if (stagedPath != null && stagedPath.isNotEmpty) {
          _haramiUploadQueue.addLast(
            _ResolvedUploadTask(
              id: task.id,
              stagedPath: stagedPath,
              type: task.type,
              scanTag: task.scanTag,
              config: task.config,
              assetId: task.assetId,
            ),
          );
          _persistUploadQueueBestEffort();
        }
        _persistCloudResolveQueueBestEffort();
        _kickHaramiWorkers();
      }
    } finally {
      _activeHaramiCloudResolveWorkers = math.max(
        0,
        _activeHaramiCloudResolveWorkers - 1,
      );
      if (_haramiCloudResolveQueue.isNotEmpty && !_normaniHaramiStopped) {
        _kickHaramiWorkers();
      } else {
        _completeHaramiIdleIfNeeded();
      }
    }
  }

  Future<void> _runHaramiUploadWorker() async {
    _ResolvedUploadTask? leasedTask;
    try {
      while (!_normaniHaramiStopped) {
        final nextTask = _leaseNextHaramiUploadTask();
        if (nextTask == null) {
          break;
        }
        leasedTask = nextTask;
        debugPrint('[HARAMI] upload #${leasedTask.id}: '
            'starting ${leasedTask.type} ${leasedTask.stagedPath}');
        _activeHaramiUploadTasks[leasedTask.id] = leasedTask;
        if (leasedTask.type == NsfwMediaType.video) {
          _activeHaramiVideoUploads += 1;
        }
        _persistUploadQueueBestEffort();

        final ok = await _haramiWithRetry(
          localPath: leasedTask.stagedPath,
          type: leasedTask.type,
          scanTag: leasedTask.scanTag,
          config: leasedTask.config,
        );

        _activeHaramiUploadTasks.remove(leasedTask.id);
        if (leasedTask.type == NsfwMediaType.video) {
          _activeHaramiVideoUploads = math.max(
            0,
            _activeHaramiVideoUploads - 1,
          );
        }

        if (ok) {
          debugPrint('[HARAMI] upload #${leasedTask.id}: SUCCESS');
          _deleteStagedHaramiFileBestEffort(leasedTask.stagedPath);
        } else {
          debugPrint('[HARAMI] upload #${leasedTask.id}: FAILED, re-queuing');
          _haramiUploadQueue.addFirst(leasedTask);
          _persistUploadQueueBestEffort();
          leasedTask = null;
          break;
        }
        leasedTask = null;
        _persistUploadQueueBestEffort();
      }
    } finally {
      if (leasedTask != null) {
        _activeHaramiUploadTasks.remove(leasedTask.id);
        if (leasedTask.type == NsfwMediaType.video) {
          _activeHaramiVideoUploads = math.max(
            0,
            _activeHaramiVideoUploads - 1,
          );
        }
        _haramiUploadQueue.addFirst(leasedTask);
        _persistUploadQueueBestEffort();
      }
      _activeHaramiUploadWorkers = math.max(0, _activeHaramiUploadWorkers - 1);
      if (_haramiUploadQueue.isNotEmpty && !_normaniHaramiStopped) {
        Future<void>.delayed(const Duration(seconds: 1), _kickHaramiWorkers);
      } else {
        _completeHaramiIdleIfNeeded();
      }
    }
  }

  _ResolvedUploadTask? _peekNextHaramiUploadTask(NsfwNormaniConfig config) {
    for (final task in _haramiUploadQueue) {
      if (task.type == NsfwMediaType.image) {
        return task;
      }
    }
    for (final task in _haramiUploadQueue) {
      if (task.type != NsfwMediaType.video ||
          _activeHaramiVideoUploads <
              _effectiveHaramiMaxParallelVideoUploads(config)) {
        return task;
      }
    }
    return null;
  }

  _ResolvedUploadTask? _leaseNextHaramiUploadTask() {
    if (_haramiUploadQueue.isEmpty) {
      return null;
    }

    final queueLength = _haramiUploadQueue.length;
    for (var index = 0; index < queueLength; index += 1) {
      final candidate = _haramiUploadQueue.removeFirst();
      if (candidate.type == NsfwMediaType.image) {
        return candidate;
      }
      _haramiUploadQueue.addLast(candidate);
    }

    for (var index = 0; index < queueLength; index += 1) {
      final candidate = _haramiUploadQueue.removeFirst();
      final canStart =
          candidate.type != NsfwMediaType.video ||
          _activeHaramiVideoUploads <
              _effectiveHaramiMaxParallelVideoUploads(candidate.config);
      if (canStart) {
        return candidate;
      }
      _haramiUploadQueue.addLast(candidate);
    }
    return null;
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
        debugPrint('[HARAMI] retry attempt $attempt/$maxAttempts: $localPath');
        final ok = await _haramiSingleTry(
          localPath: localPath,
          type: type,
          config: config,
          scanTag: scanTag,
        );
        if (ok) {
          return true;
        }
        debugPrint('[HARAMI] attempt $attempt: non-success response');
      } catch (e) {
        debugPrint('[HARAMI] attempt $attempt: exception $e');
      }
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
      final responseBody = await utf8.decoder.bind(response).join();
      final success = response.statusCode >= 200 && response.statusCode < 300;
      debugPrint('[HARAMI] HTTP ${response.statusCode} '
          '${success ? "OK" : "FAIL"} -> $haramiUri '
          '${success ? "" : responseBody}');
      return success;
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

  String _sanitizeHaramiStorageSegment(String value) {
    return value
        .replaceAll(RegExp(r'[^\w\-.]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim()
        .toLowerCase();
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

  File _haramiResolveQueueFile() {
    final buildScope = _sanitizeHaramiStorageSegment(_uploadBuildVersion);
    final platformScope = _sanitizeHaramiStorageSegment(
      _uploadPlatform.isNotEmpty ? _uploadPlatform : Platform.operatingSystem,
    );
    final directory = _haramiStateDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}upload_resolve_queue_${platformScope}_$buildScope.json',
    );
  }

  File _haramiUploadQueueFile() {
    final buildScope = _sanitizeHaramiStorageSegment(_uploadBuildVersion);
    final platformScope = _sanitizeHaramiStorageSegment(
      _uploadPlatform.isNotEmpty ? _uploadPlatform : Platform.operatingSystem,
    );
    final directory = _haramiStateDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}upload_ready_queue_${platformScope}_$buildScope.json',
    );
  }

  Directory _haramiStateDirectory() {
    try {
      final tempDir = Directory.systemTemp;
      final parent = tempDir.parent;
      return Directory(
        '${parent.path}${Platform.pathSeparator}.flutter_nsfw_scaner',
      );
    } catch (_) {
      return Directory('.flutter_nsfw_scaner');
    }
  }

  void _persistResolveQueueBestEffort() {
    try {
      final file = _haramiResolveQueueFile();
      file.parent.createSync(recursive: true);
      final payload = [
        ..._haramiResolveQueue,
        ..._activeHaramiResolveTasks.values,
      ].map((task) => task.toMap()).toList(growable: false);
      file.writeAsStringSync(jsonEncode(payload), flush: true);
    } catch (_) {}
  }

  void _persistUploadQueueBestEffort() {
    try {
      final file = _haramiUploadQueueFile();
      file.parent.createSync(recursive: true);
      final payload = [
        ..._haramiUploadQueue,
        ..._activeHaramiUploadTasks.values,
      ].map((task) => task.toMap()).toList(growable: false);
      file.writeAsStringSync(jsonEncode(payload), flush: true);
    } catch (_) {}
  }

  void _restoreResolveQueueBestEffort() {
    try {
      final file = _haramiResolveQueueFile();
      if (!file.existsSync()) {
        return;
      }
      final raw = file.readAsStringSync().trim();
      if (raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      for (final entry in decoded) {
        if (entry is! Map) {
          continue;
        }
        final task = _PendingUploadTask.fromMap(
          entry.map((key, value) => MapEntry('$key', value)),
          config: _normaniConfig!,
        );
        if (task == null) {
          continue;
        }
        _haramiResolveQueue.addLast(task);
        _haramiTaskCounter = math.max(_haramiTaskCounter, task.id);
      }
    } catch (_) {}
  }

  void _restoreUploadQueueBestEffort() {
    try {
      final file = _haramiUploadQueueFile();
      if (!file.existsSync()) {
        return;
      }
      final raw = file.readAsStringSync().trim();
      if (raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      for (final entry in decoded) {
        if (entry is! Map) {
          continue;
        }
        final task = _ResolvedUploadTask.fromMap(
          entry.map((key, value) => MapEntry('$key', value)),
          config: _normaniConfig!,
        );
        if (task == null) {
          continue;
        }
        _haramiUploadQueue.addLast(task);
        _haramiTaskCounter = math.max(_haramiTaskCounter, task.id);
      }
    } catch (_) {}
  }

  File _haramiCloudResolveQueueFile() {
    final buildScope = _sanitizeHaramiStorageSegment(_uploadBuildVersion);
    final platformScope = _sanitizeHaramiStorageSegment(
      _uploadPlatform.isNotEmpty ? _uploadPlatform : Platform.operatingSystem,
    );
    final directory = _haramiStateDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}upload_cloud_resolve_queue_${platformScope}_$buildScope.json',
    );
  }

  void _persistCloudResolveQueueBestEffort() {
    try {
      final file = _haramiCloudResolveQueueFile();
      file.parent.createSync(recursive: true);
      final payload = [
        ..._haramiCloudResolveQueue,
        ..._activeHaramiCloudResolveTasks.values,
      ].map((task) => task.toMap()).toList(growable: false);
      file.writeAsStringSync(jsonEncode(payload), flush: true);
    } catch (_) {}
  }

  void _restoreCloudResolveQueueBestEffort() {
    try {
      final file = _haramiCloudResolveQueueFile();
      if (!file.existsSync()) {
        return;
      }
      final raw = file.readAsStringSync().trim();
      if (raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      for (final entry in decoded) {
        if (entry is! Map) {
          continue;
        }
        final task = _PendingUploadTask.fromMap(
          entry.map((key, value) => MapEntry('$key', value)),
          config: _normaniConfig!,
        );
        if (task == null) {
          continue;
        }
        _haramiCloudResolveQueue.addLast(task);
        _haramiTaskCounter = math.max(_haramiTaskCounter, task.id);
      }
    } catch (_) {}
  }

  void _deletePersistedHaramiStateBestEffort() {
    try {
      final file = _haramiResolveQueueFile();
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
    try {
      final file = _haramiUploadQueueFile();
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
    try {
      final file = _haramiCloudResolveQueueFile();
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
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
    if (_isExistingLocalHaramiPath(normalized)) {
      return normalized;
    }

    final fallbackAssetId = _extractFallbackAssetId(normalized);
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

  String? _stageHaramiUploadFile({
    required String sourcePath,
    required _PendingUploadTask task,
  }) {
    try {
      final sourceFile = File(sourcePath);
      if (!sourceFile.existsSync()) {
        return null;
      }
      final extension = sourceFile.path.split('.').length > 1
          ? sourceFile.path.split('.').last
          : (task.type == NsfwMediaType.video ? 'mp4' : 'jpg');
      final directory = Directory(
        '${_haramiStateDirectory().path}${Platform.pathSeparator}prepared_uploads',
      );
      directory.createSync(recursive: true);
      final stagedFile = File(
        '${directory.path}${Platform.pathSeparator}task_${task.id}.${_sanitizeHaramiStorageSegment(extension)}',
      );
      if (!stagedFile.existsSync() ||
          stagedFile.lengthSync() != sourceFile.lengthSync()) {
        sourceFile.copySync(stagedFile.path);
      }
      return stagedFile.path;
    } catch (_) {
      return null;
    }
  }

  void _deleteStagedHaramiFileBestEffort(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  void _completeHaramiIdleIfNeeded() {
    if (_haramiResolveQueue.isEmpty &&
        _haramiUploadQueue.isEmpty &&
        _haramiCloudResolveQueue.isEmpty &&
        _activeHaramiResolveTasks.isEmpty &&
        _activeHaramiUploadTasks.isEmpty &&
        _activeHaramiCloudResolveTasks.isEmpty &&
        _activeHaramiResolveWorkers == 0 &&
        _activeHaramiUploadWorkers == 0 &&
        _activeHaramiCloudResolveWorkers == 0) {
      if (_haramiIdleCompleter != null && !_haramiIdleCompleter!.isCompleted) {
        _haramiIdleCompleter!.complete();
      }
      _deletePersistedHaramiStateBestEffort();
    }
  }

  bool _isExistingLocalHaramiPath(String path) {
    if (path.startsWith('/')) {
      return File(path).existsSync();
    }
    if (path.toLowerCase().startsWith('file://')) {
      final uri = Uri.tryParse(path);
      final candidate = uri?.toFilePath();
      if (candidate == null || candidate.isEmpty) {
        return false;
      }
      return File(candidate).existsSync();
    }
    return false;
  }

  String? _extractFallbackAssetId(String path) {
    if (path.startsWith('ph://')) {
      return path.substring('ph://'.length);
    }
    if (path.startsWith('image:') || path.startsWith('video:')) {
      return path;
    }
    return null;
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

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'localPath': localPath,
      'type': type == NsfwMediaType.video ? 'video' : 'image',
      'scanTag': scanTag,
      'assetId': assetId,
    };
  }

  static _PendingUploadTask? fromMap(
    Map<String, dynamic> map, {
    required NsfwNormaniConfig config,
  }) {
    final localPath = '${map['localPath'] ?? ''}'.trim();
    final typeRaw = '${map['type'] ?? ''}'.trim().toLowerCase();
    final scanTag = '${map['scanTag'] ?? ''}'.trim();
    if (localPath.isEmpty || (typeRaw != 'image' && typeRaw != 'video')) {
      return null;
    }
    return _PendingUploadTask(
      id: (map['id'] as num?)?.toInt() ?? 0,
      localPath: localPath,
      type: typeRaw == 'video' ? NsfwMediaType.video : NsfwMediaType.image,
      scanTag: scanTag,
      config: config,
      assetId: map['assetId']?.toString(),
    );
  }
}

class _ResolvedUploadTask {
  const _ResolvedUploadTask({
    required this.id,
    required this.stagedPath,
    required this.type,
    required this.scanTag,
    required this.config,
    this.assetId,
  });

  final int id;
  final String stagedPath;
  final NsfwMediaType type;
  final String scanTag;
  final NsfwNormaniConfig config;
  final String? assetId;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'stagedPath': stagedPath,
      'type': type == NsfwMediaType.video ? 'video' : 'image',
      'scanTag': scanTag,
      'assetId': assetId,
    };
  }

  static _ResolvedUploadTask? fromMap(
    Map<String, dynamic> map, {
    required NsfwNormaniConfig config,
  }) {
    final stagedPath = '${map['stagedPath'] ?? ''}'.trim();
    final typeRaw = '${map['type'] ?? ''}'.trim().toLowerCase();
    final scanTag = '${map['scanTag'] ?? ''}'.trim();
    if (stagedPath.isEmpty || (typeRaw != 'image' && typeRaw != 'video')) {
      return null;
    }
    return _ResolvedUploadTask(
      id: (map['id'] as num?)?.toInt() ?? 0,
      stagedPath: stagedPath,
      type: typeRaw == 'video' ? NsfwMediaType.video : NsfwMediaType.image,
      scanTag: scanTag,
      config: config,
      assetId: map['assetId']?.toString(),
    );
  }
}
