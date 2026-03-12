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
- Worker parallelism is bounded by CPU and explicit settings.
- No large image bytes are transferred over channels during scan streaming.

## Permissions

- Android: media read permissions (`READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, legacy fallback on older versions)
- iOS: Photo Library usage descriptions

## Example app

See [example/README.md](example/README.md).

## For other LLMs / tooling

See [LLM.md](LLM.md) for architecture, event schemas, threading model, and integration notes.

## License

This plugin is licensed under MIT (see `LICENSE`).
Bundled model/license attributions are listed in `THIRD_PARTY_NOTICES.md`.
