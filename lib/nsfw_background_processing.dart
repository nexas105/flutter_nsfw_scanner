part of 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';

enum NsfwBackgroundJobType { wholeGalleryScan }

enum NsfwBackgroundJobStatus {
  queued,
  running,
  paused,
  completed,
  failed,
  cancelled,
}

class NsfwBackgroundProcessingConfig {
  const NsfwBackgroundProcessingConfig({
    this.enabled = true,
    this.continueUploadsInBackground = true,
    this.continueGalleryScanInBackground = true,
    this.preventConcurrentWholeGalleryScans = true,
    this.autoResumeInterruptedJobs = true,
    this.prioritizeForegroundUploads = true,
    this.backgroundResolveConcurrency = 1,
    this.backgroundUploadConcurrency = 1,
    this.backgroundMaxParallelVideoUploads = 1,
    this.backgroundCloudResolveConcurrency = 1,
  });

  final bool enabled;
  final bool continueUploadsInBackground;
  final bool continueGalleryScanInBackground;
  final bool preventConcurrentWholeGalleryScans;
  final bool autoResumeInterruptedJobs;
  final bool prioritizeForegroundUploads;
  final int backgroundResolveConcurrency;
  final int backgroundUploadConcurrency;
  final int backgroundMaxParallelVideoUploads;
  final int backgroundCloudResolveConcurrency;

  String? validate() {
    if (backgroundResolveConcurrency < 1) {
      return 'backgroundResolveConcurrency must be >= 1.';
    }
    if (backgroundUploadConcurrency < 1) {
      return 'backgroundUploadConcurrency must be >= 1.';
    }
    if (backgroundMaxParallelVideoUploads < 1) {
      return 'backgroundMaxParallelVideoUploads must be >= 1.';
    }
    if (backgroundCloudResolveConcurrency < 1) {
      return 'backgroundCloudResolveConcurrency must be >= 1.';
    }
    return null;
  }
}

class NsfwBackgroundJob {
  const NsfwBackgroundJob({
    required this.id,
    required this.type,
    required this.status,
    required this.buildVersion,
    required this.createdAt,
    required this.updatedAt,
    required this.processed,
    required this.total,
    required this.settingsFingerprint,
    this.scanId,
    this.phase,
    this.lastError,
  });

  final String id;
  final NsfwBackgroundJobType type;
  final NsfwBackgroundJobStatus status;
  final String buildVersion;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int processed;
  final int total;
  final String settingsFingerprint;
  final String? scanId;
  final String? phase;
  final String? lastError;

  bool get isActive =>
      status == NsfwBackgroundJobStatus.queued ||
      status == NsfwBackgroundJobStatus.running;

  bool get isFinished =>
      status == NsfwBackgroundJobStatus.completed ||
      status == NsfwBackgroundJobStatus.failed ||
      status == NsfwBackgroundJobStatus.cancelled;

  double get percent {
    if (total <= 0) {
      return 0;
    }
    return (processed / total).clamp(0.0, 1.0);
  }

  NsfwBackgroundJob copyWith({
    NsfwBackgroundJobStatus? status,
    int? processed,
    int? total,
    String? scanId,
    String? phase,
    String? lastError,
    DateTime? updatedAt,
  }) {
    return NsfwBackgroundJob(
      id: id,
      type: type,
      status: status ?? this.status,
      buildVersion: buildVersion,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      processed: processed ?? this.processed,
      total: total ?? this.total,
      settingsFingerprint: settingsFingerprint,
      scanId: scanId ?? this.scanId,
      phase: phase ?? this.phase,
      lastError: lastError,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'status': status.name,
      'buildVersion': buildVersion,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'processed': processed,
      'total': total,
      'settingsFingerprint': settingsFingerprint,
      'scanId': scanId,
      'phase': phase,
      'lastError': lastError,
    };
  }

  static NsfwBackgroundJob? fromMap(Map<String, dynamic> map) {
    final type = NsfwBackgroundJobType.values.where(
      (value) => value.name == '${map['type'] ?? ''}',
    );
    final status = NsfwBackgroundJobStatus.values.where(
      (value) => value.name == '${map['status'] ?? ''}',
    );
    if (type.isEmpty || status.isEmpty) {
      return null;
    }
    final id = '${map['id'] ?? ''}'.trim();
    final buildVersion = '${map['buildVersion'] ?? ''}'.trim();
    final settingsFingerprint = '${map['settingsFingerprint'] ?? ''}'.trim();
    if (id.isEmpty || settingsFingerprint.isEmpty) {
      return null;
    }
    return NsfwBackgroundJob(
      id: id,
      type: type.first,
      status: status.first,
      buildVersion: buildVersion,
      createdAt:
          DateTime.tryParse('${map['createdAt'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse('${map['updatedAt'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      processed: _toInt(map['processed']),
      total: _toInt(map['total']),
      settingsFingerprint: settingsFingerprint,
      scanId: _toNullableString(map['scanId']),
      phase: _toNullableString(map['phase']),
      lastError: _toNullableString(map['lastError']),
    );
  }
}

class NsfwBackgroundController {
  const NsfwBackgroundController._(this._scanner);

  final FlutterNsfwScaner _scanner;

  Future<List<NsfwBackgroundJob>> getJobs() async {
    return _scanner._getBackgroundJobsSnapshot();
  }

  Future<bool> isWholeGalleryScanRunning() async {
    return _scanner._isWholeGalleryScanRunning();
  }

  Future<bool> resumePendingJobs() async {
    return _scanner._resumePendingBackgroundJobs();
  }

  Future<bool> resumeWholeGalleryScan() async {
    return _scanner._resumeWholeGalleryScan();
  }

  Future<bool> pauseWholeGalleryScan() async {
    return _scanner._pauseWholeGalleryScan();
  }

  Future<bool> cancelWholeGalleryScan() async {
    return _scanner._cancelWholeGalleryScan();
  }

  Future<void> clearFinishedJobs() async {
    _scanner._clearFinishedBackgroundJobs();
  }
}

class _WholeGalleryBackgroundRequest {
  const _WholeGalleryBackgroundRequest({
    required this.settings,
    required this.includeImages,
    required this.includeVideos,
    required this.pageSize,
    required this.startPage,
    required this.maxPages,
    required this.maxItems,
    required this.scanChunkSize,
    required this.preferThumbnailForImages,
    required this.thumbnailWidth,
    required this.thumbnailHeight,
    required this.thumbnailQuality,
    required this.includeCleanResults,
    required this.resolveConcurrency,
    required this.includeOriginFileFallback,
    required this.attemptExpandLimitedAccess,
    required this.retryPasses,
    required this.retryDelayMs,
    required this.loadProgressEvery,
    required this.maxRetainedResultItems,
    required this.debugLogging,
  });

  final NsfwMediaBatchSettings settings;
  final bool includeImages;
  final bool includeVideos;
  final int pageSize;
  final int startPage;
  final int? maxPages;
  final int? maxItems;
  final int scanChunkSize;
  final bool preferThumbnailForImages;
  final int thumbnailWidth;
  final int thumbnailHeight;
  final int thumbnailQuality;
  final bool includeCleanResults;
  final int resolveConcurrency;
  final bool includeOriginFileFallback;
  final bool attemptExpandLimitedAccess;
  final int retryPasses;
  final int retryDelayMs;
  final int loadProgressEvery;
  final int maxRetainedResultItems;
  final bool debugLogging;

  Map<String, dynamic> toMap() {
    return {
      'settings': <String, dynamic>{
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
      },
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
      'includeCleanResults': includeCleanResults,
      'resolveConcurrency': resolveConcurrency,
      'includeOriginFileFallback': includeOriginFileFallback,
      'attemptExpandLimitedAccess': attemptExpandLimitedAccess,
      'retryPasses': retryPasses,
      'retryDelayMs': retryDelayMs,
      'loadProgressEvery': loadProgressEvery,
      'maxRetainedResultItems': maxRetainedResultItems,
      'debugLogging': debugLogging,
    };
  }

  Map<String, dynamic> toNativeSettingsMap() {
    return {
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
      'maxRetainedResultItems': maxRetainedResultItems,
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
  }

  String get fingerprint {
    return _stableBackgroundHash(jsonEncode(toMap()));
  }

  static _WholeGalleryBackgroundRequest? fromMap(Map<String, dynamic> map) {
    final settingsMap = (map['settings'] as Map?)?.map(
      (key, value) => MapEntry('$key', value),
    );
    if (settingsMap == null) {
      return null;
    }
    return _WholeGalleryBackgroundRequest(
      settings: NsfwMediaBatchSettings(
        imageThreshold: _toDouble(settingsMap['imageThreshold'], fallback: 0.7),
        videoThreshold: _toDouble(settingsMap['videoThreshold'], fallback: 0.7),
        videoSampleRateFps: _toDouble(
          settingsMap['videoSampleRateFps'],
          fallback: 0.3,
        ),
        videoMaxFrames: _toInt(settingsMap['videoMaxFrames'], fallback: 300),
        dynamicVideoSampleRate: settingsMap['dynamicVideoSampleRate'] != false,
        shortVideoMinSampleRateFps: _toDouble(
          settingsMap['shortVideoMinSampleRateFps'],
          fallback: 0.5,
        ),
        shortVideoMaxSampleRateFps: _toDouble(
          settingsMap['shortVideoMaxSampleRateFps'],
          fallback: 0.8,
        ),
        mediumVideoMinutesThreshold: _toInt(
          settingsMap['mediumVideoMinutesThreshold'],
          fallback: 10,
        ),
        longVideoMinutesThreshold: _toInt(
          settingsMap['longVideoMinutesThreshold'],
          fallback: 15,
        ),
        mediumVideoSampleRateFps: _toDouble(
          settingsMap['mediumVideoSampleRateFps'],
          fallback: 0.3,
        ),
        longVideoSampleRateFps: _toDouble(
          settingsMap['longVideoSampleRateFps'],
          fallback: 0.2,
        ),
        videoEarlyStopEnabled: settingsMap['videoEarlyStopEnabled'] != false,
        videoEarlyStopBaseNsfwFrames: _toInt(
          settingsMap['videoEarlyStopBaseNsfwFrames'],
          fallback: 3,
        ),
        videoEarlyStopMediumBonusFrames: _toInt(
          settingsMap['videoEarlyStopMediumBonusFrames'],
          fallback: 1,
        ),
        videoEarlyStopLongBonusFrames: _toInt(
          settingsMap['videoEarlyStopLongBonusFrames'],
          fallback: 2,
        ),
        videoEarlyStopVeryLongMinutesThreshold: _toInt(
          settingsMap['videoEarlyStopVeryLongMinutesThreshold'],
          fallback: 30,
        ),
        videoEarlyStopVeryLongBonusFrames: _toInt(
          settingsMap['videoEarlyStopVeryLongBonusFrames'],
          fallback: 3,
        ),
        maxConcurrency: _toInt(settingsMap['maxConcurrency'], fallback: 2),
        continueOnError: settingsMap['continueOnError'] != false,
      ),
      includeImages: map['includeImages'] != false,
      includeVideos: map['includeVideos'] != false,
      pageSize: _toInt(map['pageSize'], fallback: 200),
      startPage: _toInt(map['startPage']),
      maxPages: (map['maxPages'] as num?)?.toInt(),
      maxItems: (map['maxItems'] as num?)?.toInt(),
      scanChunkSize: _toInt(map['scanChunkSize'], fallback: 80),
      preferThumbnailForImages: map['preferThumbnailForImages'] != false,
      thumbnailWidth: _toInt(map['thumbnailWidth'], fallback: 320),
      thumbnailHeight: _toInt(map['thumbnailHeight'], fallback: 320),
      thumbnailQuality: _toInt(map['thumbnailQuality'], fallback: 65),
      includeCleanResults: map['includeCleanResults'] == true,
      resolveConcurrency: _toInt(map['resolveConcurrency'], fallback: 6),
      includeOriginFileFallback: map['includeOriginFileFallback'] == true,
      attemptExpandLimitedAccess: map['attemptExpandLimitedAccess'] != false,
      retryPasses: _toInt(map['retryPasses'], fallback: 2),
      retryDelayMs: _toInt(map['retryDelayMs'], fallback: 1400),
      loadProgressEvery: _toInt(map['loadProgressEvery'], fallback: 24),
      maxRetainedResultItems: _toInt(
        map['maxRetainedResultItems'],
        fallback: 4000,
      ),
      debugLogging: map['debugLogging'] == true,
    );
  }
}

extension _NsfwBackgroundProcessingExt on FlutterNsfwScaner {
  bool get _isAppInForeground =>
      _appLifecycleState == AppLifecycleState.resumed;

  void _registerLifecycleObserverIfPossible() {
    try {
      final binding = WidgetsBinding.instance;
      _appLifecycleState = binding.lifecycleState ?? AppLifecycleState.resumed;
      _lifecycleObserver = _NsfwLifecycleObserver((state) {
        _appLifecycleState = state;
        _kickHaramiWorkers();
      });
      binding.addObserver(_lifecycleObserver!);
    } catch (_) {}
  }

  void _unregisterLifecycleObserver() {
    final observer = _lifecycleObserver;
    if (observer == null) {
      return;
    }
    try {
      WidgetsBinding.instance.removeObserver(observer);
    } catch (_) {}
    _lifecycleObserver = null;
  }

  Future<void> _restoreBackgroundJobsIfNeeded() async {
    if (_backgroundJobsRestored) {
      return;
    }
    _backgroundJobsRestored = true;
    if (!_backgroundProcessing.enabled) {
      _backgroundJobs.clear();
      _wholeGalleryJobRequests.clear();
      _deletePersistedBackgroundStateBestEffort();
      return;
    }
    _loadBackgroundStateBestEffort();
  }

  Future<void> _resumePendingBackgroundJobsIfNeeded() async {
    if (!_backgroundProcessing.enabled ||
        !_backgroundProcessing.continueGalleryScanInBackground ||
        !_backgroundProcessing.autoResumeInterruptedJobs) {
      return;
    }
    await _resumePendingBackgroundJobs();
  }

  List<NsfwBackgroundJob> _getBackgroundJobsSnapshot() {
    final jobs = _backgroundJobs.values.toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return jobs;
  }

  bool _isWholeGalleryScanRunning() {
    final activeJobId = _activeWholeGalleryJobId;
    if (activeJobId == null) {
      return false;
    }
    return _backgroundJobs[activeJobId]?.isActive == true;
  }

  Future<bool> _resumePendingBackgroundJobs() async {
    if (_isWholeGalleryScanRunning()) {
      return false;
    }
    NsfwBackgroundJob? resumableJob;
    for (final job in _backgroundJobs.values) {
      final resumable =
          job.type == NsfwBackgroundJobType.wholeGalleryScan &&
          (job.status == NsfwBackgroundJobStatus.queued ||
              job.status == NsfwBackgroundJobStatus.paused ||
              job.status == NsfwBackgroundJobStatus.running);
      if (resumable) {
        resumableJob = job;
        break;
      }
    }
    if (resumableJob == null) {
      return false;
    }
    final request = _wholeGalleryJobRequests[resumableJob.id];
    if (request == null) {
      return false;
    }
    unawaited(_runWholeGalleryScan(request, existingJobId: resumableJob.id));
    return true;
  }

  Future<bool> _resumeWholeGalleryScan() async {
    return _resumePendingBackgroundJobs();
  }

  Future<bool> _pauseWholeGalleryScan() async {
    final activeJobId = _activeWholeGalleryJobId;
    if (activeJobId == null) {
      return false;
    }
    final job = _backgroundJobs[activeJobId];
    if (job == null || !job.isActive || job.scanId == null) {
      return false;
    }
    await _platform.cancelScan(scanId: job.scanId);
    _backgroundJobs[activeJobId] = job.copyWith(
      status: NsfwBackgroundJobStatus.paused,
      updatedAt: DateTime.now().toUtc(),
      phase: 'paused',
    );
    _activeWholeGalleryJobId = null;
    _persistBackgroundStateBestEffort();
    return true;
  }

  Future<bool> _cancelWholeGalleryScan() async {
    final activeJobId = _activeWholeGalleryJobId;
    if (activeJobId == null) {
      return false;
    }
    final job = _backgroundJobs[activeJobId];
    if (job == null || !job.isActive || job.scanId == null) {
      return false;
    }
    await _platform.cancelScan(scanId: job.scanId);
    _backgroundJobs[activeJobId] = job.copyWith(
      status: NsfwBackgroundJobStatus.cancelled,
      updatedAt: DateTime.now().toUtc(),
      phase: 'cancelled',
    );
    _activeWholeGalleryJobId = null;
    _persistBackgroundStateBestEffort();
    return true;
  }

  void _clearFinishedBackgroundJobs() {
    final finishedIds = _backgroundJobs.values
        .where((job) => job.isFinished)
        .map((job) => job.id)
        .toList(growable: false);
    for (final id in finishedIds) {
      _backgroundJobs.remove(id);
      _wholeGalleryJobRequests.remove(id);
    }
    _persistBackgroundStateBestEffort();
  }

  NsfwBackgroundJob _beginWholeGalleryBackgroundJob(
    _WholeGalleryBackgroundRequest request, {
    String? existingJobId,
  }) {
    if (_backgroundProcessing.enabled &&
        _backgroundProcessing.preventConcurrentWholeGalleryScans &&
        _isWholeGalleryScanRunning() &&
        existingJobId != _activeWholeGalleryJobId) {
      throw StateError(
        'A whole-gallery scan is already running. Pause, cancel, or wait for the active background job before starting another one.',
      );
    }

    final now = DateTime.now().toUtc();
    final jobId =
        existingJobId ?? 'whole_gallery_${now.microsecondsSinceEpoch}';
    final previous = _backgroundJobs[jobId];
    final job = NsfwBackgroundJob(
      id: jobId,
      type: NsfwBackgroundJobType.wholeGalleryScan,
      status: NsfwBackgroundJobStatus.queued,
      buildVersion: _uploadBuildVersion,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
      processed: previous?.processed ?? 0,
      total: previous?.total ?? 0,
      settingsFingerprint: request.fingerprint,
      scanId: null,
      phase: 'queued',
      lastError: null,
    );
    _backgroundJobs[jobId] = job;
    _wholeGalleryJobRequests[jobId] = request;
    _activeWholeGalleryJobId = jobId;
    _persistBackgroundStateBestEffort();
    return job;
  }

  void _markWholeGalleryBackgroundJobRunning(
    String jobId, {
    required String scanId,
  }) {
    final job = _backgroundJobs[jobId];
    if (job == null) {
      return;
    }
    _backgroundJobs[jobId] = job.copyWith(
      status: NsfwBackgroundJobStatus.running,
      updatedAt: DateTime.now().toUtc(),
      scanId: scanId,
      phase: 'running',
      lastError: null,
    );
    _activeWholeGalleryJobId = jobId;
    _persistBackgroundStateBestEffort();
  }

  void _updateWholeGalleryBackgroundJob(
    String jobId, {
    int? processed,
    int? total,
    String? phase,
  }) {
    final job = _backgroundJobs[jobId];
    if (job == null) {
      return;
    }
    _backgroundJobs[jobId] = job.copyWith(
      processed: processed,
      total: total,
      phase: phase,
      updatedAt: DateTime.now().toUtc(),
      status: job.status == NsfwBackgroundJobStatus.queued
          ? NsfwBackgroundJobStatus.running
          : job.status,
    );
    _persistBackgroundStateBestEffort();
  }

  void _finishWholeGalleryBackgroundJob(
    String jobId, {
    required NsfwBackgroundJobStatus status,
    int? processed,
    int? total,
    String? lastError,
  }) {
    final job = _backgroundJobs[jobId];
    if (job == null) {
      return;
    }
    _backgroundJobs[jobId] = job.copyWith(
      status: status,
      processed: processed,
      total: total,
      phase: status.name,
      lastError: lastError,
      updatedAt: DateTime.now().toUtc(),
    );
    if (_activeWholeGalleryJobId == jobId) {
      _activeWholeGalleryJobId = null;
    }
    _persistBackgroundStateBestEffort();
  }

  void _loadBackgroundStateBestEffort() {
    try {
      final file = _backgroundJobsFile();
      if (!file.existsSync()) {
        return;
      }
      final raw = file.readAsStringSync().trim();
      if (raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final jobs = (decoded['jobs'] as List?) ?? const [];
      final requests = (decoded['wholeGalleryRequests'] as Map?) ?? const {};
      for (final rawJob in jobs) {
        if (rawJob is! Map) {
          continue;
        }
        final job = NsfwBackgroundJob.fromMap(
          rawJob.map((key, value) => MapEntry('$key', value)),
        );
        if (job == null) {
          continue;
        }
        _backgroundJobs[job.id] = job;
      }
      requests.forEach((key, value) {
        if (value is! Map) {
          return;
        }
        final request = _WholeGalleryBackgroundRequest.fromMap(
          value.map(
            (entryKey, entryValue) => MapEntry('$entryKey', entryValue),
          ),
        );
        if (request == null) {
          return;
        }
        _wholeGalleryJobRequests['$key'] = request;
      });
    } catch (_) {}
  }

  void _persistBackgroundStateBestEffort() {
    try {
      final file = _backgroundJobsFile();
      file.parent.createSync(recursive: true);
      final payload = <String, dynamic>{
        'jobs': _backgroundJobs.values
            .map((job) => job.toMap())
            .toList(growable: false),
        'wholeGalleryRequests': _wholeGalleryJobRequests.map(
          (key, value) => MapEntry(key, value.toMap()),
        ),
      };
      file.writeAsStringSync(jsonEncode(payload), flush: true);
    } catch (_) {}
  }

  void _deletePersistedBackgroundStateBestEffort() {
    try {
      final file = _backgroundJobsFile();
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  File _backgroundJobsFile() {
    final buildScope = _sanitizeHaramiStorageSegment(_uploadBuildVersion);
    final platformScope = _sanitizeHaramiStorageSegment(
      _uploadPlatform.isNotEmpty ? _uploadPlatform : Platform.operatingSystem,
    );
    final directory = _haramiStateDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}background_jobs_${platformScope}_$buildScope.json',
    );
  }
}

String _stableBackgroundHash(String value) {
  var hash = 1469598103934665603;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 1099511628211) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

class _NsfwLifecycleObserver extends WidgetsBindingObserver {
  _NsfwLifecycleObserver(this.onLifecycleChanged);

  final void Function(AppLifecycleState state) onLifecycleChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onLifecycleChanged(state);
  }
}
