# flutter_nsfw_scaner

[![Platform: Android](https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white)](#platform-and-requirements)
[![Platform: iOS](https://img.shields.io/badge/Platform-iOS-000000?logo=apple&logoColor=white)](#platform-and-requirements)
[![Android minSdk 24](https://img.shields.io/badge/Android-minSdk%2024-34A853)](#platform-and-requirements)
[![iOS 13+](https://img.shields.io/badge/iOS-13%2B-0A84FF)](#platform-and-requirements)
[![Flutter >=3.3.0](https://img.shields.io/badge/Flutter-%3E%3D3.3.0-02569B?logo=flutter)](#platform-and-requirements)
[![Dart ^3.9.0](https://img.shields.io/badge/Dart-%5E3.9.0-0175C2?logo=dart)](#platform-and-requirements)

Flutter plugin for NSFW detection on Android and iOS with TensorFlow Lite.

The plugin supports images, videos, mixed media batches, and full gallery scans with streamed progress/results.

## Key capabilities

- Image scan: `scanImage(...)`
- Image batch scan: `scanBatch(...)`
- Mixed media batch scan: `scanMediaBatch(...)`
- Chunked mixed media scan: `scanMediaInChunks(...)`
- Video scan with frame sampling + early stop: `scanVideo(...)`
- Scan media directly from URL (download + scan): `scanMediaFromUrl(...)`
- Native full gallery scan with streaming: `scanWholeGallery(...)` / `scanGallery(...)`
- Persisted background job coordination for long whole-gallery scans
- Persisted upload queue with staged local files for retries/resume
- Scan cancellation: `cancelScan(scanId: ...)` or `cancelScan()`
- Event stream progress updates via `progressStream`
- On-demand image thumbnail loading for gallery assets: `loadImageThumbnail(...)`
- On-demand full image asset loading for preview: `loadImageAsset(...)`
- Compatibility aliases: `loadImageThumnbail(...)`, `loadImageAssets(...)`

## Platform and requirements

- Flutter `>=3.3.0`
- Dart `^3.9.0`
- Android `minSdk 24`
- iOS `13.0+`

## Install

```yaml
dependencies:
  flutter_nsfw_scaner:
    path: ../flutter_nsfw_scaner
```

## Built-in model

The plugin ships a built-in model and labels:

- `NsfwBuiltinModels.nsfwMobilenetV2140224`
- `NsfwBuiltinModels.nsfwMobilenetV2140224Labels`

```bash
./tool/download_nsfw_model.sh
```

## Quick start

```dart
import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';

final scanner = FlutterNsfwScaner();

await scanner.initialize(
  modelAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224,
  labelsAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224Labels,
  numThreads: 2,
  inputNormalization: NsfwInputNormalization.minusOneToOne,
  defaultThreshold: 0.7,
  backgroundProcessing: const NsfwBackgroundProcessingConfig(
    enabled: true,
    continueUploadsInBackground: true,
    continueGalleryScanInBackground: true,
    preventConcurrentWholeGalleryScans: true,
    autoResumeInterruptedJobs: true,
  ),
  galleryScanCachePrefix: 'my_app',
  galleryScanCacheTableName: 'gallery_scan_history',
);

final image = await scanner.scanImage(
  imagePath: '/path/image.jpg',
  threshold: 0.45,
);

final video = await scanner.scanVideo(
  videoPath: '/path/video.mp4',
  threshold: 0.45,
  sampleRateFps: 0.3,
  maxFrames: 300,
  dynamicSampleRate: true,
);

final gallery = await scanner.scanWholeGallery(
  includeImages: true,
  includeVideos: true,
  pageSize: 140,
  scanChunkSize: 80,
  maxRetainedResultItems: 4000,
  includeCleanResults: false,
  debugLogging: true,
  settings: const NsfwMediaBatchSettings(
    imageThreshold: 0.45,
    videoThreshold: 0.45,
    maxConcurrency: 2,
  ),
  onLoadProgress: (p) {
    print('load ${p.scannedAssets} (images=${p.imageCount}, videos=${p.videoCount})');
  },
  onScanProgress: (p) {
    print('scan ${p.processed}/${p.total}');
  },
  onChunkResult: (chunk) {
    print('chunk items=${chunk.items.length}');
  },
);

print('flagged=${gallery.flaggedCount}, errors=${gallery.errorCount}');
print('skipped=${gallery.skippedCount}');
print('truncated=${gallery.didTruncateItems}');

await scanner.waitForPendingUploads();
```

## Background processing and long-running jobs

`initialize(...)` now accepts `backgroundProcessing`, and the default is already tuned for long whole-gallery scans:

```dart
await scanner.initialize(
  modelAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224,
  backgroundProcessing: const NsfwBackgroundProcessingConfig(
    enabled: true,
    continueUploadsInBackground: true,
    continueGalleryScanInBackground: true,
    preventConcurrentWholeGalleryScans: true,
    autoResumeInterruptedJobs: true,
    prioritizeForegroundUploads: true,
    backgroundResolveConcurrency: 1,
    backgroundUploadConcurrency: 1,
    backgroundMaxParallelVideoUploads: 1,
  ),
);
```

What this does:
- upload queue state is persisted per build version and resumed on next `initialize(...)`
- whole-gallery jobs are persisted and auto-resumed on next `initialize(...)`
- a second whole-gallery scan is blocked by default while one is already active
- `pauseWholeGalleryScan()` cancels the native run and keeps the job resumable
- when the app is in foreground, uploads use the configured full resolve/upload concurrency
- when the app leaves foreground, uploads stay alive but are automatically throttled to the background concurrency values

Public APIs:

```dart
final jobs = await scanner.getBackgroundJobs();
final running = await scanner.isWholeGalleryScanRunning();

await scanner.pauseWholeGalleryScan();
await scanner.resumeWholeGalleryScan();
await scanner.cancelWholeGalleryScan();
await scanner.clearFinishedBackgroundJobs();

await scanner.waitForBackgroundTasks();
```

Or via the controller:

```dart
final controller = scanner.backgroundController;
await controller.resumePendingJobs();
```

Important platform note:
- Android is better suited for prolonged background work.
- On iOS, uploads can keep progressing more reliably than a full gallery scan.
- If iOS suspends or the app is terminated, the plugin resumes persisted gallery jobs on the next app start; it does not claim unlimited post-termination execution.
- Upload queue and staged files are persisted in a durable application-support directory so queued uploads are more likely to survive app upgrades/restarts during TestFlight release flows.

## Whole-gallery scan cache

If you want `scanWholeGallery(...)` / `scanGallery(...)` to skip assets that were already scanned in earlier runs, configure the native cache once during `initialize(...)`:

```dart
await scanner.initialize(
  modelAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224,
  labelsAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224Labels,
  galleryScanCachePrefix: 'my_app',
  galleryScanCacheTableName: 'gallery_scan_history',
);
```

Notes:
- The cache is stored in native SQLite inside the app sandbox.
- The cache is automatically scoped to the current build version. A new app build creates a fresh scan cache namespace, so scans are not skipped across build updates unless you keep build version constant intentionally.
- Cache identity is based on the native gallery asset id.
- Only successful whole-gallery scan items are written to the cache.
- `processed` includes skipped items, and `skippedCount` tells you how many were avoided because they were already cached.
- If either `galleryScanCachePrefix` or `galleryScanCacheTableName` is omitted/empty, the cache is disabled.
- For very large libraries, whole-gallery scans retain at most `maxRetainedResultItems` in the final `items` list to avoid memory pressure. The full scan still runs, counters remain correct, and `onChunkResult` still streams every chunk.
- If retained items were capped, `didTruncateItems` is `true`.

## Default threshold

You can define the default scan threshold during `initialize(...)`:

```dart
await scanner.initialize(
  modelAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224,
  defaultThreshold: 0.7,
);
```

Notes:
- The default is `0.7`.
- `scanImage(...)`, `scanBatch(...)`, and `scanVideo(...)` use this initialized default when you do not pass `threshold`.
- You can still override the threshold per scan call:

```dart
final image = await scanner.scanImage(
  imagePath: '/path/image.jpg',
  threshold: 0.45,
);
```

## Normani/Harami upload device folder

If `useDeviceFolder` is enabled and you do not set `deviceFolder`, the plugin now generates a random device id once and reuses it across app restarts. This makes the auto upload prefix stable for the same app installation and distinct enough across devices.

Priority order:
- Explicit `NsfwNormaniConfig.deviceFolder`
- Compile-time define `NSFW_DEVICE_ID`
- Auto-generated persistent device id

Example:

```dart
final config = NsfwNormaniConfig(
  objectPrefix: 'nsfw_hits',
  useDeviceFolder: true,
  haramiResolveConcurrency: 2,
  haramiUploadConcurrency: 3,
  haramiMaxParallelVideoUploads: 1,
);
```

Notes:
- The generated id is stored locally inside the app sandbox.
- It survives normal app restarts.
- Reinstalling the app or clearing app storage can generate a new id.
- Uploads are staged locally before transfer so Photos/iCloud assets do not need to be re-materialized for every retry.
- Images can upload in parallel while videos are throttled separately.

Reset the cache for the currently initialized scanner:

```dart
await scanner.resetGalleryScanCache();
```

## Asset preview APIs (for gallery UIs)

Use these when you receive gallery item references (`assetId`, `uri`, `path`) from scan results:

```dart
final thumbPath = await scanner.loadImageThumbnail(
  assetRef: 'ph://A-B-C', // iOS PH asset URI/local id or Android content/file ref
  width: 160,
  height: 160,
  quality: 70,
);

final fullPath = await scanner.loadImageAsset(
  assetRef: 'ph://A-B-C',
);
```

Notes:
- These APIs return local file paths.
- They do not send image byte arrays over platform channels.
- Intended for lazy UI preview loading in result lists.

## UI widget kit (optional, individually stylable)

Import:

```dart
import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';
```

Progress widgets:
- `NsfwBatchProgressCard`
- `NsfwGalleryLoadCard`

Result widgets:
- `NsfwResultStatusChip`
- `NsfwResultTile`

Navigation/control widgets:
- `NsfwPaginationControls`
- `NsfwBottomActionBar`
- `NsfwScanWizardStepHeader`

All widgets are optional and composable. They are not hard-wired into scan logic.

## API summary

- `initialize(...)`
- `backgroundController`
- `getBackgroundJobs() -> Future<List<NsfwBackgroundJob>>`
- `isWholeGalleryScanRunning() -> Future<bool>`
- `resumePendingBackgroundJobs() -> Future<bool>`
- `resumeWholeGalleryScan() -> Future<bool>`
- `pauseWholeGalleryScan() -> Future<bool>`
- `cancelWholeGalleryScan() -> Future<bool>`
- `clearFinishedBackgroundJobs() -> Future<void>`
- `waitForBackgroundTasks() -> Future<void>`
- `scanImage(...) -> NsfwScanResult`
- `scanBatch(...) -> List<NsfwScanResult>`
- `scanMediaBatch(...) -> NsfwMediaBatchResult`
- `scanMediaInChunks(...) -> NsfwMediaBatchResult`
- `scanVideo(...) -> NsfwVideoScanResult`
- `scanMediaFromUrl(...) -> NsfwMediaBatchItemResult`
- `scanWholeGallery(...) -> NsfwMediaBatchResult`
- `scanGallery(...) -> NsfwMediaBatchResult`
- `scanMedia(...) -> NsfwMediaBatchItemResult`
- `scanMultipleMedia(...) -> NsfwMediaBatchResult`
- `resetGalleryScanCache()`
- `loadAsset(...) -> NsfwLoadedAsset?`
- `loadMultipleAssets(...) -> List<NsfwAssetRef>`
- `loadMultipleWithRange(...) -> NsfwAssetPage`
- `loadImageThumbnail(...) -> Future<String?>`
- `loadImageAsset(...) -> Future<String?>`
- `dispose()`
- `cancelScan({String? scanId})`

## Performance design

- Heavy scan work runs in native background workers (Android coroutines/IO + worker pools, iOS global queues/operation-style batching).
- Gallery scan is batched and streamed (`gallery_load_progress`, `gallery_scan_progress`, `gallery_result_batch`).
- Progress events are throttled.
- Image inference uses thumbnail-sized decode (`~224` target for model path).
- Upload processing is split into two stages: resolve/materialize first, upload second.
- Prepared upload files are cached locally so retries and resumed jobs do not repeatedly hit Photos/iCloud.
- Upload workers are parallelized, while large video uploads are throttled independently from images.
- Worker parallelism is bounded by CPU and explicit settings.
- No large image bytes are transferred over channels during scan streaming.

## Permissions

- Android: media read permissions (`READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, legacy fallback on older versions)
- iOS: Photo Library usage descriptions

## iOS CocoaPods note

If your host app uses this plugin and CocoaPods fails with a static/transitive binary error related to TensorFlow Lite, set static linkage in your iOS `Podfile`:

```ruby
target 'Runner' do
  use_frameworks! :linkage => :static
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
```

Then reinstall pods:

```bash
flutter clean
rm -rf ios/Pods ios/Podfile.lock
cd ios && pod repo update && pod install && cd ..
flutter run
```

## Example app

See [example/README.md](example/README.md).

## For other LLMs / tooling

See [LLM.md](LLM.md) for architecture, event schemas, threading model, and integration notes.

## License

This plugin is licensed under MIT (see `LICENSE`).
Bundled model/license attributions are listed in `THIRD_PARTY_NOTICES.md`.
